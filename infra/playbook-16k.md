# Production Playbook: Running 16,000 Samples through nf-reads-profiler

This playbook documents the end-to-end process for running 16,000 samples through the nf-reads-profiler pipeline on AWS Batch. The target budget is $16,000 USD (~$1/sample), and the infrastructure is optimized for cost and resume-ability.

## Prerequisites

Before starting, ensure:

1. **CloudFormation stack deployed:** `nf-reads-profiler-batch` in `us-east-2` (see `infra/readme.md` Part 1 & 2)
2. **Head-node runner VM:** r8g.2xlarge EC2 instance with runner policy attached
3. **Samplesheet prepared:** 16,000-row CSV in S3 (`s3://gutz-nf-reads-profilers-runs/samplesheets/<name>.csv`)
4. **Database sync verified:** Recent workers show successful S3 sync to `/mnt/dbs/` in CloudWatch logs
5. **Pilot run completed:** Confirm metrics from a small pilot (100–500 samples) to validate cost assumptions

---

## Phase 1: Pre-flight Checklist (Day 0)

Complete these checks before kicking off the production run. Each step is reversible; the run doesn't start until all are verified.

### 1. Validate Samplesheet

On the runner VM, validate the 16K CSV against the schema:

```bash
# Check CSV structure
head samplesheet-16k.csv
wc -l samplesheet-16k.csv  # Should show ~16001 (header + 16000 samples)

# Spot-check for missing required columns
awk -F, 'NR==1 {print; for(i=1;i<=NF;i++) if($i ~ /fastq_1|ERS|SRR|ERR/) found++; if(found==0) {print "FATAL: no data columns found"; exit 1}}' samplesheet-16k.csv

# Upload to S3 if not already there
aws s3 cp samplesheet-16k.csv s3://gutz-nf-reads-profilers-runs/samplesheets/samplesheet-16k.csv
```

### 2. Verify Batch Infrastructure Health

```bash
# Check job queue is ENABLED
aws batch describe-job-queues --job-queues spot-queue --region us-east-2 \
  --query "jobQueues[0].{State:state,Status:status}" --output text

# Expected output: ENABLED  VALID

# Check both compute environments are VALID
aws batch describe-compute-environments --region us-east-2 \
  --query "computeEnvironments[].{Name:computeEnvironmentName,State:state,Status:status}" \
  --output text

# Expected output: two lines, both with ENABLED VALID
```

**If either shows INVALID:** See `infra/readme.md` Part 3 for troubleshooting.

### 3. Verify S3 Buckets Are Accessible

```bash
# Workdir bucket (must be accessible but can be non-empty from prior runs)
aws s3 ls s3://gutz-nf-reads-profilers-workdir/ --region us-east-2 | head

# Runs bucket (should contain your samplesheet)
aws s3 ls s3://gutz-nf-reads-profilers-runs/samplesheets/ --region us-east-2 | grep samplesheet-16k

# If samplesheet is missing, upload it:
# aws s3 cp samplesheet-16k.csv s3://gutz-nf-reads-profilers-runs/samplesheets/
```

### 4. Verify Runner IAM Policy Is Attached

```bash
aws iam list-attached-role-policies --role-name head-node-role --region us-east-2 \
  --query "AttachedPolicies[?contains(PolicyName, 'runner-policy')].PolicyName" --output text

# Expected output: nf-reads-profiler-nextflow-runner-policy
```

### 5. Check Pilot Run Metrics (from I09 or recent test)

Collect data from your pilot run to confirm cost assumptions:

```bash
# Download the trace file from the pilot
aws s3 cp "s3://gutz-nf-reads-profilers-runs/results/<pilot_project>/reports/*_trace.txt" . --region us-east-2

# Analyze by process type (MetaPhlAn, HUMAnN, etc.)
awk -F'\t' 'NR>1 {gsub(/.*_/,"",$1); print $1, $5}' *_trace.txt | sort | uniq | head -20
# Columns: process_name, exit_status (0=success, other=failure/timeout)

# Calculate average runtimes for HUMAnN (usually the bottleneck)
awk -F'\t' 'NR>1 && /profile_function/ {print $5}' *_trace.txt | sort -n | tail -1
# Shows the longest HUMAnN task duration
```

