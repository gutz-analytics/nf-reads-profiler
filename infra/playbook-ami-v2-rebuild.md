# Playbook — AMI v2 rebuild (Phase 1: profile_taxa / vJan25 only)

**Phase 1 scope:** validate the entire optimization pattern (download
from official source + pre-warm cache) on `profile_taxa` and the
vJan25 MetaPhlAn DB only. Once this is working end-to-end, we extend
the same pattern to `profile_function` / vOct22 in a Phase 2 rebuild.

Combines (narrowed forms of) two issues into a single Packer + UserData
rebuild:

- **I21 (narrowed)** — bake vJan25 MetaPhlAn DB into the AMI from the
  **official biobakery source** via `metaphlan --install`. Eliminates
  ~12 min decompression-on-first-run for `profile_taxa`.
- **I20 (narrowed)** — pre-warm the vJan25 page cache in worker
  UserData. Eliminates the cold-fault penalty on first `profile_taxa`
  task per worker.

**Out of scope for Phase 1** (deliberately untouched):

- vOct22 — still copied from S3 like today. HUMAnN's internal MetaPhlAn
  pre-screen will continue to pay its current cold-fault cost on first
  use; that's known and accepted for this phase.
- HUMAnN DBs (chocophlan, full_mapping, uniref90) — still copied from S3.
- `profile_function` workflow — unchanged; will still be slow on first
  task per worker (this is fine; we're proving the pattern works on
  the simpler case first).

Expected impact on per-task wallclock for fresh workers:

| Task | Before | After (Phase 1) |
|---|---|---|
| `profile_taxa` first task | ~50 min (12 min prep + 38 min alignment) → 1h timeout | ~5-10 min (warm cache, prepared DB) |
| `profile_function` first task | ~30 min cold-fault + alignment | unchanged — still slow on first task |

---

## Pre-flight

Before kicking anything off:

1. **Queue is empty** (current run failed at the timeout; verify no leftovers):
   ```bash
   for s in SUBMITTED PENDING RUNNABLE STARTING RUNNING; do
     aws batch list-jobs --job-queue spot-queue --region us-east-2 \
       --job-status $s --query 'length(jobSummaryList)' --output text
   done
   ```

2. **Old screen session is gone** (if `nf` from the failed resume is still around):
   ```bash
   screen -X -S nf quit 2>&1 || true
   ```

3. **`infra/packer/build-ami.sh` runs from the head node** with
   `head-node-role` IAM profile. That role needs `ec2:RunInstances`,
   `ec2:CreateImage`, `s3:Get/ListObject` on `cjb-gutz-s3-demo`,
   `ssm:PutParameter` on `/nf-reads-profiler/ami-id`, and Packer's
   normal AMI-creation perms. Already in place from I14.

4. **Capture the current AMI ID** in case rollback is needed:
   ```bash
   aws ssm get-parameter --name /nf-reads-profiler/ami-id \
     --region us-east-2 --query 'Parameter.Value' --output text
   ```
   Today's value: `ami-0b87926a60df7043e` (the I14 baseline AMI).

---

## File changes (proposed — staged for review, not yet applied)

### 1. `infra/packer/worker-ami.pkr.hcl` — fetch vJan25 from official biobakery source

**Phase-1 narrowed:** the existing S3 sync stays intact — vOct22 still
gets pulled from `cjb-gutz-s3-demo` like today (HUMAnN keeps working
unchanged). The only edit is to *add* a new provisioner that fetches
vJan25 from biobakery and prepares it in place.

**Change 1a:** Leave the existing S3 sync block as-is. (No edit needed.)

It stays exactly as it is now:

```hcl
"sudo /opt/conda-aws/bin/aws s3 sync s3://$DB_SOURCE_BUCKET /mnt/dbs/ \\
   --exclude '*' \\
   --include 'chocophlan_v4_alpha/*' \\
   --include 'full_mapping_v4_alpha/*' \\
   --include 'metaphlan_databases/*' \\
   --include 'uniref90_annotated_v4_alpha_ec_filtered/*'",
```

This synced copy of `metaphlan_databases/` will populate vJan25 from
S3 with the same `.bz2` files we have today. The new step (1b) then
**replaces** the contents of the vJan25 directory specifically with
the prepared form from biobakery. vOct22 keeps its current S3-synced
content untouched.

