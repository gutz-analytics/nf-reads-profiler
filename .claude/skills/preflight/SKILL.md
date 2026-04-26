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

### 3. Custom AMI version matches deployed stack

Workers use a pre-baked custom AMI with databases and awscli. Verify the
deployed stack is using the latest available AMI.

```bash
# AMI in the deployed stack
DEPLOYED_AMI=$(aws cloudformation describe-stacks --stack-name nf-reads-profiler-batch \
  --region us-east-2 --query 'Stacks[0].Parameters[?ParameterKey==`EcsAmiId`].ParameterValue' --output text)

# Latest available self-owned AMI
LATEST_AMI=$(aws ec2 describe-images --region us-east-2 --owners self \
  --filters "Name=name,Values=nf-reads-profiler-worker-*" "Name=state,Values=available" \
  --query 'Images | sort_by(@,&CreationDate) | [-1].[ImageId,Name,CreationDate]' --output text)

echo "Deployed: $DEPLOYED_AMI"
echo "Latest:   $LATEST_AMI"
```

WARN if deployed AMI doesn't match the latest available AMI.

Also verify the Batch-managed launch templates have the same AMI (Batch
snapshots at CE create/update time — stale managed templates are a known
issue, see `logs/2026-04-26-launch-template-propagation-fix.log`).

```bash
for lt in $(aws ec2 describe-launch-templates --region us-east-2 \
  --filters "Name=launch-template-name,Values=Batch-lt-*" \
  --query 'LaunchTemplates[*].LaunchTemplateName' --output text); do
  AMI=$(aws ec2 describe-launch-template-versions --launch-template-name "$lt" \
    --region us-east-2 --versions '$Latest' \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.ImageId' --output text)
  echo "$lt: $AMI"
done
```

All Batch-managed templates must show the same AMI as the deployed stack.

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