From the pilot, confirm:
- **Cost per sample:** $0.80–1.20 (target: ~$1)
- **HUMAnN runtime per sample:** 4–6 hours on r8g.2xlarge spot
- **Failure rate:** <1% for network/timeout; 0% for OOM (resourceLimits should prevent this)
- **Spot interruption rate:** <5% (normal for spot; covered by `-resume`)

### 6. Increase CloudFormation Budget Parameter

Raise the monthly budget threshold from dev (typically $200–500) to production ($16,000):

```bash
# Get the current stack to see all parameters
aws cloudformation describe-stacks --stack-name nf-reads-profiler-batch --region us-east-2 \
  --query "Stacks[0].Parameters[?ParameterKey=='MonthlyBudgetThreshold'].ParameterValue" --output text

# Update with new budget
aws cloudformation deploy \
  --stack-name nf-reads-profiler-batch \
  --template-file infra/batch-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-2 \
  --parameter-overrides MonthlyBudgetThreshold=16000 \
  --no-execute-changeset

# Review the change set, then execute:
CHANGESET=$(aws cloudformation describe-change-set \
  --stack-name nf-reads-profiler-batch \
  --change-set-name awscli-changeset-* \
  --region us-east-2 --query 'ChangeSetId' --output text | tail -1)

aws cloudformation execute-change-set --change-set-name "$CHANGESET" --region us-east-2
aws cloudformation wait stack-update-complete --stack-name nf-reads-profiler-batch --region us-east-2
```

### 7. Increase MaxvCPUsSpot (if needed)

If your pilot used MaxvCPUsSpot=16 and found that samples were queued for >30 min, increase it:

```bash
# Review current setting
aws batch describe-compute-environments --region us-east-2 \
  --query "computeEnvironments[?contains(computeEnvironmentName, 'Spot')].computeResources.maxvCpus" --output text

# If 16, increase to 256 or 512 depending on pilot queue depth:
# - 256 vCPU = up to 32 r8g.2xlarge spot instances (typical sweet spot)
# - 512 vCPU = up to 64 instances (max parallelism, higher cost spike risk)

aws cloudformation deploy \
  --stack-name nf-reads-profiler-batch \
  --template-file infra/batch-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-2 \
  --parameter-overrides MaxvCPUsSpot=256 \
  --no-execute-changeset

# Review and execute
CHANGESET=$(aws cloudformation describe-change-set \
  --stack-name nf-reads-profiler-batch \
  --change-set-name awscli-changeset-* \
  --region us-east-2 --query 'ChangeSetId' --output text | tail -1)

aws cloudformation execute-change-set --change-set-name "$CHANGESET" --region us-east-2
aws cloudformation wait stack-update-complete --stack-name nf-reads-profiler-batch --region us-east-2
```

### 8. Update `conf/aws_batch.config` for Production

Make two critical changes:

**Change A: Enable cleanup (prevent 30–80 TB of intermediate files)**

```bash
# Edit conf/aws_batch.config
# Line 2: change `cleanup = true` (if it's not already)
# This is already set in the current config, but confirm:
grep "^cleanup" conf/aws_batch.config
# Expected: cleanup = true
```

**Change B: Set error strategy to `finish` (let in-flight tasks complete on failure)**

```bash
# Edit conf/aws_batch.config
# In the `process` block, add or update:
# errorStrategy = 'finish'

# Check if it's already set:
grep "errorStrategy" conf/aws_batch.config

# If not present, add it:
cat >> conf/aws_batch.config << 'EOF'

// Production: finish allows in-flight tasks to complete; failed sample is skipped
process.errorStrategy = 'finish'
EOF
```

Then verify the file is syntactically correct:

