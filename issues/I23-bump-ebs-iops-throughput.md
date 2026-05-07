# I23 — Bump EBS gp3 IOPS / throughput for post-init disk performance

## Status

Proposed — 2026-04-28. Originally promoted from a footnote in I20.
Rescoped on the same day after we discovered (issue I24) that
first-boot disk slowness is dominated by snapshot lazy-load, not gp3
settings. **gp3 IOPS/throughput tuning only matters after the volume
is fully initialized** — which on a fresh-from-AMI worker means
"after the lazy-load is past." See I24 for the cold-boot fix.

Defer until I16 baseline numbers (or post-FSR measurements) tell us
whether random-IOPS or sequential throughput is the actual bottleneck
during steady-state workloads.

## Scope (what I23 covers, what it does NOT)

| Phase of disk activity | Bottleneck | Solved by |
|---|---|---|
| Boot, fresh from AMI snapshot | Snapshot lazy-load (S3-backed) | **I24 — Fast Snapshot Restore** |
| `cat *.bt2l > /dev/null` warmup on a freshly-booted worker | Snapshot lazy-load (mostly), NOT gp3 throughput | I24 |
| `cat *.bt2l > /dev/null` warmup on a worker whose volume is already initialized | gp3 sequential throughput | this issue (option A) |
| `bowtie2-align-l` random-mmap on a hot index | warm-cache (RAM) — no disk IO | n/a |
| `bowtie2-align-l` random-mmap on a cold index post-init | gp3 IOPS | this issue (option B) |
| HUMAnN ChocoPhlAn random-mmap on cold per-clade pangenomes | gp3 IOPS | this issue (option B) |

I23 is for the **post-init** rows. If you haven't enabled FSR, every
fresh worker spends its first 30-90 min in lazy-load territory and
gp3 settings do nothing for that phase.

## Background

Spot workers boot from a custom AMI with all reference DBs baked into
`/mnt/dbs/` on a 500 GB gp3 root volume. Default gp3 settings:

| Knob | Default | Cost above default |
|---|---|---|
| Storage | 500 GB | $0.08/GB-month (already paid) |
| IOPS | 3000 | $0.005/provisioned-IOPS-month above 3000 |
| Throughput | 125 MB/s | $0.04/MB/s-month above 125 |

## Two distinct interventions (both post-init only)

### A. Bump throughput from 125 → 250 MB/s (or 500 MB/s)

Once a volume is initialized (or FSR has pre-warmed it), sequential
reads run at the gp3 throughput cap. With 250 MB/s the 34 GB vJan25
cat takes ~2:15 instead of ~4:30; with 500 MB/s, ~1:10.

| Setting | $/month per volume (above default) | Sequential read of 34 GB (post-init) |
|---|---|---|
| 125 MB/s (default) | $0 | ~4:30 |
| 250 MB/s | $5 | ~2:15 |
| 500 MB/s | $15 | ~1:10 |

EBS billing is by-the-hour on the volume's lifetime. A worker that
exists for 1 hour pays roughly $0.007-$0.021 extra at 250-500 MB/s.

Win: shaves ~3 min off the post-init warmup. **Only realised if
combined with I24 (FSR) or after the volume has been touched once
end-to-end.** Without FSR, the warmup is bottlenecked upstream and
this knob is moot.

### B. Bump IOPS from 3000 → 12000

Speeds up cold-fault mmap on indexes that haven't been pre-warmed —
HUMAnN's per-clade ChocoPhlAn pangenome loads, for example, where
which clade is needed isn't known until MetaPhlAn detects species and
the random-IOPS pattern is unavoidable.

This is a **post-init** problem (block has been touched once, but
isn't in page cache). Bumping IOPS to 12000 gives ~4× improvement on
that cold-cache mmap pattern — ~7-8 min instead of ~30 min for the
chocophlan working set.

If we're already running with vOct22 pre-warmed (Phase 2 of I20)
and chocophlan-per-clade is still the dominant cold-IO pattern,
this is the remaining lever.

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

- **I24 — Fast Snapshot Restore — addresses the cold-boot lazy-load
  problem this issue used to conflate with gp3 settings. Land I24
  first; this issue then becomes useful for post-init tuning.**
- I20 — pre-warm MetaPhlAn cache (alternative to IOPS bump for vOct22).
  I20's warmup math also assumed gp3 throughput; see I24 for the
  actual first-boot bottleneck.
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
