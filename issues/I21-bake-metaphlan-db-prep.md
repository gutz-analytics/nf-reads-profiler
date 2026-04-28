# I21 — Bake MetaPhlAn DB preparation into the Packer AMI

## Status

Proposed — 2026-04-28. Discovered during the I16 max005 resume attempt
when `profile_taxa (SRR36835853)` hit the 1-hour Batch attempt timeout.
~12 minutes of that hour were consumed by MetaPhlAn 4.2.4 doing
on-the-fly database setup that should be a one-time AMI bake step.

**Phase 1 scope (current):** bake **vJan25** prep into the AMI only —
the DB used by `profile_taxa`. See `infra/playbook-ami-v2-rebuild.md`
for the combined runbook with I20.

**Phase 2 (deferred):** extend the same pattern to vOct22 (used by
HUMAnN's internal MetaPhlAn pre-screen in `profile_function`). Same
mechanism, same biobakery source, just a second `--install` call. We
validate the pattern works on the simpler `profile_taxa` case first.

## Background

The Packer AMI build (`infra/packer/worker-ami.pkr.hcl`) syncs raw
MetaPhlAn database files from S3 into `/mnt/dbs/metaphlan_databases/`,
including compressed archives:

- `mpa_vJan25_CHOCOPhlAnSGB_202503_SGB.fna.bz2`
- `mpa_vJan25_CHOCOPhlAnSGB_202503_VSG.fna.bz2`
- (similarly for vOct22)

MetaPhlAn 4.2.4 detects on first invocation that the bowtie2-loadable
form is missing and bootstraps it:

```
14:30:18  Decompressing mpa_vJan25_CHOCOPhlAnSGB_202503_SGB.fna.bz2
14:40:36  Decompressing mpa_vJan25_CHOCOPhlAnSGB_202503_VSG.fna.bz2
14:41:05  Joining FASTA databases
14:42:52  Removing uncompressed databases ..._SGB.fna
14:42:54  Removing uncompressed databases ..._VSG.fna
14:42:55  Download complete.
```

That's ~12 minutes of setup, paid every time a `profile_taxa` task
starts on a fresh worker. After this prep, MetaPhlAn presumably runs
`bowtie2-build` on the joined FASTA (more time burned), then alignment.
The 1-hour Batch attempt timeout fired before alignment could complete.

## Why this isn't fine

- **Wallclock waste at scale:** 12 min × 16,000 samples (I10 production)
  = ~3,200 worker-hours burned on redundant decompression. At spot rates
  (~$0.05/hr/vCPU, 8 vCPU = ~$0.40/hr per worker), that's ~$1,300+ in
  wasted compute.
- **Squeezes the time budget:** the `profile_taxa { time = '3h' }`
  override (introduced in conjunction with this issue, see
  `conf/aws_batch.config`) already sacrifices 12 min of every 3-hour
  budget to setup. Tighter time budgets become impossible.
- **Concurrency hazard:** if two `profile_taxa` jobs land on the same
  worker, both will detect missing prep files and try to decompress
  in parallel into the same paths. Race condition territory.
- **AMI snapshot is wasted potential:** the whole point of I14 was to
  ship a fully prepared `/mnt/dbs/`. Leaving DB prep to first-job time
  defeats that.

## Goal

The Packer build should produce an AMI in which `/mnt/dbs/metaphlan_databases/`
is fully prepared:
- All `.bz2` archives decompressed.
- Joined FASTA built where MetaPhlAn expects it.
- `bowtie2-build` index files (`.bt2l`) present and ready to mmap.

After bake, the first `profile_taxa` task on a fresh worker should jump
straight to alignment with no setup overhead.

## Approach: fetch MetaPhlAn from the official biobakery source via `--install`

Per
[biobakery forum guidance](https://forum.biobakery.org/t/minimap2-database-files-for-metaphlan-4-2-2/8504/2),
MetaPhlAn 4.x maintains an authoritative distribution that
`metaphlan --install` fetches automatically. We do not need to copy
the .bz2 archives through `cjb-gutz-s3-demo` first — the install step
downloads + decompresses + joins + `bowtie2-build`s in one operation,
fetching directly from biobakery's CDN.

This is **better than copying via our S3 bucket** for three reasons:
1. Removes ~54 GB of redundant data we'd otherwise maintain in
   `cjb-gutz-s3-demo`.
2. Canonical version pinning — `mpa_vJan25_CHOCOPhlAnSGB_202503` is a
   content-addressed identifier; biobakery's distribution is immutable
   for that version string. No risk of our copy drifting.
3. Less custom infra for future maintainers; aligns with how anyone
   reading the MetaPhlAn docs would expect the install to work.

**Phase 1 — vJan25 only.** Two coordinated changes to
`infra/packer/worker-ami.pkr.hcl`. The existing S3 sync stays intact
(vOct22 keeps coming from `cjb-gutz-s3-demo` like today); the new
provisioner replaces the vJan25 directory with the prepared form
fetched from biobakery. Phase 2 will add the symmetric vOct22 step.

**A. Leave the existing S3 sync block as-is** (still includes
`metaphlan_databases/*`, so vOct22 lands on the AMI from S3 as today).

**B. Add a new provisioner that runs `metaphlan --install` for vJan25:**

```hcl
provisioner "shell" {
  inline = [
    "sudo systemctl start docker || true",
    "sudo docker pull colinbrislawn/metaphlan:4.2.4",
    # Empty the S3-synced vJan25/ before metaphlan --install runs, so
    # we don't end up with stale .bz2 mixed with newly-built .bt2l.
    "sudo rm -rf /mnt/dbs/metaphlan_databases/vJan25",
    "sudo mkdir -p /mnt/dbs/metaphlan_databases/vJan25",

    # vJan25 (used by profile_taxa) — downloads from biobakery, prepares.
    "sudo docker run --rm -v /mnt/dbs:/mnt/dbs colinbrislawn/metaphlan:4.2.4 \\
       metaphlan --install \\
                 --index mpa_vJan25_CHOCOPhlAnSGB_202503 \\
                 --bowtie2db /mnt/dbs/metaphlan_databases/vJan25/",
  ]
}
```

Phase 2 will add a symmetric block for `mpa_vOct22_CHOCOPhlAnSGB_202403`
into `/mnt/dbs/metaphlan_databases/vOct22/`.

**C. Update the validation block** to assert the prepared vJan25
`.bt2l` files exist after the install step (Phase 1). Phase 2 adds the
matching assertion for vOct22.

Verify the exact `--install` semantics for MetaPhlAn 4.2.4 before
merging — older versions had different flags. The
`colinbrislawn/metaphlan:4.2.4` image is the authoritative reference
since that's what runs at task time.

### New dependency: Packer instance internet egress

The Packer instance must reach biobakery's CDN. The default VPC subnet
already has internet via NAT/IGW (the existing s3 sync proves this), so
no new networking work — but the AMI bake now depends on biobakery
availability. If a future build ever fails on the `--install` step,
biobakery's distribution may be down or the index name may have
changed.

## Side effect: AMI bake time + size

- **Bake duration**: adds ~15-20 min to the Packer build (the
  decompression + bowtie2-build itself). Acceptable; AMI bakes are
  rare.
- **AMI size**: decompressed FASTA is ~2-3× the .bz2 size. The full
  vJan25 footprint may grow from 34 GB to ~50-60 GB on disk. Add to
  vOct22 (~20 GB → ~30-35 GB), and total /mnt/dbs/ may approach 130-150 GB
  vs the current 66 GB. Still fits comfortably on the 500 GB EBS root,
  but worth measuring after bake.
- **Should we delete the .bz2 files post-prep?** Saves ~30 GB of AMI
  size. Trade-off: future re-prep (e.g., MetaPhlAn version bump
  requiring re-bootstrap) needs to re-fetch from S3. Recommendation:
  delete the .bz2 once we've verified `--install` is the canonical
  prep path; keep them around for the first iteration.

## Files to change

| File | Change |
|------|--------|
| `infra/packer/worker-ami.pkr.hcl` | Add `metaphlan --install` provisioner steps for vJan25 and vOct22 after the existing s3 sync; add validation that `.bt2l` files now exist. |
| `infra/packer/build-ami.sh` | No change expected, unless flag plumbing needed. |
| `issues/I20-prewarm-metaphlan-cache.md` | Add cross-link: I21 makes the prep one-time, I20 then warms the prepared form into page cache at task/worker start. |
| `conf/aws_batch.config` | `withName: 'profile_taxa' { time = '3h' }` is already in place; can be tightened to `'1h'` after I21 ships. |

## Acceptance criteria (Phase 1)

- [ ] Packer build produces an AMI where `/mnt/dbs/metaphlan_databases/vJan25/`
      contains the prepared bowtie2-loadable index files (no `.bz2` decompression
      step needed at task time).
- [ ] First `profile_taxa` task on a fresh worker reaches the actual
      alignment phase within 1-2 min of starting (vs ~12+ min today).
- [ ] `profile_function` is unchanged — vOct22 still served from S3-synced
      `.bz2` form, no regression vs current behavior.
- [ ] Add a Packer-time validation: the build fails loudly if the
      vJan25 prep step doesn't produce the expected `.bt2l` files.

### Phase 2 acceptance (deferred)

- [ ] vOct22 also baked from biobakery; HUMAnN's internal MetaPhlAn call
      benefits from the prepared form.
- [ ] `cjb-gutz-s3-demo/metaphlan_databases/` can be deleted (saves ~54
      GB of bucket storage; canonical source is now biobakery).

## Related

- I14 — original custom AMI build (this extends it)
- I15 — DbSourceBucket cleanup (BLOCKED on MEDI — orthogonal but
  also Packer-territory)
- I20 — pre-warm MetaPhlAn page cache (complements this; warm-cache
  needs a prepared DB to be useful)
- I22 (if opened) — Packer build pipeline / CI integration

## Out of scope

- Pre-decompressing chocophlan_v4_alpha (different problem; chocophlan
  uses per-clade FNA files that are already in usable form, no `--install`
  step needed).
- Switching to a different MetaPhlAn DB version.
- Investigating whether `mpa_vJan25_CHOCOPhlAnSGB_202503_VSG.fna.bz2`
  can be omitted from the workflow (potentially smaller DB).
