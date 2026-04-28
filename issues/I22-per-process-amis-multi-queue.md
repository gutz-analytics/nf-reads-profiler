# I22 — Split workers by stage: per-process AMIs + multiple Batch queues

## Status

Proposed — 2026-04-28. Architectural follow-up from the AMI v2 Phase 1
work. Defer until I16 baseline numbers are in hand and we know which
stages are actually paying boot/cache cost in production.

## Background

Today every Batch worker boots from one fat AMI (~130-150 GB after
Phase 2 lands) carrying every reference DB the pipeline could
possibly need. Workers are then asked to run any of:

| Stage | DB working set | Container |
|---|---|---|
| AWS_DOWNLOAD, FASTERQ_DUMP, clean_reads, count_reads, MultiQC | none | small utility images |
| profile_taxa | vJan25 (~34 GB) | `colinbrislawn/metaphlan:4.2.4` |
| profile_function | vOct22 + chocophlan + uniref90 (~64 GB active) | `colinbrislawn/humann:4.0.3` |
| MEDI_QUANT (broken on AWS today) | medi_db (~447 GB) | MEDI image |

Bin-packing across stages happens because all jobs land on the same
queue. That's good for utilization on small runs, but:

- A FASTERQ_DUMP job ends up on a worker that booted with 130 GB of
  reference data it will never touch.
- Large AMIs take longer to snapshot (the build #2 timeout that bit us)
  and longer to boot (EBS warm-up + ECS agent start).
- Pre-warm cost (`cat *.bt2l > /dev/null`) is paid even when the worker
  ends up running only ingest tasks.

## Architecture Nextflow + Batch supports

AWS Batch routes jobs by **queue**, not by job characteristics. A queue
points to one or more CEs, each with its own Launch Template, each with
its own AMI. To split workers by stage:

1. Build N AMIs, each with only the DBs that stage needs (or none).
2. Provision N CEs in CFN, each LT pointing at the matching AMI.
3. Provision N queues, each backed by the matching CE(s).
4. Map Nextflow processes to queues:

   ```nextflow
   process {
       queue = 'spot-queue-base'    // default: tiny no-DB AMI

       withName: 'profile_taxa' {
           queue = 'spot-queue-vjan25'
       }
       withName: 'profile_function' {
           queue = 'spot-queue-humann'
       }
   }
   ```

The container image stays per-process via the existing `container`
directive — that's an independent axis. The AMI provides `/mnt/dbs/`
on the host; the LT mounts it into whatever container Nextflow runs.

## Realistic split (when this lands)

| AMI | Contents | Size | Stages |
|---|---|---|---|
| `worker-base` | OS + awscli + sra-tools + utility binaries | ~5 GB | AWS_DOWNLOAD, FASTERQ_DUMP, clean_reads, count_reads, MultiQC |
| `worker-taxa` | base + vJan25 prepared | ~40 GB | profile_taxa |
| `worker-humann` | base + vOct22 + chocophlan + uniref90 | ~90 GB | profile_function |
| `worker-medi` (deferred until MEDI works on AWS) | base + medi_db | ~450 GB | MEDI_QUANT |

The biggest concrete win is `worker-base`: FASTERQ_DUMP workers boot
in seconds from a 5 GB AMI instead of ~5+ min from a 130 GB AMI. At
I10 scale (16k samples, mostly ingest churn) that's significant.

## Trade-offs

**Pros**
- Smaller AMIs → faster Packer builds, faster snapshots, faster boot.
- Smaller cache footprint per stage → vJan25 fills the page cache without
  competing against chocophlan it won't use.
- Per-stage iteration: rebuild `worker-taxa` without touching humann.
- FASTERQ_DUMP workers can use cheaper instance types (no need for 64 GB
  RAM just to mount big DBs).

**Cons**
- More CFN resources (3 CEs + 3 LTs + 3 queues + per-CE alarms).
- More AMI builds and version-alignment to manage.
- Bin-packing fragmentation: profile_taxa and FASTERQ_DUMP no longer
  share a worker; idle vCPUs waste on small runs.
- More failure modes during deploys; more queues with their own metrics.
- `process.queue` mappings must stay correct; a mis-mapped process either
  fails (DB missing) or works inefficiently (booting a fat AMI for a
  small job).

## When to revisit

Land this if I16 / I10 measurement shows ANY of:

- AWS_DOWNLOAD/FASTERQ_DUMP wallclock dominated by worker boot, not work.
- Workers running only ingest tasks but boot times are 5+ min.
- Page-cache thrashing between profile_taxa and profile_function on the
  same worker (one stage evicting the other's hot DB).
- Per-stage AMI build cost (developer time) is being eaten by combined
  rebuilds for any DB version bump.

If none of those bite at I10 scale, the single-AMI design wins on
simplicity.

## Files that would change

| File | Change |
|---|---|
| `infra/packer/` | Split into `worker-base.pkr.hcl`, `worker-taxa.pkr.hcl`, `worker-humann.pkr.hcl`. Shared base layer to dedupe miniconda+awscli install. |
| `infra/batch-stack.yaml` | Add per-stage `LaunchTemplate`/`ComputeEnvironment`/`JobQueue` resources (~3× current). Per-stage SSM AMI parameters. |
| `conf/aws_batch.config` | Add `withName:` queue mappings per process. |
| `infra/playbook-multi-ami.md` (new) | Build sequence for 3 AMIs + sanity checks. |
| `.claude/agents/batch-doctor.md` | Update to enumerate all queues + CEs. |
| `infra/readme.md` | Document the queue-to-stage mapping. |

## Acceptance criteria

- [ ] Three AMIs built and published to distinct SSM parameters.
- [ ] CFN deploys cleanly with all three CEs/queues healthy.
- [ ] A profile_taxa job lands on a worker that has vJan25 but NOT
      chocophlan; verified by SSH + `ls /mnt/dbs/`.
- [ ] FASTERQ_DUMP boot-to-first-task time drops measurably (target
      < 60 sec from > 5 min today).
- [ ] No regression on profile_function wallclock.
- [ ] I16 max005 still passes end-to-end.

## Related

- I14 — original custom AMI work (single AMI; this issue splits it)
- I20 — pre-warm MetaPhlAn cache (per-queue warmup becomes natural)
- I21 — bake MetaPhlAn DB prep (per-AMI bake becomes natural)
- I23 — bump EBS IOPS / throughput (orthogonal: applies whether single
  or split AMIs)

## Out of scope

- Container image consolidation (different concern; we already use
  per-process images).
- Cross-account or cross-region AMI distribution.
- ARM64 vs x86 split (we're ARM64-only).