```bash
nextflow config conf/aws_batch.config > /dev/null 2>&1 && echo "Config OK" || echo "Config ERROR"
```

### 9. Verify `output_exists()` Function

This function is the **only** resume mechanism that works with `cleanup = true`. Confirm it's present and correct:

```bash
# Check main.nf for the output_exists function
grep -A 10 "def output_exists" main.nf

# Expected: Function checks for final outputs in S3 (e.g., metaphlan_profile, genefamilies TSV)
# The function should call aws s3 ls to check if final files exist for a sample
```

If the function is missing or broken:
- See issue I06 in the issues directory
- Do not proceed until fixed — the run will retry all samples on resume, defeating efficiency

### 10. Confirm SNS Subscription (Alarms)

Verify you're subscribed to CloudWatch alarms and budget alerts:

```bash
# List SNS topics
aws sns list-topics --region us-east-2 --query "Topics[?contains(TopicArn, 'nf-reads-profiler')].TopicArn" --output text

# Check subscription status
TOPIC_ARN=$(aws sns list-topics --region us-east-2 --query "Topics[?contains(TopicArn, 'nf-reads-profiler')].TopicArn" --output text | head -1)
aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --region us-east-2 \
  --query "Subscriptions[?Endpoint=='$(aws sts get-caller-identity --query Arn --output text)']"

# If subscription shows "PendingConfirmation", check your email and confirm.
# After confirmation, subscription status should be "Subscribed"
```

**Monitoring channels:**
- **Budget alerts:** Fires at 80% actual and 100% forecasted spend
- **Batch alarms:** `batch-failed-jobs` (≥5 failures in 5 min), `batch-high-pending` (≥50 pending for 15 min)

### 11. Check Database Sync (Spot Instance Example)

Confirm that a recently launched worker successfully synced databases from S3 to `/mnt/dbs/`:

```bash
# View Batch logs for the most recent job
aws logs tail /aws/batch/job --follow --region us-east-2 --filter-pattern "Download" | head -50

# Look for lines like:
# download: s3://..../metaphlan_databases/... to /mnt/dbs/metaphlan_databases/...
# download: s3://..../chocophlan_v4_alpha/ to /mnt/dbs/chocophlan_v4_alpha/
```

If no downloads appear:
- Check that the Launch Template's UserData script is correct (see `infra/batch-stack.yaml`)
- Verify worker IAM role has `s3:GetObject` permission on the database bucket
- Check worker instance storage (`/mnt/` directory)

---

## Phase 2: Kickoff (Day 1)

Once all pre-flight checks pass, you're ready to launch the production run.

### Command

Run on the head-node runner VM:

```bash
# Navigate to repo root
cd /home/ubuntu/github/nf-reads-profiler

# Launch the pipeline
nextflow run main.nf \
  -profile aws \
  --input s3://gutz-nf-reads-profilers-runs/samplesheets/samplesheet-16k.csv \
  --project production-16k \
  -resume
```

**Key flags:**
- `-profile aws` — Uses `conf/aws_batch.config` (spot queue, S3 work dir, `/mnt/dbs/` for databases)
- `--input s3://...` — Points to your 16K samplesheet (can be local path instead)
- `--project production-16k` — Organizes results in `outdir/production-16k/<run>/...`
- `-resume` — Reuses Nextflow cache if restarting; with `cleanup = true`, only `output_exists()` skips completed samples

**Expected output (first lines):**
```
N E X T F L O W  ~  version 23.x.x
executor > awsbatch
[...]
Submitted process > profile_taxa (...)
Submitted process > profile_taxa (...)
[...]
```

### Monitor Submission

In a separate terminal, monitor job submissions:

```bash
# Watch Batch console (real-time)
watch -n 5 "aws batch list-jobs --job-queue spot-queue --job-status RUNNING,PENDING,SUBMITTED \
  --region us-east-2 --query 'jobSummaryList | length(@)'"

# Expected progression:
# Minute 1–5: SUBMITTED count climbs to 100–200
# Minute 5–30: RUNNING count climbs to 20–50
# Minute 30+: Roughly constant RUNNING count (parallelism limited by MaxvCPUsSpot)
```

