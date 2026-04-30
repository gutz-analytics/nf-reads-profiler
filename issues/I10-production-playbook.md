# I10: Create production playbook for the 16K-sample run

**Priority:** Low — last to land; blocked on all prior issues and pilot validation
**Size:** Small
**Files to create:** `infra/playbook-16k.md`
**Dependencies:** I00, I01, I02, I03, I04, I05, I06, I07, I08, I09 (all must be merged and verified before this playbook is used)

---

## Context

After the pilot run validates end-to-end pipeline correctness and per-sample cost/time, the full 16K-sample cohort can be submitted. This issue creates `infra/playbook-16k.md` — a self-contained operator guide for that production run. The playbook assumes all infrastructure issues (I00–I09) are resolved and the pilot has produced timing data needed to right-size the compute environment.

---

## Playbook contents

`infra/playbook-16k.md` must cover all five sections below.

---

### 1. Pre-flight checklist

The checklist must be a markdown task list that an operator can tick off before submitting:

**Code and infra readiness:**
- [ ] All issues I00–I09 are merged to `main` and the head-node runner has pulled `main`
- [ ] A pilot run (representative subset — e.g., 50–100 samples) has completed successfully and produced expected outputs in `s3://gutz-nf-reads-profilers-runs/results/`
- [ ] Pilot trace file (`*_trace.txt`) has been reviewed; per-sample wall-clock time and peak memory are recorded

**Compute scaling — `MaxvCPUsSpot`:**

Raise the spot vCPU ceiling before submitting. The formula for picking a value:

```
target_wall_time_hours = desired total wall-clock hours for the cohort
per_sample_time_hours  = median per-sample time from pilot trace
vcpus_per_job          = cpus set in aws_batch.config (currently 4)

MaxvCPUsSpot = ceil(16000 / target_wall_time_hours * per_sample_time_hours * vcpus_per_job)
```

Constrain by budget: at ~$0.05–0.10/vCPU-hour (Graviton spot), every 100 vCPUs running continuously for a week costs roughly $800–1600. Choose a ceiling that fits the approved budget envelope.

Update the stack with the chosen value:

```bash
# Retrieve current AMI (required for redeploy)
EcsAmiId=$(aws ec2 describe-images --region us-east-2 --owners amazon \
  --filters "Name=name,Values=al2023-ami-ecs-hvm-*-kernel-*-arm64" \
            "Name=state,Values=available" \
  --query 'Images | sort_by(@,&CreationDate) | [-1].ImageId' --output text)

aws cloudformation deploy \
  --stack-name nf-reads-profiler-batch \
  --template-file infra/batch-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-2 \
  --parameter-overrides \
    VpcId=vpc-06ad1e39bb8cd26df \
    SubnetIds="subnet-09159c654acc505a3,subnet-03afe111356916511,subnet-0d0f1d152c1656677" \
    WorkDirBucketName=gutz-nf-reads-profilers-workdir \
    RunsBucketName=gutz-nf-reads-profilers-runs \
    DbSourceBucket=cjb-gutz-s3-demo \
    BudgetAlertEmail=colin@vasogo.com \
    MonthlyBudgetThreshold=16000 \
    SpotBidPercentage=70 \
    MaxvCPUsSpot=<TBD_from_formula> \
    MaxvCPUsOnDemand=8 \
    ProjectTag=nf-reads-profiler \
    EnvironmentTag=production \
    EcsAmiId="$EcsAmiId"
```

- [ ] `MaxvCPUsSpot` raised from 16 to `<computed value>` and CloudFormation update has completed (status: `UPDATE_COMPLETE`)

**Budget threshold:**
- [ ] `MonthlyBudgetThreshold` raised from $200 to $16,000 (included in the deploy command above)
- [ ] Confirm budget alert email (`colin@vasogo.com`) is correct and the SNS subscription is confirmed

**`cleanup = true` — must be enabled:**

`conf/aws_batch.config` sets `cleanup = true`, which causes Nextflow to delete intermediate work files from `s3://gutz-nf-reads-profilers-workdir` once a sample finishes. This is required for production to avoid TB-scale accumulation in the workdir bucket. If `cleanup` was set to `false` during any debugging phase (per I06), it must be re-enabled before this run.

- [ ] Confirm `cleanup = true` is set in `conf/aws_batch.config` (search: `grep cleanup conf/aws_batch.config`)

