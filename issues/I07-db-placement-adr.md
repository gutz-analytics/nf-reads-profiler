# I07: Document DB-placement architecture decision (ADR 001)

**Priority:** low
**Size:** small
**Dependencies:** none (but I01 parameterizes the bucket name referenced here)

## Goal

Document the decision to keep per-worker S3 sync as the database placement
strategy, and add timing instrumentation to the Launch Template UserData so
the pilot run produces hard data on sync duration.

## Deliverables

### 1. Create `infra/adr-001-db-placement.md`

ADR format with:

- **Status:** Accepted (2026-04-24)
- **Context:** ~65 GB of databases (MetaPhlAn vJan25, HUMAnN4 ChocoPhlAn +
  UniRef, mapping tables) must be available on every Batch worker at `/mnt/dbs`
  before tasks run. MEDI Kraken2 DB (1.37 TB) is excluded via
  `--exclude "referencedata/*"`.
- **Decision:** Keep per-worker `aws s3 sync` from `cjb-gutz-s3-demo` to
  `/mnt/dbs/` in the EC2 Launch Template UserData at boot time.
- **Alternatives evaluated:**

| Option | Cost | Boot overhead | Why rejected |
|--------|------|---------------|-------------|
| Pre-baked AMI | ~$3.25/mo EBS snapshot | Near-zero | AMI rebuild workflow for ~2 min savings; operational burden not justified |
| EFS (Elastic throughput) | $0.30/GB/mo storage + $0.04/GiB reads | None (always mounted) | NFS latency degrades random I/O for Bowtie2 alignment + diamond search; throughput charges add up at 16K samples |
| FSx for Lustre (Scratch) | Min 1.2 TiB = ~$174/mo | Near-zero | 18× overprovisioned for 65 GB; complex setup for marginal benefit |
| S3 Mountpoint (FUSE) | Near-zero | None | Random-read latency kills bioinformatics workloads; not viable for alignment/search patterns |

- **Why S3 sync wins:** ~65 GB syncs in ~2 min at typical EC2 throughput
  (~5 Gbps). This is <1% of HUMAnN wall time (~4h). Free intra-region
  transfer. Local NVMe/gp3 reads are the fastest option after sync. No new
  infrastructure to manage, no throughput billing surprises, no AMI rebuild
  workflow.
- **MEDI note:** If `--enable_medi` is needed at 16K scale, the 1.37 TB
  Kraken2 DB would take ~30 min to sync. Pre-baked AMI becomes the right
  answer for MEDI-specific runs only. Deferred.
- **Consequences:**
  - Positive: simplest option, fastest runtime I/O, zero ongoing cost
  - Negative: every spot replacement re-syncs (~2 min); all workers hit same
    S3 prefix simultaneously (S3 handles this well, but pilot should confirm)

### 2. Add sync timing to `infra/batch-stack.yaml` UserData

Add `echo` timestamps around the `aws s3 sync` command in the
`BatchWorkerLaunchTemplate` UserData section (around lines 424-429):

```bash
# stage dbs locally
mkdir -p /mnt/dbs

echo "=== DB sync starting at $(date) ==="
/opt/conda-aws/bin/aws s3 sync s3://cjb-gutz-s3-demo /mnt/dbs/ \
    --exclude "referencedata/*" --quiet
echo "=== DB sync completed at $(date) ==="
```

These timestamps will appear in `/var/log/nf-userdata.log` on each worker
(the UserData already redirects to this file via `exec > >(tee ...)`).

During the pilot (I09), SSH into a worker or check CloudWatch Logs to
measure actual sync duration and validate the ~2 min estimate.

## Files

| File | Action |
|------|--------|
| `infra/adr-001-db-placement.md` | Create |
| `infra/batch-stack.yaml` | Add timing echoes to UserData sync block |

## Verification

- ADR is readable and accurately reflects the evaluation
- `aws cloudformation validate-template` passes after UserData edit
- After next stack deploy, SSH to a worker and check
  `/var/log/nf-userdata.log` for sync timing lines