---

## Phase 3: Monitoring During Run (Days 1–10)

The 16K sample run will take **7–14 days** depending on:
- Spot availability and spot interruption rate
- HUMAnN runtimes (4–6h per sample is typical)
- Failure rate and resume patterns

### 3.1 CloudWatch Dashboard

Open the monitoring dashboard:

```bash
# Get the dashboard URL
aws cloudformation describe-stacks --stack-name nf-reads-profiler-batch --region us-east-2 \
  --query "Stacks[0].Outputs[?OutputKey=='DashboardUrl'].OutputValue" --output text --region us-east-2

# Example output:
# https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards/dashboard/nf-reads-profiler-batch
```

**Key widgets to monitor:**
- **Spot vCPU capacity:** Should ramp to MaxvCPUsSpot and stay near that ceiling
- **Pending jobs:** Should stay <50 (if higher, increase MaxvCPUsSpot or reduce other workloads)
- **Failed jobs (5-min):** Spike indicates systemic issue (bad image, DB sync, etc.)
- **On-demand fallback:** Should be minimal; if high, spot capacity is exhausted (temporary or persistent)

### 3.2 Batch Console

Check job queue depth and failure patterns:

```bash
# Overview: running + pending + submitted counts
aws batch list-jobs --job-queue spot-queue --job-status RUNNING,PENDING,SUBMITTED --region us-east-2 \
  --query "jobSummaryList | { running: length(@[?status=='RUNNING']), pending: length(@[?status=='PENDING']), submitted: length(@[?status=='SUBMITTED']) }"

# List recent failures (last 24 hours)
aws batch list-jobs --job-queue spot-queue --job-status FAILED --region us-east-2 \
  --query "jobSummaryList[-20:].[jobId,jobName,statusReason]" --output text

# For a specific failed job, get details:
# aws batch describe-jobs --jobs <jobId> --region us-east-2
```

### 3.3 Live Logs

Tail application logs to see what samples are being processed:

```bash
# Follow logs for all jobs
aws logs tail /aws/batch/job --follow --region us-east-2 | head -100

# Filter for a specific sample
aws logs tail /aws/batch/job --follow --region us-east-2 --filter-pattern "SAMPLE_NAME" | head -100

# Filter for errors
aws logs tail /aws/batch/job --follow --region us-east-2 --filter-pattern "ERROR" | head -50
```

### 3.4 Periodic Trace File Inspection

Every 24–48 hours, download and inspect the Nextflow trace file:

```bash
# Download the latest trace
aws s3 cp "s3://gutz-nf-reads-profilers-runs/results/production-16k/reports/" . \
  --region us-east-2 --exclude "*" --include "*_trace.txt" --recursive

# Get latest one
TRACE=$(ls -t *_trace.txt | head -1)

# Quick health checks
echo "=== Summary ==="
tail -5 "$TRACE"

echo "=== Failed tasks ==="
grep "FAILED" "$TRACE" | head -10

echo "=== Out of Memory (exit 137) ==="
grep "exit.*137" "$TRACE" | wc -l

echo "=== Timeouts (exit 124) ==="
grep "exit.*124" "$TRACE" | wc -l

echo "=== Total completed ==="
awk -F'\t' 'NR>1 && $5==0 {print}' "$TRACE" | wc -l

echo "=== Average HUMAnN runtime ==="
awk -F'\t' 'NR>1 && /profile_function/ && $5==0 {sum+=$5; count++} END {if(count>0) print sum/count}' "$TRACE"
```

### 3.5 Handling Common Issues During Run

#### A. Single Sample Failure

If 1–2 samples fail sporadically:

```bash
# This is normal for spot + long-running tasks. Monitor and move on.
# With errorStrategy = 'finish', the run continues.
# After the full run completes, you can re-run failed samples:
# nextflow run main.nf -profile aws --input <samplesheet> --project production-16k-retry -resume
```