**Queue and cluster state:**
- [ ] No stale jobs in the Batch queue from previous runs:

  ```bash
  for status in SUBMITTED PENDING RUNNABLE STARTING RUNNING; do
    echo "=== $status ==="
    aws batch list-jobs --job-queue spot-queue --job-status $status \
      --region us-east-2 --output text --query 'jobSummaryList[].jobName' | head -5
  done
  ```

  Expected: no output for any status.

- [ ] Workdir bucket is empty or contains only items from the current run (30-day lifecycle will clean prior runs, but confirm no unexpected large objects):

  ```bash
  aws s3 ls s3://gutz-nf-reads-profilers-workdir --recursive --human-readable --summarize \
    | tail -2
  ```

**Head-node runner resources:**
- [ ] Head-node instance (`r8g.2xlarge`: 64 GB RAM, 8 vCPU) has sufficient free disk for Nextflow's local cache and 16K job tracking. Check:

  ```bash
  df -h $HOME
  free -h
  ```

  Nextflow's `.nextflow/` directory grows with job history; ensure at least 20 GB free on the home filesystem.

- [ ] Samplesheet is uploaded and accessible:

  ```bash
  aws s3 ls s3://gutz-nf-reads-profilers-runs/samplesheets/<name>.csv
  ```

---

### 2. Kickoff command

```bash
# Screen or tmux strongly recommended — this run may take days
screen -S production-16k

nextflow run main.nf \
  -profile aws \
  --input s3://gutz-nf-reads-profilers-runs/samplesheets/<samplesheet>.csv \
  --project <project_name> \
  -resume
```

The `-resume` flag is safe to include on the initial submission; if the workdir is empty it has no effect. Keep the session alive — Nextflow's head process must run continuously for the duration.

---

### 3. Monitoring

**CloudWatch dashboard** (live cost, vCPU utilization, job queue depth):

```
https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards/dashboard/nf-reads-profiler-batch?start=PT72H
```

Retrieve the URL programmatically:

```bash
aws cloudformation describe-stacks \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2 \
  --query "Stacks[0].Outputs[?OutputKey=='DashboardURL'].OutputValue" \
  --output text
```

**Job queue status** — snapshot of active work:

```bash
# Jobs in each state
for status in SUBMITTED PENDING RUNNABLE STARTING RUNNING FAILED SUCCEEDED; do
  count=$(aws batch list-jobs --job-queue spot-queue --job-status $status \
    --region us-east-2 --query 'length(jobSummaryList)' --output text 2>/dev/null)
  echo "$status: $count"
done
```

**Individual job logs** — tail a specific job's container output:

```bash
# Replace <log-stream-name> with the value from the Batch console or list-jobs detail
aws logs tail /aws/batch/job \
  --log-stream-name <log-stream-name> \
  --follow \
  --region us-east-2
```

**What to watch for:**

| Signal | Threshold | Action |
|--------|-----------|--------|
| FAILED job count | >5% of submitted | Review logs; check for OOM or DB sync failures |
| PENDING backlog > 500 for > 30 min | Capacity starvation | Temporarily raise `MaxvCPUsSpot`; check spot AZ availability |
| Spot interruption rate | >20% | Consider raising `SpotBidPercentage` or enabling more instance families |
| Monthly spend | Approaching $16K budget | Pause submission; re-evaluate pace |
| Workdir bucket size | >10 TB | Verify `cleanup = true` is active; investigate stalled samples |

**Nextflow trace file** — written incrementally during the run:

```bash
# Path matches params.outdir / params.project / reports / <timestamp>_trace.txt
aws s3 ls "s3://gutz-nf-reads-profilers-runs/results/<project>/reports/" \
  | grep trace
```

---

### 4. Resume procedure

**How `-resume` interacts with `cleanup = true`:**

When `cleanup = true`, Nextflow deletes work-directory files for a task as soon as that task succeeds. This means `-resume` cannot reuse the cached outputs for completed tasks — those files are gone. Instead:

- Fully completed samples are skipped by `output_exists(meta)` in `main.nf`, which checks whether all three HUMAnN TSVs (`genefamilies`, `pathabundance`, `pathcoverage`) already exist in `s3://gutz-nf-reads-profilers-runs/results/<project>/<run>/function/`. These final outputs are never cleaned up.
- Partially completed samples (where intermediate work files were deleted before the sample finished) restart from the beginning. This is the expected and safe behavior.
- Failed samples (logged by Nextflow but not in the output directory) will be reprocessed.

**Identify failed samples from the trace:**

