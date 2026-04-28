# I23 — Bump EBS gp3 IOPS / throughput on spot workers

## Status

Proposed — 2026-04-28. Promoted from a footnote in I20 to its own
issue. Defer until I16 baseline numbers tell us whether throughput
or random-IOPS is the actual bottleneck.

## Background

Spot workers boot from a custom AMI with all reference DBs baked into
`/mnt/dbs/` on a 500 GB gp3 root volume. Default gp3 settings:

| Knob | Default | Cost above default |
|---|---|---|
| Storage | 500 GB | $0.08/GB-month (already paid) |
| IOPS | 3000 | $0.005/provisioned-IOPS-month above 3000 |
| Throughput | 125 MB/s | $0.04/MB/s-month above 125 |

I20 measurements show the disk profile that matters at task time:

- **Sequential pre-warm** (`cat *.bt2l > /dev/null` in UserData): bound
  by **throughput**. 125 MB/s = ~5 min for a 34 GB index.
- **mmap random-access** (bowtie2 cold-fault when warmup is skipped or
  the index is bigger than free RAM): bound by **IOPS**. 3000 IOPS
  ≈ 12 MB/s effective — 30+ min stall on first task per worker.

## Two distinct interventions

### A. Bump throughput from 125 → 250 MB/s (or 500 MB/s)

Speeds up the UserData warmup. With 250 MB/s the 34 GB vJan25 cat
takes ~2:15 instead of ~4:30. With 500 MB/s, ~1:10.

| Setting | $/month per volume (above default) | Warmup time, 34 GB |
|---|---|---|
| 125 MB/s (default) | $0 | ~4:30 |
| 250 MB/s | $5 | ~2:15 |
| 500 MB/s | $15 | ~1:10 |

EBS billing is by-the-hour on the volume's lifetime. A worker that
exists for 1 hour pays roughly $0.007-$0.021 extra at 250-500 MB/s.

Win: shaves ~3 min off every worker's first-job-acceptance time. At I10
scale (lots of worker churn), this compounds; for max005 it's
negligible.

### B. Bump IOPS from 3000 → 12000

Speeds up cold-fault mmap when something has NOT been pre-warmed. With
the Phase 1 design (vJan25 pre-warmed in UserData), bowtie2 hits warm
cache so this is mostly insurance.

But Phase 1 deliberately leaves vOct22 unwarmed. HUMAnN's internal
MetaPhlAn pre-screen will pay the cold-fault stall on first
profile_function task per worker — currently ~30 min. Bumping IOPS to
12000 gives roughly 4× improvement → ~7-8 min on the cold path, which
might be cheaper than adding the vOct22 warmup.

| Setting | $/month per volume (above default) |
|---|---|
| 3000 IOPS (default) | $0 |
| 6000 IOPS | $15 |
| 12000 IOPS | $45 |
| 16000 IOPS (gp3 max) | $65 |

Per-hour cost on a 1-hour worker: $0.02-$0.09.

Trade-off vs Phase 2 vOct22 warmup: warmup adds ~3 min UserData time
that workers serve sequentially; IOPS bump is paid for the lifetime of
the volume but costs ~$0.06/hr extra. Which one wins depends on
job-mix and how often workers are reused.

## Files to change

| File | Change |
|---|---|
| `infra/packer/worker-ami.pkr.hcl` | `launch_block_device_mappings { ... iops = N, throughput = M }` |
| `infra/batch-stack.yaml` | `BlockDeviceMappings` under `LaunchTemplateData` — add `Iops:` and `Throughput:` to the gp3 entry |
| `infra/readme.md` | Document the EBS settings + their cost implications |

Note: both Packer (for the source AMI snapshot) and the Launch Template
(for the runtime volume) need the bump. The AMI snapshot's volume
attributes are NOT inherited by the runtime instance — that's why the
LT has its own `BlockDeviceMappings` block today.

## Decision criteria

Decide based on I16 / I10 trace:

1. **Boot time dominates worker wallclock** → bump throughput (option A).
2. **First-task-on-worker is consistently slow due to cold-cache** → bump
   IOPS (option B).
3. **Both** → do both. Total cost ~$60/month per volume = ~$0.08/hr.
4. **Neither** → stay on defaults; the warmup + bake design already
   addresses the slow path.

## Acceptance criteria

- [ ] Per-volume EBS cost increase is documented in `infra/readme.md`
      cost section.
- [ ] Measurement shows the targeted phase (warmup OR cold-fault) is
      actually faster after the bump, by an amount commensurate with
      the cost.
- [ ] No regression on jobs that didn't have the cold-cache bottleneck
      to start with.

## Related

- I20 — pre-warm MetaPhlAn cache (alternative to IOPS bump for vOct22)
- I21 — bake MetaPhlAn DB prep (alternative to runtime DB prep)
- I22 — per-process AMIs / multi-queue (orthogonal; if AMIs are smaller,
  the throughput bump matters less because the warmup completes
  faster regardless)

## Out of scope

- Switching to a different EBS volume type (io2, st1, etc.) — gp3 is
  the right tier for this workload.
- Instance store (NVMe-backed local SSD) — would require a fundamental
  rearchitecture (DBs no longer survive instance termination, AMI
  bake becomes irrelevant).
- Provisioned-throughput EFS / FSx for Lustre — already evaluated and
  rejected in `infra/adr-001-db-placement.md`.