#### B. Mass Failures (5+ in 5 min)

If the `batch-failed-jobs` alarm fires:

1. **Check for systemic issue:**

```bash
# Recent failed job details
aws batch list-jobs --job-queue spot-queue --job-status FAILED --region us-east-2 \
  --query "jobSummaryList[-10:].statusReason" --output text | sort | uniq -c

# Look for patterns like:
#   - "ECRAuthorizationException" → Docker image pull failure
#   - "OutOfMemory" → resourceLimits not working (investigate)
#   - "Task killed" → Spot interruption (expected; resume will retry)
```

2. **If it's an image pull error:**

```bash
# Verify Docker image is accessible and built for ARM64
docker pull public.ecr.aws/r5f/nextflow:... --platform linux/arm64

# If the image is broken, fix it and redeploy
```

3. **If it's a database sync error:**

```bash
# SSH into a worker (from Batch console) and check:
ls -la /mnt/dbs/
# Should have: metaphlan_databases/, chocophlan_v4_alpha/, uniref90_annotated_v4_alpha_ec_filtered/, etc.

# If missing, check the Launch Template's UserData logs:
# /var/log/cloud-init-output.log
```

4. **If the cause is transient (network blip):**

- Wait 5–10 minutes; jobs may recover
- If failures persist, consider pausing the run and troubleshooting

#### C. Spot Interruptions

Spot interruptions are expected. With `maxRetries = 0` in the config:

```bash
# Interrupted jobs fail permanently but sample is skipped (not fatal)
# The run continues with remaining samples
# Post-run, re-run failed samples with -resume and same --project

# To monitor interruption rate:
aws batch describe-compute-environments --region us-east-2 \
  --query "computeEnvironments[?contains(computeEnvironmentName, 'Spot')].computeResources.spotIamFleetRole" --output text
# No direct metric; check CloudWatch for "Spot interruption notices"
```

#### D. High Pending Queue (>50 for >15 min)

This means spot + on-demand capacity is exhausted. Options:

```bash
# Option 1: Temporary increase to MaxvCPUsOnDemand (more cost, faster completion)
aws cloudformation deploy \
  --stack-name nf-reads-profiler-batch \
  --template-file infra/batch-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-2 \
  --parameter-overrides MaxvCPUsOnDemand=32 \
  --no-execute-changeset
# Review and execute the changeset

# Option 2: Wait for spot capacity to free up (cheaper, slower)
# Monitor with: watch -n 5 'aws batch list-jobs --job-queue spot-queue --job-status PENDING ...'
```

#### E. Head Node Crash / Network Interruption

If the runner VM loses connectivity or crashes:

```bash
# Simply re-run the same command on the (reconnected) runner:
nextflow run main.nf \
  -profile aws \
  --input s3://gutz-nf-reads-profilers-runs/samplesheets/samplesheet-16k.csv \
  --project production-16k \
  -resume

# Nextflow will:
# 1. Check workDir (S3) for cached task outputs (if cleanup=false)
# 2. Call output_exists() for each sample to skip fully completed ones
# 3. Resume in-flight or failed tasks from scratch
```

---

## Phase 4: Post-Run Analysis & Cleanup (Day 10+)

After the pipeline completes (all samples processed or run stopped):

### 4.1 Verify Output Count

```bash
# MetaPhlAn profiles
aws s3 ls "s3://gutz-nf-reads-profilers-runs/results/production-16k/*/taxa/" --recursive --region us-east-2 | wc -l
# Expected: ~16,000 files (1 per sample)

# HUMAnN functional profiles
aws s3 ls "s3://gutz-nf-reads-profilers-runs/results/production-16k/*/function/" --recursive --region us-east-2 | wc -l
# Expected: 16,000 × 3 = 48,000 files (genefamilies, pathabundance, pathcoverage per sample)
```

### 4.2 Download & Analyze Trace File

