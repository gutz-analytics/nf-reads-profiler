# I20 — Pre-warm MetaPhlAn page cache in worker UserData

## Status

Proposed — 2026-04-28. Discovered during I16 max005 resume run while
investigating bowtie2 single-threaded behavior. Measurements during the
live run made the diagnosis unambiguous.

**Phase 1 scope (current):** pre-warm the **vJan25** index only — the
DB used by `profile_taxa`. This is the first DB being moved into the
new AMI build (see `infra/playbook-ami-v2-rebuild.md`). The pattern
generalizes to vOct22, but we validate it on the simpler standalone
process first.

**Phase 2 (deferred):** extend the same warmup to vOct22 (used by
HUMAnN's internal MetaPhlAn pre-screen in `profile_function`) once
Phase 1 is proven working. The original measurements below are on
vOct22; the wins for vJan25 are larger in absolute terms because the
index is bigger.

## Background

HUMAnN's `profile_function` calls MetaPhlAn internally as a pre-screen
step. MetaPhlAn invokes `bowtie2-align-l` against the index at
`/mnt/dbs/metaphlan_databases/vOct22/` (20 GB on disk).

The index is mmap'd. On a freshly-booted worker the page cache is empty,
so bowtie2 page-faults each region of the index from EBS the first time
it's needed. EBS gp3 default is 3000 IOPS / 125 MB/s sequential — but
mmap random access is IOPS-bound (≈ 12 MB/s effective). For a 20 GB
random-access pattern interleaved with alignment work, this is **roughly
30 minutes of stall on the first profile_function task per worker**.

## Evidence (from live run on PID 5262, 2026-04-28)

- bowtie2 spent ~33 minutes in state `D` (uninterruptible disk wait)
  with ~76% CPU, ~5.6 MB/s `read_bytes` from EBS — IOPS-throttled
  cold-cache mmap.
- After the index was warm: `maj_flt = 0` (no more disk faults), CPU
  crossed 100% for the first time, alignment proceeded normally.
- `read_fastx.py` (the upstream producer) was parked at 0% CPU during
  the cold-cache phase — back-pressured by slow bowtie2, NOT itself slow.
- Page cache was healthy: 33 GiB cached, 44 GiB available out of 61 GiB
  total host RAM. Plenty of room for the 20 GB index.

So the fix is to load the index into page cache *before* bowtie2 needs
it, sequentially (~3 min at 125 MB/s) instead of randomly during work
(~30 min at 12 MB/s). 10× speedup for free.

### Observed load-time per index (cold EBS gp3 baseline)

| Index | Size | Cold-fault load time | Sequential pre-warm time | Used by |
|---|---|---|---|---|
| `metaphlan_databases/vOct22` | 20 GB | ~30 min (measured) | ~3 min | HUMAnN pre-screen / `profile_function` |
| `metaphlan_databases/vJan25` | 34 GB | ~50 min (projected, 1.7× of vOct22) | ~5 min | `profile_taxa` (direct standalone MetaPhlAn, newer DB) |
| `chocophlan_v4_alpha` | 42 GB on disk | not all loaded at once — see below | n/a | HUMAnN nucleotide search / `profile_function` |

**Chocophlan note:** despite being 42 GB on disk, HUMAnN's nucleotide
search only loads pangenomes for species the MetaPhlAn pre-screen
actually detected — typically 50-200 species out of thousands, so only
a few GB are active per sample. Pre-warming the whole tree would be
wasteful (most of it never gets touched). Out of scope for I20; address
later if measurement shows the per-clade fault-in is itself a
significant cold-cache cost.

The relationship is roughly linear in DB size at the EBS gp3 IOPS limit
(3000 IOPS ≈ 12 MB/s effective for random-access mmap; 125 MB/s for
sequential pre-warm). So the same intervention generalizes: pre-warm
whichever DB the active stage needs, get a ~10× speedup on the cold
case.

### Implication for `profile_taxa` (vJan25)

`profile_taxa` runs standalone MetaPhlAn against vJan25 — different DB,
same problem. If the I16 trace shows a similar cold-fault stall on
`profile_taxa`, the same pre-warm approach applies, just keyed on
vJan25 instead of vOct22. The two DBs are currently independent
(different MetaPhlAn versions, different reference SGBs), so a worker
running `profile_taxa` doesn't help a worker running `profile_function`
and vice versa.

Open question: does the I10 production workflow run both `profile_taxa`
*and* `profile_function`? If yes, vJan25 + vOct22 = 54 GB of MetaPhlAn
indexes — almost all of host RAM on a 64 GB box, with no room for
binaries or working memory. That's an independent argument for either
(a) running on a 128 GB instance type or (b) splitting MetaPhlAn out so
each MetaPhlAn variant lands on its own VM, each with its own
matched-DB warmup (see synergy section below).

## Constraint: keep the active stage's DB hot

```
metaphlan_databases/vOct22      20 GB   on-disk; whole index used by bowtie2 pre-screen
metaphlan_databases/vJan25      34 GB   on-disk; whole index used by direct profile_taxa
chocophlan_v4_alpha             42 GB   on-disk; only pre-screened clades loaded (~few GB active)
full_mapping_v4_alpha          2.7 GB
uniref90_annotated_..._filtered 1.6 GB
host RAM (r6g/r8g.2xlarge):     64 GB
container memory limit:         60 GB
```

Among the *MetaPhlAn* indexes, the whole file is touched (bowtie2 mmaps
random-access into the entire index), which is why vOct22 has a 30-min
cold-fault penalty. Chocophlan is structured per-clade; HUMAnN only
loads pangenomes for species MetaPhlAn detected, typically a few GB per
sample. So the practical hot-cache requirement per stage is much
smaller than the on-disk total.

This issue scopes the intervention to the **MetaPhlAn vOct22 index**
specifically — it's the one we measured paying the full 30-min
cold-fault penalty, and pre-warming it (~3 min sequential) eliminates
that. Chocophlan is out of scope for I20; revisit if measurement shows
its per-clade fault-in is itself a significant cold-cache cost.

## Approach: pre-warm in worker UserData

Add to the launch-template UserData health-check (currently
post-AMI, health-check-only — see I14). After the existing `/mnt/dbs/`
existence check, sequentially read the **vJan25** index files
(Phase 1):

```bash
echo "Warming MetaPhlAn vJan25 page cache..."
time cat /mnt/dbs/metaphlan_databases/vJan25/*.bt2l > /dev/null 2>&1 || true
echo "Page cache warm."
```

`cat ... > /dev/null` does sequential reads, which on gp3 baseline runs
at ~125 MB/s. 34 GB ≈ 4:30. Worker takes ~5 min longer to accept jobs,
but the FIRST profile_taxa task on that worker saves ~30+ min of cold-
fault stall (extrapolated from the vOct22 measurement, scaled by index
size).

Phase 2 will extend this with a second `cat` line for vOct22 — the same
shape, just a different path. Out of scope for now.

For workers running multiple `profile_taxa` tasks (Batch can pack 2 jobs
per r6g.2xlarge if memory allows), all tasks benefit from the same
warmed cache. The fixed ~5 min cost amortizes over many tasks.

vmtouch is also an option (`vmtouch -t`) but isn't installed by default
on AL2023; `cat > /dev/null` requires nothing extra and is equally
effective for this purpose.

## Alternative approach: in-task pre-warm

If UserData approach is undesirable, do the pre-warm inside the
`profile_function` process script in `modules/community_characterisation.nf`:

```nextflow
script:
"""
# Pre-warm MetaPhlAn index page cache (saves ~30 min on first run per worker)
cat /mnt/dbs/metaphlan_databases/vOct22/*.bt2l > /dev/null 2>&1 || true

humann --input ... # rest unchanged
"""
```

Subsequent tasks on the same worker hit warm cache and the `cat`
returns in seconds. First task pays a one-time ~3 min cost.

Trade-off vs UserData: in-task is more portable (no infra change), but
the boot-time approach is cleaner (one-time cost, separate from
task budget).

## Out of scope (separate follow-ups, not blocking I16)

- **Chocophlan pre-warm**: chocophlan is 42 GB, fits in cache once
  vOct22 is evicted, but timing the warmup (after MetaPhlAn finishes,
  before nucleotide search starts) requires hooking inside HUMAnN. Not
  worth doing for I16; revisit if the nucleotide search phase shows
  similar cold-cache cost.
- **Bigger instance type** (r8g.4xlarge with 128 GB RAM): would let all
  4 DBs stay hot simultaneously, eliminating cold-cache penalty
  permanently. Higher per-hour cost but probably lower per-sample cost.
  Track separately if cost analysis shows it pays off.
- **Provisioned IOPS gp3**: bump EBS from 3000 → 12000 IOPS for ~$30/mo
  per worker. Reduces but doesn't eliminate the cold-cache penalty.
  Not as clean as pre-warming.

## Files that would change

| File | Change |
|------|--------|
| `infra/batch-stack.yaml` | Add `cat /mnt/dbs/metaphlan_databases/vJan25/*.bt2l > /dev/null` to LT UserData health-check block (Phase 1). Phase 2 adds the equivalent for vOct22. |
| OR `modules/community_characterisation.nf` | Add cache-warm line at top of `profile_taxa` script |

Pick one, not both. UserData is preferred (one-time cost per worker,
benefits all tasks).

## Acceptance criteria

- [ ] Baseline measured: time-to-first-MetaPhlAn-result on a fresh
      worker without pre-warm (use I16 trace data or instrument an
      explicit timer).
- [ ] After change: same measurement, expecting ~25-30 min reduction.
- [ ] No regression on profile_function wallclock for 2nd+ task on
      the same worker (should be cheaper than baseline because index
      stays cached anyway after first task).
- [ ] No regression on worker boot time beyond the expected ~3 min
      added by sequential read.

## Synergy: split MetaPhlAn into its own Nextflow process (would-be I21)

The win from this issue is much bigger if MetaPhlAn is broken out of
HUMAnN's internal pre-screen and run as its own Nextflow process step.

### Current architecture (the constraint)

```
profile_function (HUMAnN container, 60 GB memory limit, ~6h time):
  1. internal MetaPhlAn pre-screen   → uses /mnt/dbs/metaphlan_databases/vOct22/  (20 GB DB)
  2. ChocoPhlAn nucleotide search    → uses /mnt/dbs/chocophlan_v4_alpha/         (42 GB DB)
  3. UniRef translated search        → uses /mnt/dbs/uniref90_..._filtered/       (1.6 GB DB)
  4. pathway abundance computation
```

Because HUMAnN owns the whole pipeline, the container has to be sized
for the **biggest** stage (chocophlan at 42 GB). With 60 GB memory limit
on r6g.2xlarge (64 GB host, 8 vCPU), Batch can pack at most **1 job
per worker**. So a single worker amortizes its warmup over exactly 1
MetaPhlAn pre-screen.

### Split architecture (the opportunity)

```
profile_taxa_humann (new, MetaPhlAn-only, ~25 GB memory, ~30 min):
  - input:  cleaned reads
  - output: taxonomic profile TSV (vOct22 lineages)
  - DB:     /mnt/dbs/metaphlan_databases/vOct22/  (20 GB, fits in cache)

profile_function (HUMAnN, --taxonomic-profile <input>, ~60 GB memory):
  - skip internal MetaPhlAn pre-screen
  - use supplied profile from profile_taxa_humann
  - DB working set during this stage: chocophlan + uniref ≈ 44 GB
```

HUMAnN supports this via `--taxonomic-profile <file>` flag — feeding it
a pre-computed MetaPhlAn output skips the internal pre-screen entirely.

### Why the synergy with I20

A standalone `profile_taxa_humann` process needs only ~25 GB memory
(MetaPhlAn + bowtie2 + index in working set). On an r6g.2xlarge worker
with 60 GB available, **Batch can pack 2 of these jobs per worker**.
On a bigger r8g.4xlarge (128 GB) it's 4 per worker.

Each of those packed MetaPhlAn jobs hits the **same warmed vOct22 page
cache**. The fixed ~3 min UserData warmup cost amortizes over 2-4 jobs
instead of 1, and per-task wallclock drops from 30 min cold-fault → 5
min warm-cache.

Aggregate impact at I10 production scale (16k samples):
- Without I20: 16k × ~30 min cold MetaPhlAn = ~8000 worker-hours wasted on disk faults
- With I20 alone: 16k × ~5 min warm MetaPhlAn = ~1300 worker-hours, but 1 MetaPhlAn per VM
- With I20 + split: same per-task time + 2× packing density = ~650 worker-hours
- 12× compute reduction on this stage from the combination

### Suggested follow-up (not part of I20)

Open **I21 — split MetaPhlAn out of profile_function** to track the
architectural change. I20 stands alone (and is still worth doing
independently), but the two together are much stronger than either alone.
Track the I10 cost projection in I16's metrics to decide whether the
split is worth the refactor cost.

## Related

- I14 — custom AMI (the DBs being baked is what makes this even possible)
- I18 — FASTERQ_DUMP threading (different bottleneck, different stage)
- I19 (if opened) — spot reclamation + retries (orthogonal)
- I21 (if opened) — split MetaPhlAn into its own Nextflow process —
  multiplies the value of I20

## Anti-recommendation: do NOT pre-warm all of /mnt/dbs/

The total DB footprint (66 GB) exceeds host RAM (64 GB). Pre-warming
everything would force the OS to evict pages it just loaded, achieving
nothing. Scope the warmup to one DB at a time, matched to the active
HUMAnN phase.
