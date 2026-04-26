---
name: deploy-stack
description: Deploy the CloudFormation stack and re-validate Batch compute environments
---

# Deploy the nf-reads-profiler Batch stack

This skill deploys the CloudFormation stack and re-validates compute environments.

**Before running**: confirm with the user that they want to deploy. Show them the
`git diff infra/batch-stack.yaml` so they can review changes.

## Steps

### 1. Validate the template

```bash
aws cloudformation validate-template \
  --template-body file://infra/batch-stack.yaml \
  --region us-east-2
```

If validation fails, stop and report the error.

### 2. Deploy the stack

```bash
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
    BudgetAlertEmail=colin@vasogo.com \
    MonthlyBudgetThreshold=100 \
    SpotBidPercentage=70 \
    MaxvCPUsSpot=16 \
    MaxvCPUsOnDemand=8 \
    ProjectTag=nf-reads-profiler \
    EnvironmentTag=development \
    DbSourceBucket=cjb-gutz-s3-demo
```

### 3. Wait for completion

```bash
aws cloudformation wait stack-update-complete \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2
```

### 4. Re-validate compute environments (disable/re-enable)

```bash
CE_SPOT=$(aws batch describe-job-queues --job-queues spot-queue --region us-east-2 \
  --query "jobQueues[0].computeEnvironmentOrder[0].computeEnvironment" --output text)
CE_ONDEMAND=$(aws batch describe-job-queues --job-queues spot-queue --region us-east-2 \
  --query "jobQueues[0].computeEnvironmentOrder[1].computeEnvironment" --output text)

aws batch update-compute-environment --compute-environment $CE_SPOT --state DISABLED --region us-east-2
aws batch update-compute-environment --compute-environment $CE_ONDEMAND --state DISABLED --region us-east-2
```

Wait 30 seconds, then re-enable:

```bash
aws batch update-compute-environment --compute-environment $CE_SPOT --state ENABLED --region us-east-2
aws batch update-compute-environment --compute-environment $CE_ONDEMAND --state ENABLED --region us-east-2
```

### 5. Confirm both are VALID

```bash
aws batch describe-compute-environments \
  --region us-east-2 \
  --query "computeEnvironments[].{Name:computeEnvironmentName,State:state,Status:status}"
```

Report the result to the user.