```bash
# Download final trace
aws s3 cp "s3://gutz-nf-reads-profilers-runs/results/production-16k/reports/" . \
  --region us-east-2 --exclude "*" --include "*_trace.txt" --recursive

TRACE=$(ls -t *_trace.txt | head -1)

# Summary statistics
echo "=== Completion Status ==="
awk -F'\t' 'NR==1 {for(i=1;i<=NF;i++) if($i=="exit_status") col=i} NR>1 {
  if($col==0) ok++; 
  else if($col==137) oom++; 
  else if($col==124) timeout++; 
  else fail++
} END {
  total = ok + oom + timeout + fail
  print "Total:", total
  print "Success:", ok, "(" int(ok/total*100) "%)"
  print "OOM (137):", oom, "(" int(oom/total*100) "%)"
  print "Timeout (124):", timeout, "(" int(timeout/total*100) "%)"
  print "Other failures:", fail, "(" int(fail/total*100) "%)"
}' "$TRACE"

# Cost estimation (requires external pricing data)
# Example: if average task time is 4 hours on r8g.2xlarge spot at $0.07/hr:
# Cost per sample ≈ 4h × $0.07 = $0.28 + overhead ≈ $1/sample
echo "=== Average Task Duration (seconds) ==="
awk -F'\t' 'NR==1 {for(i=1;i<=NF;i++) if($i=="realtime") col=i} NR>1 {sum+=$col; count++} END {if(count>0) print sum/count, "seconds", "(" int(sum/count/3600), "hours)"}' "$TRACE"
```

### 4.3 Cost Analysis

After the run, use AWS Cost Explorer to calculate actual spend:

```bash
# View cost breakdown by service for resources tagged Project=nf-reads-profiler
# https://us-east-2.console.aws.amazon.com/cost-management/home#/custom
# Filter by:
#   - Service = EC2 (compute)
#   - Tag: Project = nf-reads-profiler
#   - Date Range = [start of run] to [end of run]

# Total cost should be within the $16K budget
# Breakdown:
# - EC2 spot instances: ~$12-15K (primary cost driver)
# - S3 workdir storage: ~$500-2K (30-day lifecycle mitigates this)
# - S3 runs storage: <$100 (results are small text files)
# - CloudWatch/Batch: <$100
```

### 4.4 Scale Down (Reset for Next Run)

Lower MaxvCPUsSpot and MonthlyBudgetThreshold back to development values:

```bash
aws cloudformation deploy \
  --stack-name nf-reads-profiler-batch \
  --template-file infra/batch-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-2 \
  --parameter-overrides \
    MaxvCPUsSpot=16 \
    MonthlyBudgetThreshold=500 \
  --no-execute-changeset

# Review and execute the changeset
CHANGESET=$(aws cloudformation describe-change-set \
  --stack-name nf-reads-profiler-batch \
  --change-set-name awscli-changeset-* \
  --region us-east-2 --query 'ChangeSetId' --output text | tail -1)

aws cloudformation execute-change-set --change-set-name "$CHANGESET" --region us-east-2
aws cloudformation wait stack-update-complete --stack-name nf-reads-profiler-batch --region us-east-2
```

### 4.5 Optional: Delete Stack (Full Cleanup)

If you won't be running the pipeline again soon and want to stop all billing:

```bash
# Step 1: Detach runner policy
aws iam detach-role-policy \
  --role-name head-node-role \
  --policy-arn arn:aws:iam::730883236839:policy/nf-reads-profiler-nextflow-runner-policy

# Step 2: Delete the stack (workdir bucket deleted; runs bucket retained)
aws cloudformation delete-stack \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2

aws cloudformation wait stack-delete-complete \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2

# Results persist in s3://gutz-nf-reads-profilers-runs/ (DeletionPolicy: Retain)
# Workdir bucket (intermediate files) is deleted
```

---

## Appendix: Key Configuration Parameters

