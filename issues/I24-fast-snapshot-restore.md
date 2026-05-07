# I24 — Enable EBS Fast Snapshot Restore on the worker AMI snapshot

## Status

Proposed — 2026-04-28. Discovered live during the AMI v2 Phase 1
deployment when the vJan25 page-cache warmup ran at ~6 MB/s on a
freshly-booted worker — far below the 125 MB/s gp3 baseline assumed
by I20.

## What we measured

Workers `i-031fa1854fa999308` and `i-0edf0c9ddd29ccdbd` booted from
`ami-0b82e0161299a01ea` at 2026-04-28T20:13Z. The UserData warmup
(`cat /mnt/dbs/metaphlan_databases/vJan25/*.bt2l > /dev/null`) was
running at ~6 MB/s — 7 GB loaded after ~20 min. At that rate the
full 34 GB warmup would take ~95 min, not the ~5 min I20 originally
predicted.

## Why this is happening (and why I20 / I23 were both wrong about it)

When EC2 launches an instance from a snapshot-backed AMI, the root
volume is **lazy-loaded from S3**. Blocks live in S3 and are pulled
to EBS on first-touch. Until each block has been touched once, every
read goes through this slow path **regardless of the volume's gp3
throughput / IOPS settings**.

This is two layers, often confused:

| Layer | Bottleneck | Throughput observed |
|---|---|---|
| Snapshot lazy-load (first-touch) | Per-snapshot S3-backed init throttle | ~6-50 MB/s typical, 6 MB/s in our case |
| gp3 steady-state | User-configured throughput / IOPS | up to 1000 MB/s / 16000 IOPS provisioned |

Bumping gp3 throughput (the original I23 proposal) does **nothing** to
the lazy-load layer. The warmup math in I20 (`125 MB/s, ~5 min for
34 GB`) was derived from the gp3 layer and is wrong for first-boot
workers.

The custom AMI from I14 didn't eliminate the slow-first-read problem,
it just **relocated** it from `aws s3 sync` (visible) to snapshot
lazy-load (invisible until measured). Total cost-per-fresh-worker is
roughly the same, just paid in a different layer.

## Cost-comparison framing (user's observation)

Reading 34 GB at first-touch from a snapshot is structurally identical
to running `aws s3 sync s3://x .` on a fresh NVMe. Both fetch from S3
on demand, both pay per-GB egress (well, S3 GET for `aws s3 sync`;
internal-AWS-traffic for snapshot lazy-load), both bottleneck on
upstream throughput rather than the local disk.

The "fast access from boot" alternatives are all paid:

| Approach | Paid | Latency from boot |
|---|---|---|
| Snapshot lazy-load (today) | free per worker | ~30-90 min slow first reads |
| `aws s3 sync` at boot (pre-I14) | free per worker | ~20 min sync, then full local speed |
| Fast Snapshot Restore (this issue) | $0.75/AZ/hr per snapshot while enabled | full gp3 throughput from boot |
| EFS shared FS | $0.30/GB/month + throughput | network latency permanent |
| FSx for Lustre | $174/month minimum | network latency permanent |
| Provisioned IOPS gp3 | $5-65/volume/month | doesn't help with lazy-load |

FSR at $0.75/AZ/hr × 3 AZs = $2.25/hr is in the same order of magnitude
as a proper shared-FS subscription, but pay-as-you-go. It's the only
option that turns *off* when you're not using it.

## What FSR does

- Pre-replicates a snapshot to specified AZs in a region.
- Volumes restored from a FSR-enabled snapshot in those AZs serve full
  gp3 throughput from boot — no first-touch S3 fetch.
- State is per-snapshot per-AZ. Enable/disable independently.
- Initial enable takes ~5-60 min depending on snapshot size (our
  snapshot is ~150 GB — expect ~15-30 min).
- Billing starts when state becomes `enabled` and stops on `disabling`.

## Workflow

### Enable before a large run

```bash
SNAP_ID=$(aws ec2 describe-images \
  --image-ids "$(aws ssm get-parameter --name /nf-reads-profiler/ami-id \
                  --region us-east-2 --query 'Parameter.Value' --output text)" \
  --region us-east-2 \
  --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)

for AZ in us-east-2a us-east-2b us-east-2c; do
  aws ec2 enable-fast-snapshot-restores --region us-east-2 \
    --availability-zones "$AZ" --source-snapshot-ids "$SNAP_ID"
done

# Wait until all 3 are 'enabled' (not 'enabling') — 15-30 min for a 150 GB snapshot
aws ec2 describe-fast-snapshot-restores --region us-east-2 \
  --filters "Name=snapshot-id,Values=$SNAP_ID" \
  --query 'FastSnapshotRestores[].[AvailabilityZone,State]' --output table
```