```bash
# Download the most recent trace
aws s3 cp \
  "s3://gutz-nf-reads-profilers-runs/results/<project>/reports/<timestamp>_trace.txt" \
  /tmp/trace.txt

# Show failed tasks
awk -F'\t' '$4 == "FAILED" {print $0}' /tmp/trace.txt | head -20
```

**Re-run after interruption or failure:**

No samplesheet changes are needed. Re-run the identical kickoff command with `-resume`:

```bash
nextflow run main.nf \
  -profile aws \
  --input s3://gutz-nf-reads-profilers-runs/samplesheets/<samplesheet>.csv \
  --project <project_name> \
  -resume
```

`output_exists(meta)` will skip the ~15,900 samples that finished; only the interrupted or failed samples will be re-submitted to Batch.

---

### 5. Post-run teardown

**Verify outputs are complete:**

```bash
# Count output directories (one per sample per run)
aws s3 ls s3://gutz-nf-reads-profilers-runs/results/<project>/ \
  --recursive | grep "function/genefamilies" | wc -l
# Expected: ~16000
```

Check for any samples missing outputs by comparing the samplesheet against the results directory. A helper command:

```bash
# List sample IDs from samplesheet (adjust column number to match schema)
cut -d',' -f1 /tmp/<samplesheet>.csv | tail -n +2 | sort > /tmp/expected.txt

# List sample IDs present in results
aws s3 ls "s3://gutz-nf-reads-profilers-runs/results/<project>/" \
  | awk '{print $2}' | tr -d '/' | sort > /tmp/actual.txt

diff /tmp/expected.txt /tmp/actual.txt
```

**Scale back compute resources** (prevents accidental spend after the run):

```bash
EcsAmiId=$(aws ec2 describe-images --region us-east-2 --owners amazon \
  --filters "Name=name,Values=al2023-ami-ecs-hvm-*-kernel-*-arm64" \
            "Name=state,Values=available" \
  --query 'Images | sort_by(@,&CreationDate) | [-1].ImageId' --output text)

aws cloudformation deploy \
  --stack-name nf-reads-profiler-batch \
  --template-file infra/batch-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-2 \
  --parameter-overrides \
    VpcId=vpc-06ad1e39bb8cd26df \
    SubnetIds="subnet-09159c654acc505a3,subnet-03afe111356916511,subnet-0d0f1d152c1656677" \
    WorkDirBucketName=gutz-nf-reads-profilers-workdir \
    RunsBucketName=gutz-nf-reads-profilers-runs \
    DbSourceBucket=cjb-gutz-s3-demo \
    BudgetAlertEmail=colin@vasogo.com \
    MonthlyBudgetThreshold=200 \
    SpotBidPercentage=70 \
    MaxvCPUsSpot=16 \
    MaxvCPUsOnDemand=8 \
    ProjectTag=nf-reads-profiler \
    EnvironmentTag=development \
    EcsAmiId="$EcsAmiId"
```

- [ ] `MaxvCPUsSpot` restored to 16
- [ ] `MonthlyBudgetThreshold` restored to $200

**Clean up the workdir bucket** (if `cleanup = true` was active throughout, this should already be near-empty; verify before deleting):

```bash
# Check remaining size
aws s3 ls s3://gutz-nf-reads-profilers-workdir --recursive --human-readable --summarize \
  | tail -2

# Empty if needed (only if verified that the run is complete and outputs are confirmed)
aws s3 rm s3://gutz-nf-reads-profilers-workdir --recursive
```

**Check for orphaned EC2 instances:**

```bash
# Only the head-node runner should be running
aws ec2 describe-instances --region us-east-2 \
  --filters "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

Expected: one instance (the head node). Any additional instances are orphaned Batch workers that did not terminate cleanly — terminate them manually:

```bash
aws ec2 terminate-instances --region us-east-2 --instance-ids <instance-id>
```

- [ ] No orphaned EC2 instances
- [ ] Workdir bucket verified empty or near-empty
- [ ] CloudFormation stack parameters restored to baseline values
- [ ] Final output count confirmed against samplesheet

---

## Verification

This playbook is considered verified when:

1. The 16K-sample run completes with `output_exists` passing for all (or all non-failed) samples.
2. All outputs are present in `s3://gutz-nf-reads-profilers-runs/results/<project>/`.
3. The CloudFormation stack is back to baseline parameters (`MaxvCPUsSpot=16`, `MonthlyBudgetThreshold=200`).
4. No orphaned EC2 instances remain.
5. The Nextflow report HTML and trace TSV are archived alongside the results.
