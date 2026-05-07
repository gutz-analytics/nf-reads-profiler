# I14: Custom AMI for AWS Batch Workers

## Problem

Workers spend 20+ minutes at boot syncing 65 GiB (~30k objects) of reference
databases from S3 to `/mnt/dbs/` before accepting any Batch jobs. Spot
instances idle the entire time, wasting money and delaying pipeline starts.

ADR-001 assumed ~2-minute sync overhead and stated: "If sync exceeds 10
minutes, alternative strategies should be reevaluated." Observed sync time
exceeds that threshold by 2x.

The root cause is the high object count — `aws s3 sync` must issue individual
GET requests for ~30k small files. Narrowing the include filters (done in
commit 1c9c420) reduces the bucket scan but not the per-file transfer overhead.

## Alternatives Considered

### Custom AMI (pre-baked databases) — CHOSEN

Bake databases + Miniconda/awscli into a custom AMI built with Packer from the
AL2023 ECS-optimized ARM64 base. Workers boot with everything on disk and
register with ECS in seconds.

**Pros:**
- Fastest possible boot (seconds, not 20+ minutes)
- Best read performance (local gp3 SSD — critical for Bowtie2/DIAMOND random seeks)
- No ongoing infra to maintain (no EFS mount targets, security groups, throughput provisioning)
- No per-GB throughput charges
- AMI build is automated and reproducible

**Cons:**
- Must rebuild AMI (~30 min) when databases change (a few times/year)
- AMI is region-specific (us-east-2 only, currently)
- Snapshot storage cost (~$3.75/mo for ~75 GiB used blocks)
- Risk of stale databases if S3 is updated without rebuilding

### EFS (shared NFS filesystem) — REJECTED

Mount an EFS volume with databases pre-staged. Workers mount instantly.

**Pros:**
- No AMI rebuilds — update databases in one place
- Workers mount instantly
- Shared across all workers

**Cons:**
- NFS latency compounds over millions of random seeks (Bowtie2, DIAMOND)
- Throughput costs at scale with many concurrent workers
- Monthly cost even when idle (~$19.50/mo for 65 GiB standard)
- Requires additional infrastructure (mount targets, security groups)
- ADR-001 already rejected this for the same I/O latency reason

### Status quo (S3 sync at boot) — REJECTED

Already failing: 20+ minute sync, repeated race condition bugs, spot instances
wasting money during sync.

## Decision

Custom AMI. Databases change only a few times per year, making the rebuild
overhead negligible. The I/O performance advantage of local SSD (the core
rationale from ADR-001) is preserved.

## Implementation Outline

### Packer template (`infra/packer/worker-ami.pkr.hcl`)

- Source: latest AL2023 ECS-optimized ARM64 AMI
- Instance: `r8g.2xlarge` (matches production workers)
- Volume: 500 GiB gp3 encrypted (matches launch template)
- Provisioners:
  1. Install Miniconda to `/opt/conda-aws`, install awscli, `conda clean`
  2. Sync DB directories from S3 to `/mnt/dbs/` — current list:
     - `metaphlan_databases/vJan25/` (direct MetaPhlAn)
     - `metaphlan_databases/vOct22/` (HUMAnN-matched MetaPhlAn)
     - `humann/` (ChocoPhlAn, UniRef, utility maps)
     - `hostile/` (~4 GB bowtie2 human-t2t-hla index; added by I11)
     - `medi_db/` (Kraken2+Bracken food DB; only if MEDI enabled)
  3. Validate all directories have files
  4. Clean up temp files
- Post-processor: write AMI ID to SSM `/nf-reads-profiler/ami-id`

### Build script (`infra/packer/build-ami.sh`)

Wrapper: `packer init` + `packer validate` + `packer build`. Prints AMI ID.

### CloudFormation changes (`infra/batch-stack.yaml`)

- `EcsAmiId` parameter: point to custom AMI (lookup via SSM)
- UserData: replace S3 sync with minimal health check (verify `/mnt/dbs/` dirs
  exist, verify `/opt/conda-aws/bin/aws` exists, log errors)
- Remove `systemctl stop/start ecs` — databases are already present

### Deploy workflow

1. Build AMI: `bash infra/packer/build-ami.sh`
2. Deploy stack with new AMI ID via `/deploy-stack`
3. Force CE update with `updateToLatestImageVersion:true` (required — Batch
   does not auto-propagate launch template changes)

## Acceptance Criteria

- [ ] Packer template builds successfully and produces a valid ARM64 AMI
- [ ] AMI ID is stored in SSM `/nf-reads-profiler/ami-id`
- [ ] CloudFormation deploys with custom AMI and simplified UserData
- [ ] Workers register with ECS within 1 minute of launch (not 20+)
- [ ] Smoke test passes end-to-end: `bash infra/smoke-test.sh`
- [ ] ADR-001 updated to reflect the decision change
- [ ] `/deploy-stack` skill reads AMI ID from SSM
- [ ] `/preflight` skill checks AMI version matches SSM

## Supersedes

- ADR-001 (S3-sync database placement) — the 2-minute assumption was wrong
- The `--exclude`/`--include` approach in the UserData S3 sync (commit 1c9c420)
  is a stopgap; this issue replaces it entirely