### Disable after the run

```bash
for AZ in us-east-2a us-east-2b us-east-2c; do
  aws ec2 disable-fast-snapshot-restores --region us-east-2 \
    --availability-zones "$AZ" --source-snapshot-ids "$SNAP_ID"
done
```

Disable is near-instant; billing stops as soon as state leaves `enabled`.

### Suggested wrapper scripts

- `infra/packer/enable-fsr.sh` — wraps the enable + wait-for-ready
- `infra/packer/disable-fsr.sh` — wraps the disable

## When FSR pays off

| Scenario | Wallclock | FSR cost (3 AZ) | Verdict |
|---|---|---|---|
| 5-sample dev run (max005) | ~1-3 hr | $2-7 | Marginal — depends on whether you'd notice the 30+ min boot stall |
| 100-sample pilot (I09) | ~6-12 hr | $14-27 | Worth it — saves operator time, predictable per-sample wallclock |
| 16k-sample production (I10) | ~24-72 hr | $54-162 | Definitely worth it — slow first-job-per-worker × thousands of workers compounds |
| Always-on | $1620/month | NO — turn off when not running |

Rule of thumb: enable when total worker count × first-task-stall-saved
exceeds the $0.75/AZ/hr cost. At ~30 min saved per worker first-task
and $2.25/hr for 3-AZ coverage, breakeven is roughly **5 workers per
hour of FSR on**. Any sustained run beats that.

## What about Phase 2 / I22 (smaller per-stage AMIs)?

A smaller AMI snapshot lazy-loads less data on first boot. If
`worker-base` is 5 GB instead of 150 GB, the lazy-load penalty is
30× smaller — a few minutes instead of an hour. That makes FSR less
critical (or unnecessary) for the small-AMI workers.

For the big AMIs (`worker-humann` ≈ 90 GB after Phase 2), FSR is
still useful. So FSR + I22 are complementary, not substitutes.

## Files to create / change

| File | Change |
|---|---|
| `infra/packer/enable-fsr.sh` (new) | Idempotent enable across 3 AZs; waits for `enabled` state |
| `infra/packer/disable-fsr.sh` (new) | Idempotent disable across 3 AZs |
| `infra/playbook-ami-v2-rebuild.md` | Add post-build step: "if running at scale (>5 workers / hr × > 1 hr), enable FSR before submitting jobs" |
| `infra/readme.md` | Document FSR option in cost section; rule of thumb for when to enable |
| `issues/I20-prewarm-metaphlan-cache.md` | Cross-reference I24; correct warmup math |
| `issues/I23-bump-ebs-iops-throughput.md` | Rescope to post-init only; cross-reference I24 |

## Acceptance criteria

- [ ] `enable-fsr.sh` and `disable-fsr.sh` work end-to-end against
      the current SSM-published AMI's snapshot.
- [ ] After `enable-fsr.sh` reports all 3 AZs `enabled`, a fresh
      worker boot shows >100 MB/s sequential read on `/mnt/dbs/`
      (vs ~6 MB/s observed today).
- [ ] vJan25 warmup completes in <5 min on a FSR-enabled boot
      (vs ~95 min projected without).
- [ ] Cost section in `infra/readme.md` documents the per-AZ-hour
      rate and the breakeven rule of thumb.

## Out of scope

- Multi-region FSR (we're single-region).
- FSR for snapshots other than the worker AMI's root volume.
- Automating FSR enable/disable as part of `/deploy-stack` —
  deploys are infrastructure changes, not run starts. Keep separate.

## Related

- I14 — original custom AMI (relocated the slow-first-read problem
  from `aws s3 sync` to snapshot lazy-load, did not eliminate it).
- I20 — pre-warm MetaPhlAn cache (warmup is bottlenecked by lazy-load
  without FSR; this issue makes I20 deliver as advertised).
- I22 — per-process AMIs (smaller AMIs reduce lazy-load surface;
  complements FSR).
- I23 — gp3 IOPS/throughput tuning (orthogonal: applies after
  initialization, not during).
