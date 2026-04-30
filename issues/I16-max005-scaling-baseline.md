# I16 — Scaling baseline run on 5 largest CHILD samples (`sra-child-max005`)

## Status

**DONE — 2026-04-30.** Project `max005-20260430-160716`. All 5 samples
completed. Metrics summary appended below. Unblocks I09, I11, I12, I13.

Originally proposed 2026-04-27.

## Goal

Get end-to-end run metrics — timing, VM packing, peak memory, S3 workdir
size, total cost — on the **5 largest-depth CHILD samples**. These are
the worst-case-per-sample workload, so they expose any resource-limit
issues that smaller samples mask.

Target: process all 5 samples for **≤ $100 total**. If we land near or
under that, it's a strong signal for the 16k-sample production run (I10).

## Inputs

- Samplesheet: `s3://gutz-nf-reads-profilers-runs/samplesheets/sra-child-max005.csv`
- 5 SRA accessions, study `SRP662258`:
  - `SRR36835310`
  - `SRR36835334`
  - `SRR36835076`
  - `SRR36835882`
  - `SRR36835853`

These are the top-5 by depth from the CHILD cohort (`max005` convention).
Earlier failed runs (2026-04-17) on these accessions predate the I00
containerOptions fix and the I14 custom AMI — irrelevant for this run.

## Pre-flight checklist