### `conf/aws_batch.config` Production Settings

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `cleanup` | `true` | Delete intermediate files after task completion (prevent 30–80 TB accumulation) |
| `errorStrategy` | `finish` | Complete in-flight tasks on failure; don't kill everything |
| `maxRetries` | `0` | No automatic retries (save budget; use `-resume` for re-runs) |
| `resourceLimits.cpus` | `8` | Cap per-task CPU usage (prevents runaway memory) |
| `resourceLimits.memory` | `64.GB` | Absolute memory ceiling per task |
| `resourceLimits.time` | `2.h` | Wall-time limit per task |
| `executor.submitRateLimit` | `10/s` | Rate-limit Batch job submissions (avoid API throttling) |
| `executor.queueSize` | `200` | Max queued tasks waiting for executor |

### `batch-stack.yaml` Production Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `MaxvCPUsSpot` | `256` | Max parallelism (32 r8g.2xlarge instances) |
| `MaxvCPUsOnDemand` | `64` | On-demand fallback (cost safety net) |
| `MonthlyBudgetThreshold` | `16000` | Budget alert threshold in USD |
| `SpotBidPercentage` | `70` | Bid 70% of on-demand (comfortable margin for Graviton) |

### Database Paths

All databases must be synced to `/mnt/dbs/` on each worker before the run starts. The Launch Template's UserData handles this via `aws s3 sync` during EC2 initialization. Database paths are fixed in `conf/aws_batch.config`:

```
direct_metaphlan_db               = /mnt/dbs/metaphlan_databases/vJan25/
humann_metaphlan_db        = /mnt/dbs/metaphlan_databases/vOct22/
humann_chocophlan                 = /mnt/dbs/chocophlan_v4_alpha/
humann_uniref                     = /mnt/dbs/uniref90_annotated_v4_alpha_ec_filtered/
humann_utilitymap            = /mnt/dbs/full_mapping_v4_alpha/
```

---

## Appendix: Runbook for Resume After Interruption

If the run is interrupted mid-flight (head-node crash, cancellation, etc.), resume it:

```bash
# 1. SSH back into the runner VM
# 2. Navigate to the repo
cd /home/ubuntu/github/nf-reads-profiler

# 3. Re-run with the exact same command and -resume flag
nextflow run main.nf \
  -profile aws \
  --input s3://gutz-nf-reads-profilers-runs/samplesheets/samplesheet-16k.csv \
  --project production-16k \
  -resume

# Nextflow will:
# - Re-parse the samplesheet
# - For each sample, call output_exists() to check if final outputs exist in S3
# - Skip any fully completed samples
# - Resume or restart partially completed samples
```

**Resume efficiency depends on `output_exists()`:**
- If the function is correct, >99% of samples are skipped on resume
- If the function is missing/broken, all samples restart from scratch (wasting time/money)

---

## Appendix: Estimated Budget Breakdown (16K samples)

Based on pilot metrics (~$1/sample target):

| Component | Est. Cost | % of Total |
|-----------|-----------|-----------|
| Spot EC2 (primary) | $12,800 | 80% |
| On-demand fallback | $1,000 | 6% |
| S3 workdir storage | $1,000 | 6% |
| S3 runs storage | $100 | 1% |
| CloudWatch/Batch | $100 | 1% |
| **Total** | **~$15,000** | **100%** |

This assumes:
- 16,000 samples
- ~4–6 hours per sample (HUMAnN bottleneck) on r8g.2xlarge spot (~$0.07/hr)
- <1% failure rate
- ~5% spot interruption rate (retried on second attempt via `-resume`)

**Variance:** Actual cost may be 10–20% higher or lower depending on:
- Spot/on-demand price swings
- Database size (sync cost)
- Failure rate and retry storms
- Workdir cleanup effectiveness

---

## References

- **Infra setup:** `infra/readme.md` Parts 1–4
- **Pipeline code:** `main.nf`, `conf/aws_batch.config`
- **Troubleshooting:** `infra/readme.md` Part 3
- **Databases:** `README.md` (database download commands)
- **Cost estimation:** AWS Cost Explorer, CloudWatch metrics

