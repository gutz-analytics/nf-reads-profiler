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

### 3. Launch template UserData is correct

Decode the launch template UserData and verify it contains the expected
content. Currently this is the S3 sync with `systemctl stop ecs` guard;
after the custom AMI migration (`issues/I14-custom-ami-worker.md`) it will
be a minimal health check verifying `/mnt/dbs/` directories exist.

```bash
aws ec2 describe-launch-template-versions \
  --launch-template-name nf-reads-profiler-worker \
  --region us-east-2 \
  --versions '$Latest' \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' \
  --output text | base64 -d | grep -n 'systemctl\|s3 sync\|mnt/dbs'
```

Also verify the Batch-managed launch templates have picked up the latest
UserData (Batch snapshots at CE create/update time — stale managed templates
are a known issue, see `logs/2026-04-26-launch-template-propagation-fix.log`).

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