- [x] I00 (containerOptions fix) merged
- [x] I05 (smoke test driver) validated by run #9
- [x] I06 (resource limits / HUMAnN memory / nreads cap) merged
- [x] I14 (custom AMI) deployed and validated by smoke #9
- [ ] Old `screen` session `84178.nf` cleaned up (in progress per user)
- [ ] No active jobs in `spot-queue`
- [ ] CEs ENABLED + VALID (run `/preflight` before launch)
- [ ] Cost-allocation tags + budget alarm verified (I03/I04 — *not yet
      done; we will catch overspend reactively if alarms aren't wired*)

## Run procedure

Lesson from smoke #9: **always launch under `screen`**, never in the
foreground. SSH disconnect = SIGHUP = dead Nextflow.

```bash
# 1. Confirm no stale screen
screen -ls

# 2. Launch under screen
TS=$(date -u +%Y%m%d-%H%M%S)
PROJECT="max005-${TS}"
LOG=/home/ubuntu/github/nf-reads-profiler/logs/${PROJECT}.log

screen -dmS nf -L -Logfile "$LOG" bash -lc "
  cd /home/ubuntu/github/nf-reads-profiler && \
  nextflow run main.nf -profile aws \
    --input s3://gutz-nf-reads-profilers-runs/samplesheets/sra-child-max005.csv \
    --project ${PROJECT}; \
  echo '=== nextflow exited with \$? at \$(date -u) ==='; \
  exec bash
"

# 3. Detach-safe monitoring (run from anywhere)
sed -uE 's/\x1b\[[0-9;]*[A-Za-z]//g' "$LOG" | tail -f
```

## Metrics to capture

Capture these in `logs/<project>.log` and a structured summary at the bottom
of this issue (or a follow-up commit) when the run completes.

### Wallclock and stage timing

From `results_local_logs/<project>/reports/*_trace.txt`:
- Per-stage duration: `AWS_DOWNLOAD`, `FASTERQ_DUMP`, `count_reads`,
  `clean_reads`, `profile_taxa`, `profile_function`, `combine_*`, `MULTIQC`.
- Total wallclock from launch to "Execution complete -- Goodbye".
- Time spent in each state (`SUBMITTED → RUNNABLE → STARTING → RUNNING`).

### VM packing

From AWS Batch / EC2 (the existing `batch-doctor` agent covers most of this):
- Peak concurrent worker count.
- Instance types selected (Graviton family — `r8g.*` vs `r7g.*`).
- vCPU utilization per worker (do we ever fill an instance, or do we
  always provision a fresh one per task?).
- Spot reclamation events (count + which stages got hit).

### Memory + disk

From `*_trace.txt`:
- Peak RSS per task — flag any task within 80% of its `process.memory`
  limit.
- `/tmp` and `/mnt/dbs` watermarks if reachable via SSM during the run.
- Diamond translated-search is the usual memory peak; verify it stays
  under the I06-set limit.

### Storage

```bash
aws s3 ls s3://gutz-nf-reads-profilers-workdir/ --recursive --summarize \
  --human-readable | tail -3
```
- Workdir bytes generated (will auto-expire in 30 days per the lifecycle
  rule, but the peak matters for cost).
- Final results size in `s3://gutz-nf-reads-profilers-runs/results/<project>/`.

### Cost

- AWS Cost Explorer query for the run window, filtered to the project tag.
- Spot-vs-on-demand split.
- `$/sample` extrapolated to 100 (I09) and 16,000 (I10).

## Why this blocks downstream work

Any optimization (I11 host removal, I12 local reduce, I13 MEDI from
unmapped reads, future ideas) needs a **baseline** to measure against.
Without max005 numbers we cannot say "X saves Y%". So this run becomes
the reference against which all future tuning is compared.

If the cost lands at or below ~$100 / 5 samples (~$20/sample), the 16k
run extrapolates to ~$320k — almost certainly too high, and we *must*
land at least one optimization before I10. If it lands at $50 / 5
samples (~$10/sample), 16k → $160k — still high but in the realm of
"acceptable with some optimization". This run gives us the actual number.

## Acceptance criteria

- [ ] All 5 samples produce non-empty `genefamilies.tsv`,
      `pathabundance.tsv`, and `metaphlan_profile.tsv` outputs in
      `s3://gutz-nf-reads-profilers-runs/results/<project>/`.
- [ ] MultiQC report renders without missing-file warnings.
- [ ] Trace + timeline + report HTML are saved at
      `results_local_logs/<project>/reports/`.
- [ ] Total cost ≤ $100 (target; will document actual).
- [ ] No spot reclamations cause job failures (retries fine).
- [ ] Metrics summary appended to this issue or linked from
      `logs/<project>.log`.

## Open questions / flags before launch

- **Pathways DB issue** (surfaced from smoke #9): HUMAnN was using
  `humann/data/utility_DEMO/...` for the pathways database. The
  `_pathabundance.tsv` outputs were 90 bytes (essentially empty). If
  this is a real bug rather than HUMAnN4-default behavior, this run
  will inherit the same problem on the larger inputs. Worth a
  decision before launch: investigate first, or run anyway and treat
  pathabundance as out-of-scope for this baseline?
- **Budget alarm**: I03/I04 not yet verified. Set a manual reminder
  to check spend at ~halfway (estimated wallclock from sample sizes)
  and abort if pacing > $200.
- **Spot pricing volatility**: Graviton spot has been stable in
  us-east-2c/2a; if pricing spikes, the on-demand fallback CE will
  pick up but at higher cost.

---

## Results — 2026-04-30 (project `max005-20260430-160716`)

### Run summary

| Metric | Value |
|---|---|
| Total wallclock | 3h 16m 32s |
| Nextflow CPU hours | 32.5 h |
| Tasks succeeded | 34 |
| Tasks cached (resume) | 6 |
| S3 workdir size (post) | 98.9 GiB |
| S3 results size | 93.7 MiB |
| Instance types used | r8g.2xlarge (primary), m8g.2xlarge (FASTERQ_DUMP phase) |
| Cost | Pending — Cost Explorer 24h lag; query tag `Project=nf-reads-profiler` for window 16:07–19:38 UTC 2026-04-30 |

### profile_taxa — realtime, %cpu, peak_rss

| Sample | Reads | realtime | %cpu | peak_rss | Cache state |
|---|---|---|---|---|---|
| SRR36835853 | 8,458,427 | 10m 59s | 616% | 35.4 GB | warm |
| SRR36835882 | 8,532,961 | 9m 27s | 511% | 35.4 GB | warm |
| SRR36835076 | 8,959,121 | 9m 54s | 570% | 35.4 GB | warm |
| SRR36835310 | 11,291,070 | 12m 21s | 488% | 35.4 GB | warm |
| SRR36835334 | 11,193,897 | 59m 24s | 102% | 35.4 GB | **cold** |

SRR36835334's 102% CPU (≈single-threaded) vs 488–616% on the others is
the fingerprint of a cold EBS page cache: bowtie2 stalled in uninterruptible
disk wait while faulting in the 35 GB vJan25 index. The other four tasks
landed on workers whose background prewarm (I20) had finished; SRR36835334
landed on a freshly-booted worker (~2 min after boot, prewarm incomplete).

### profile_function — realtime, %cpu, peak_rss

| Sample | realtime | %cpu | peak_rss |
|---|---|---|---|
| SRR36835076 | 47m 10s | 540% | 20.0 GB |
| SRR36835310 | 55m 50s | 553% | 19.8 GB |
| SRR36835334 | 56m 9s | 537% | 21.1 GB |
| SRR36835853 | 1h 7m 40s | 614% | 19.5 GB |
| SRR36835882 | 1h 33m 38s | 344% | 19.0 GB |

SRR36835882 at 344% (vs 537–614% for others) may reflect partial cold
cache on the HUMAnN nucleotide DB (vOct22, ~20 GB working set) — same
mechanism as the profile_taxa outlier above.

### Acceptance criteria

- [x] All 5 samples produce non-empty `genefamilies.tsv`, `pathabundance.tsv`, `metaphlan_profile.tsv`
- [x] MultiQC report rendered (no errors observed)
- [x] Trace + timeline + report HTML saved at `results_local_logs/max005-20260430-160716/reports/`
- [ ] Total cost ≤ $100 — pending Cost Explorer (check 2026-05-01)
- [x] No spot reclamations caused job failures
- [x] Metrics summary appended (this section)

### Key findings for downstream issues

- **I25 (instance benchmark)**: warm-cache `profile_taxa` realtime 9–12 min
  on r8g.2xlarge; cold-cache outlier 59 min (102% CPU). Need cache-state
  annotation before comparing instance types.
- **I20 (prewarm)**: prewarm background task doesn't complete before jobs
  arrive when workers boot <5 min before first submission. FSR (I24) is
  necessary but not sufficient if Batch schedules jobs faster than prewarm.
  Consider delaying ECS agent start until prewarm finishes (see I20 Phase 2).
- **Cost extrapolation**: assuming warm-cache baseline (~10–12 min profile_taxa,
  ~55 min profile_function per sample), 16k samples × ~$X/sample pending
  Cost Explorer confirmation.
