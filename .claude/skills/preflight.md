---
name: preflight
description: Pre-flight check before running the pipeline on AWS Batch
---

# Pre-flight check for AWS Batch pipeline runs

Run these read-only checks before launching a pipeline run to catch common
problems early.

## Checks

### 1. Compute environments are ENABLED + VALID

```bash
aws batch describe-compute-environments \
  --region us-east-2 \
  --query "computeEnvironments[].{Name:computeEnvironmentName,State:state,Status:status,Reason:statusReason}"
```

Both must show `State: ENABLED`, `Status: VALID`.

### 2. Job queue is ENABLED

```bash
aws batch describe-job-queues \
  --job-queues spot-queue \
  --region us-east-2 \
  --query "jobQueues[0].{State:state,Status:status}"
```

### 3. Launch template has stop-ecs guard

Decode the launch template UserData and confirm `systemctl stop ecs` appears
before the `s3 sync` line:

```bash
aws ec2 describe-launch-template-versions \
  --launch-template-name nf-reads-profiler-worker \
  --region us-east-2 \
  --versions '$Latest' \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' \
  --output text | base64 -d | grep -n 'systemctl\|s3 sync'
```

Expected: `stop ecs` before `s3 sync`, `start ecs` after.

### 4. S3 buckets are reachable

```bash
aws s3 ls s3://gutz-nf-reads-profilers-workdir/ --region us-east-2 > /dev/null && echo "workdir: OK"
aws s3 ls s3://gutz-nf-reads-profilers-runs/ --region us-east-2 > /dev/null && echo "runs: OK"
aws s3 ls s3://cjb-gutz-s3-demo/ --region us-east-2 > /dev/null && echo "db source: OK"
```

### 5. Samplesheet exists (if user provided one)

If the user specified an `--input` samplesheet path, verify it exists in S3:

```bash
aws s3 ls <samplesheet-path>
```

### 6. No stuck jobs in the queue

```bash
aws batch list-jobs --job-queue spot-queue --region us-east-2 --job-status RUNNABLE \
  --query "length(jobSummaryList)"
aws batch list-jobs --job-queue spot-queue --region us-east-2 --job-status RUNNING \
  --query "length(jobSummaryList)"
```

If there are unexpected RUNNABLE/RUNNING jobs from a previous run, warn the user.

## Output

Print a pass/fail checklist and stop if anything fails.