**Change 1b:** Insert a new provisioner block **after** the s3 sync
(line ~112) and **before** the validation block. This downloads + prepares
ONLY vJan25, replacing whatever the S3 sync put there. Per
[biobakery forum guidance](https://forum.biobakery.org/t/minimap2-database-files-for-metaphlan-4-2-2/8504/2),
`metaphlan --install` is the canonical way to fetch + prepare the index.

```hcl
  # Phase 1: fetch vJan25 from official biobakery source and prepare it
  # (decompress .bz2, build joined fasta, bowtie2-build the index). This
  # is a one-time bake step; without it, every profile_taxa task spends
  # ~12 min doing this on first run and may time out. See issue I21.
  #
  # vOct22 is intentionally NOT touched here — it's still synced from
  # cjb-gutz-s3-demo by the previous provisioner, and HUMAnN's internal
  # MetaPhlAn pre-screen will continue using that copy. Phase 2 extends
  # this pattern to vOct22 once Phase 1 is validated.
  provisioner "shell" {
    inline = [
      "echo '=== Phase 1: fetching vJan25 from official biobakery source ==='",
      "sudo systemctl start docker || true",
      "sudo docker pull colinbrislawn/metaphlan:4.2.4",
      # Empty the S3-synced contents of vJan25/ so metaphlan --install
      # writes a clean prepared form (avoids stale .bz2 files mixed with
      # newly-built .bt2l indexes).
      "sudo rm -rf /mnt/dbs/metaphlan_databases/vJan25",
      "sudo mkdir -p /mnt/dbs/metaphlan_databases/vJan25",
      # Download + decompress + join + bowtie2-build, all in one step.
      # ~10-15 min on r8g.2xlarge depending on biobakery CDN throughput.
      "sudo docker run --rm -v /mnt/dbs:/mnt/dbs colinbrislawn/metaphlan:4.2.4 \\
         metaphlan --install \\
                   --index mpa_vJan25_CHOCOPhlAnSGB_202503 \\
                   --bowtie2db /mnt/dbs/metaphlan_databases/vJan25/",
      "echo '=== vJan25 prep complete ==='",
      "ls -lh /mnt/dbs/metaphlan_databases/vJan25/ | head",
    ]
  }
```

**Change 1c:** Update the validation block (line 117-121) to assert
the prepared vJan25 `.bt2l` files exist (in addition to the existing
checks):

```hcl
  provisioner "shell" {
    inline = [
      "echo '=== Validating pre-baked content ==='",
      "for d in chocophlan_v4_alpha full_mapping_v4_alpha metaphlan_databases uniref90_annotated_v4_alpha_ec_filtered; do count=$(find /mnt/dbs/$d -type f | wc -l); echo \"$d: $count files\"; if [ \"$count\" -eq 0 ]; then echo \"FATAL: $d has no files\" >&2; exit 1; fi; done",
      # NEW: Phase 1 — verify vJan25 has the prepared bowtie2-loadable files
      "vJan25_bt2l=$(find /mnt/dbs/metaphlan_databases/vJan25 -name '*.bt2l' | wc -l); echo \"metaphlan/vJan25 .bt2l files: $vJan25_bt2l\"; if [ \"$vJan25_bt2l\" -lt 4 ]; then echo \"FATAL: metaphlan/vJan25 missing .bt2l index files (need >=4)\" >&2; exit 1; fi",
      "/opt/conda-aws/bin/aws --version",
      "echo '=== Validation passed ==='",
    ]
  }
```

### Side benefits (deferred until vOct22 also moves to biobakery in Phase 2)

- vJan25 now uses canonical source (biobakery), but vOct22 still copies
  from `cjb-gutz-s3-demo`. So `cjb-gutz-s3-demo/metaphlan_databases/`
  cleanup (mentioned in I15) is **deferred** until Phase 2.
- The Packer build now depends on biobakery's CDN being reachable for
  vJan25. Default VPC subnet has internet via NAT/IGW (existing s3 sync
  proves this), so no new networking work.

### 2. `infra/batch-stack.yaml` — add vJan25 cache warmup to UserData

**Phase-1 narrowed:** pre-warm only vJan25, since profile_taxa is the
single process we're optimizing in this iteration. vOct22 stays unwarmed
(profile_function will continue to pay its first-task cold-cache cost).

In the launch-template UserData block (around line 411-435), add a
warmup line right before the success message:

```yaml
            if [ $ERRORS -gt 0 ]; then
              echo "FATAL: $ERRORS pre-bake checks failed. Rebuild AMI with infra/packer/build-ami.sh" >&2
            else
              echo "OK: all databases and awscli present"
              cat /mnt/dbs/.ami-build-timestamp 2>/dev/null || true

              # Phase 1: pre-warm MetaPhlAn vJan25 page cache (~5 min sequential
              # read of 34 GB index) so the first profile_taxa task on this
              # worker doesn't pay the cold-fault penalty. See issue I20.
              echo "=== Pre-warming MetaPhlAn vJan25 page cache ==="
              time cat /mnt/dbs/metaphlan_databases/vJan25/*.bt2l > /dev/null 2>&1 || true
              echo "OK: vJan25 page cache warmed"
            fi
```

vOct22 intentionally NOT pre-warmed in this phase — we'll add it
in Phase 2 once vJan25 is proven working end-to-end.

---

## Build sequence

These steps are run by you, on the head node. I can run them too if you
prefer; nothing here is destructive (the old AMI stays published in
SSM until step 6 succeeds).

### Step 1 — review the file edits

```bash
# I'll have prepared the changes in the working tree; review with:
git -C /home/ubuntu/github/nf-reads-profiler diff infra/packer/worker-ami.pkr.hcl infra/batch-stack.yaml
```

### Step 2 — kick off the Packer build

```bash
cd /home/ubuntu/github/nf-reads-profiler
bash infra/packer/build-ami.sh 2>&1 | tee logs/ami-build-$(date -u +%Y%m%d-%H%M%S).log
```

Expected wallclock: ~30-45 min (was ~20-25 min for I14; the
`metaphlan --install` step adds ~15 min).

### Step 3 — watch it run (so you can see the build process)

While Packer is running, in a separate terminal:

```bash
# Find the Packer instance:
PACKER_INSTANCE=$(aws ec2 describe-instances --region us-east-2 \
  --filters "Name=tag:Name,Values=packer-nf-reads-profiler-worker" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
echo "Packer building on: $PACKER_INSTANCE"

# Watch what Packer's provisioner is doing:
aws ssm start-session --region us-east-2 --target "$PACKER_INSTANCE"
# Then inside:
sudo tail -f /var/log/cloud-init-output.log
# Or watch the docker pull / metaphlan --install run:
sudo docker ps
sudo docker logs -f $(sudo docker ps -q --filter ancestor=colinbrislawn/metaphlan:4.2.4)
```

The interesting milestones inside the Packer instance:
- s3 sync of /mnt/dbs/ (~5-10 min — includes vOct22 still synced from S3)
- docker pull colinbrislawn/metaphlan:4.2.4 (~30 sec)
- vJan25 `--install` (~10-15 min — biobakery download + decompression + join + bowtie2-build)
- Validation block (~30 sec)
- AMI snapshot (~10-15 min — Packer-side, you won't see it from inside)

Total expected build time: ~30-40 min (vs ~20-25 min for current AMI;
the vJan25 install adds ~10-15 min).

### Step 4 — confirm the new AMI ID

```bash
aws ssm get-parameter --name /nf-reads-profiler/ami-id \
  --region us-east-2 --query 'Parameter.Value' --output text
```

This should show a new `ami-XXXXXX` ID (build-ami.sh updates the SSM
parameter automatically). The previous AMI (`ami-0b87926a60df7043e`)
remains in your account but is no longer pointed-to.

### Step 5 — verify the new AMI is well-formed

Spin up a one-off instance from it for a sanity check:

```bash
NEW_AMI=$(aws ssm get-parameter --name /nf-reads-profiler/ami-id \
  --region us-east-2 --query 'Parameter.Value' --output text)

aws ec2 run-instances --region us-east-2 \
  --image-id "$NEW_AMI" \
  --instance-type r6g.large \
  --iam-instance-profile Name=nf-reads-profiler-ecs-instance-profile \
  --subnet-id subnet-09159c654acc505a3 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ami-v2-smoke},{Key=Project,Value=nf-reads-profiler}]' \
  --query 'Instances[0].InstanceId' --output text
```

> **Note**: the `aws ec2 run-instances` guardrail in `.claude/hooks/guardrails.sh`
> hard-blocks this command. Run it yourself, OR temporarily allowlist
> for this one purpose.

SSM into it, verify:
```bash
ls /mnt/dbs/metaphlan_databases/vJan25/*.bt2l    # PHASE 1: should exist now (prepared form)
ls /mnt/dbs/metaphlan_databases/vOct22/         # vOct22 dir still has S3-synced .bz2 files (unchanged)
sudo cat /var/log/nf-userdata.log                # should show vJan25 warmup ran
free -h                                           # buff/cache should show ~34 GB hot (vJan25)
```

Terminate when satisfied:
```bash
aws ec2 terminate-instances --region us-east-2 --instance-ids <id>
```

### Step 6 — redeploy the CFN stack

The stack template change (UserData warmup) needs a deploy to take effect:

```bash
cd /home/ubuntu/github/nf-reads-profiler
aws cloudformation deploy \
  --stack-name nf-reads-profiler-batch \
  --template-file infra/batch-stack.yaml \
  --parameter-overrides \
    EcsAmiId="$(aws ssm get-parameter --name /nf-reads-profiler/ami-id --region us-east-2 --query 'Parameter.Value' --output text)" \
    DbSourceBucket=cjb-gutz-s3-demo \
    BudgetAlertEmail=colin@vasogo.com \
    MonthlyBudgetThreshold=100 \
    SpotBidPercentage=70 \
    MaxvCPUsSpot=16 \
    MaxvCPUsOnDemand=8 \
    ProjectTag=nf-reads-profiler \
    EnvironmentTag=development \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-2
```

I'll prepare this command exactly; do **not** add `MonthlyBudgetThreshold=200`
(your live budget is already $100 which is tighter — leave that as is).

### Step 7 — re-arm I16 max005 with the new image

```bash
screen -dmS nf -L -Logfile logs/max005-amiv2-$(date -u +%Y%m%d-%H%M%S).log bash -lc '
  bash infra/max005_test.sh max005-20260427-203146
  echo "=== exited $? at $(date -u) ==="
  exec bash
'
```

(Resume with the same project name to keep cache hits from the prior
attempt's upstream stages.)

---

## Rollback (only if AMI v2 is broken)

If anything in steps 4-7 goes wrong:

```bash
# Point SSM back at the old AMI:
aws ssm put-parameter --name /nf-reads-profiler/ami-id \
  --value ami-0b87926a60df7043e --type String --overwrite \
  --region us-east-2

# Redeploy the stack with the old AMI:
# (rerun the deploy command from step 6, EcsAmiId resolves from SSM)
```

---

## What Phase 1 does NOT solve (deliberately deferred)

- **vOct22 cold-fault on `profile_function`** — Phase 2 will extend this
  same pattern (move to biobakery + UserData warmup) to vOct22 once
  Phase 1 is validated. Until then, `profile_function` first task per
  worker keeps its current ~30 min cold-fault cost.
- **chocophlan cold-fault** — not worth pre-warming all 42 GB; per-clade
  active set is much smaller and faults in proportionally fast. Revisit
  if measurement shows otherwise.
- **CPU clamping** (bowtie2 `-p 8` clamped to ~3 by container cpuset) —
  separate bottleneck, fixes are `process.cpus = 8` and/or `r6g.4xlarge`.
- **Spot reclamation** — `process.maxRetries = 5` already handles this;
  out of scope here.
- **MEDI on AWS** — broken on a different axis (path mismatch in
  `nextflow.config`); not addressed by this AMI.
- **DbSourceBucket runtime cleanup (I15)** — independent stack-only
  change; can land any time. The bucket-content cleanup
  (`metaphlan_databases/*` deletion) waits until Phase 2 also moves
  vOct22 to biobakery.

---

## Acceptance criteria

- [ ] AMI v2 published to SSM `/nf-reads-profiler/ami-id`.
- [ ] Sanity-check instance shows prepared `.bt2l` files in
      `/mnt/dbs/metaphlan_databases/vJan25/` (vOct22 still holds the
      S3-synced `.bz2` files — that's expected for Phase 1).
- [ ] `/var/log/nf-userdata.log` on the sanity instance shows the
      vJan25 warmup ran successfully.
- [ ] CFN stack redeploys cleanly.
- [ ] Re-resumed I16 max005 run completes within 90 min wallclock and
      passes all per-sample assertions.
- [ ] First `profile_taxa` task on a fresh worker reaches the actual
      alignment phase within 1-2 min (vs ~12 min today on the
      decompression step).
