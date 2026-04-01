# AWS Batch Infrastructure for nf-reads-profiler

This directory contains a CloudFormation template that provisions AWS Batch
infrastructure for running the `nf-reads-profiler` Nextflow pipeline from an
EC2 runner VM. All compute nodes use **Graviton (ARM64)** instances — the
same architecture as the runner (`r8g.2xlarge`).

## Architecture

```
EC2 Nextflow Runner VM — r8g.2xlarge (Graviton 4, ARM64)
  │
  │  nextflow run main.nf -profile aws
  │
  └─► AWS Batch: spot-queue
        ├─ Order 1: Spot Compute Environment  (SPOT_CAPACITY_OPTIMIZED)
        │    └─ r8g/m8g/c8g (G4) + r7g/m7g (G3) + r6g/m6g (G2)  →  0–256 vCPU
        └─ Order 2: On-Demand Compute Environment (automatic fallback)
             └─ r8g/m8g/r7g (Graviton)                            →  0–64 vCPU

S3: s3://gutz-nf-reads-profilers-workdir        ← Nextflow work dir  — STACK-MANAGED, deleted on teardown
S3: s3://gutz-nf-reads-profilers-runs  ← input + results    — DeletionPolicy Retain, survives teardown
```

**S3 buckets:**
- `gutz-nf-reads-profilers-workdir` — Nextflow intermediate/temp files. Created and managed by this
  stack. Deleted when the stack is torn down (after you empty it first). A 30-day
  lifecycle rule is applied automatically by the template.
- `gutz-nf-reads-profilers-runs` — samplesheets and pipeline results. Also created by this
  stack, but with `DeletionPolicy: Retain` — it survives stack deletion. Delete it
  manually only when you no longer need the results.

---

## Prerequisites

- AWS CLI v2 configured (`aws configure` or instance role)
- AWS account `730883236839`, region `us-east-2`
- An existing EC2 runner VM (`r8g.2xlarge` or similar Graviton) with an IAM instance role
- Nextflow ≥ 23.x and Java 17 installed on the runner:
  ```bash
  sudo yum install -y java-17-amazon-corretto
  curl -s https://get.nextflow.io | bash && sudo mv nextflow /usr/local/bin/
  ```
- Your VPC ID and at least one subnet ID:
  ```bash
  # get value for VpcId later
  aws ec2 describe-vpcs --query "Vpcs[?IsDefault].VpcId" --output text

  # get values for SubnetIds later
  aws ec2 describe-subnets --filters "Name=defaultForAz,Values=true" \
    --query "Subnets[].SubnetId" --output text
  ```
- An email address for alerts (budget + CloudWatch alarms)

---

## Deploy the Stack

### 1. Validate the template

```bash
aws cloudformation validate-template \
  --template-body file://./infra/batch-stack.yaml \
  --region us-east-2
```

### 2. Deploy

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
  --tags Repo=nf-reads-profiler Environment=development
```

> **`RunsBucketName`** must be globally unique across all AWS accounts.
> If `gutz-nf-reads-profilers-runs` is taken, choose another name and update
> `conf/aws_batch.config` accordingly.
>
> **Subnet note:** Use public subnets (auto-assign public IP) or private subnets
> with a NAT gateway — Batch instances need outbound internet for DockerHub pulls.

### 3. Get stack outputs

```bash
aws cloudformation describe-stacks \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2 \
  --query "Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}" \
  --output text
```

Save `NextflowRunnerPolicyArn` and `BatchJobRoleArn` for the next steps.

---

## Post-Deploy: Attach Runner Policy

```bash
# Replace <runner-role-name> with the IAM role attached to your runner VM
aws iam attach-role-policy \
  --role-name <runner-role-name> \
  --policy-arn <NextflowRunnerPolicyArn from stack outputs>

# Verify
aws iam list-attached-role-policies --role-name <runner-role-name>
```

---

## Post-Deploy: Add Job Role to Nextflow Config

Add the `BatchJobRoleArn` from stack outputs to `conf/aws_batch.config`:

```groovy
aws {
    batch {
        jobRole = '<BatchJobRoleArn from stack outputs>'
    }
    // ... existing client block ...
}
```

---

## Uploading Samplesheets

Samplesheets are small CSVs. Upload from the runner VM to the runs bucket:

```bash
aws s3 cp my-study.csv s3://gutz-nf-reads-profilers-runs/samplesheets/my-study.csv

# List uploaded samplesheets
aws s3 ls s3://gutz-nf-reads-profilers-runs/samplesheets/
```

Alternatively, keep samplesheets on the runner's local disk and pass a local path —
Nextflow copies them into `workDir` automatically.

---

## Run the Pipeline

From your EC2 runner VM:

```bash
# Standard run
nextflow run /path/to/nf-reads-profiler/main.nf \
  -profile aws \
  --input s3://gutz-nf-reads-profilers-runs/samplesheets/my-study.csv \
  --outdir s3://gutz-nf-reads-profilers-runs/results/ \
  --project my-project \
  -resume

# Smoke test
nextflow run main.nf \
  -profile aws \
  --input s3://gutz-nf-reads-profilers-runs/samplesheets/test.csv \
  --outdir s3://gutz-nf-reads-profilers-runs/results-test/ \
  --project smoke-test \
  --nreads 1000 \
  --minreads 100
```

Key flags:
- `-resume` — reuses cached work; essential for long pipelines
- `-profile aws` — loads `conf/aws_batch.config` (spot-queue, S3 work dir)
- No credential files needed when running on an EC2 instance with the runner policy attached

### Database paths

`nextflow.config` defaults point to local paths (`/dbs/omicsdata/...`).
Override with S3 URIs for AWS runs:

```bash
nextflow run main.nf -profile aws \
  --metaphlan_db s3://your-db-bucket/metaphlan/metaphlan4/vJan25 \
  --metaphlan_index mpa_vJan25_CHOCOPhlAnSGB_202503 \
  --humann_metaphlan_db s3://your-db-bucket/metaphlan/metaphlan4/vOct22_202403 \
  --chocophlan s3://your-db-bucket/humann/4.0/chocophlan \
  --uniref s3://your-db-bucket/humann/4.0/uniref/uniref \
  --utility_mapping s3://your-db-bucket/humann/4.0/utility_mapping/utility_mapping \
  ...
```

---

## Cost Monitoring

### AWS Budgets

Alerts fire when actual spend reaches **80%** or forecasted spend exceeds **100%**
of the monthly threshold for resources tagged `Project=nf-reads-profiler`.

View budgets: <https://us-east-2.console.aws.amazon.com/billing/home#/budgets>

> **Tag activation delay:** Go to <https://us-east-2.console.aws.amazon.com/billing/home#/tags>
> and activate `Project` as a cost allocation tag. Allow 24 hours.

### AWS Cost Explorer

<https://us-east-2.console.aws.amazon.com/cost-management/home#/cost-explorer>

Filter by `Project = nf-reads-profiler` to see per-service breakdown (EC2, S3, CloudWatch).

---

## Resource Monitoring

### CloudWatch Dashboard

```bash
aws cloudformation describe-stacks \
  --stack-name nf-reads-profiler-batch \
  --query "Stacks[0].Outputs[?OutputKey=='DashboardUrl'].OutputValue" \
  --output text
```

### CloudWatch Alarms

| Alarm | Condition | Meaning |
|---|---|---|
| `batch-failed-jobs` | ≥ 5 failures in 5 min | Systemic error (bad image, IAM, etc.) |
| `batch-high-pending` | ≥ 50 pending for 15 min | Spot + on-demand capacity exhausted |

Spot interruptions are handled by `maxRetries=3` in `aws_batch.config` and do not trigger alarms.

### Live job logs

```bash
aws logs tail /aws/batch/nf-reads-profiler --follow --region us-east-2
```

### AWS Batch console

<https://us-east-2.console.aws.amazon.com/batch/home?region=us-east-2#/queues>

---

## Estimated Costs (us-east-2, Graviton, 2025 spot pricing)

| Resource | Rate | Notes |
|---|---|---|
| Spot r8g.2xlarge (8 vCPU / 64 GB) | ~$0.06–0.09/hr | HUMAnN jobs; ~25% cheaper than x86 r5 |
| Spot m8g.2xlarge (8 vCPU / 32 GB) | ~$0.03–0.05/hr | MetaPhlAn, fastp, SRA download |
| On-demand r8g.2xlarge | ~$0.27/hr | Fallback only |
| S3 work dir (INTELLIGENT_TIERING) | ~$0.023/GB/mo | 30-day lifecycle in template keeps this low |
| S3 runs bucket | ~$0.023/GB/mo | Results are small text files — typically <$1/mo |
| CloudWatch Logs | $0.50/GB ingested | |
| AWS Batch | $0 | Pay only for EC2 |

**Typical run — 100 samples (MetaPhlAn + HUMAnN):**
- Spot EC2: ~$35–100
- S3: ~$5–20/month total
- Recommended budget threshold: **$500/month** to catch runaway jobs

---

## Teardown

The workdir bucket (`gutz-nf-reads-profilers-workdir`) is deleted with the stack — but CloudFormation
requires the bucket to be **empty first**. The 30-day lifecycle rule handles most cleanup
automatically; for an immediate teardown, empty it manually:

```bash
# 1. Empty the workdir bucket (required before stack deletion)
aws s3 rm s3://gutz-nf-reads-profilers-workdir --recursive

# 2. Delete the stack (IAM roles, compute envs, job queue, alarms, workdir bucket)
aws cloudformation delete-stack \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2

# 3. Wait (~5 minutes)
aws cloudformation wait stack-delete-complete \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2

# 4. Detach the runner policy (not removed automatically)
aws iam detach-role-policy \
  --role-name <runner-role-name> \
  --policy-arn <NextflowRunnerPolicyArn>
```

The **runs bucket** (`gutz-nf-reads-profilers-runs`) survives stack deletion. Delete it
manually only when you no longer need the results:

```bash
aws s3 rm s3://gutz-nf-reads-profilers-runs --recursive
aws s3api delete-bucket --bucket gutz-nf-reads-profilers-runs --region us-east-2
```

---

## Importing an Existing Workdir Bucket

If `gutz-nf-reads-profilers-workdir` already exists, import it into the stack instead of recreating it:

```bash
# 1. Deploy the stack WITHOUT WorkDirBucketName (or use a temp name)
#    so the bucket resource is created fresh, then:

# 2. Or use CloudFormation resource import to adopt the existing bucket:
aws cloudformation create-change-set \
  --stack-name nf-reads-profiler-batch \
  --change-set-name import-workdir-bucket \
  --change-set-type IMPORT \
  --resources-to-import '[{
    "ResourceType": "AWS::S3::Bucket",
    "LogicalResourceId": "S3WorkDirBucket",
    "ResourceIdentifier": {"BucketName": "gutz-nf-reads-profilers-workdir"}
  }]' \
  --template-body file://infra/batch-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM

aws cloudformation execute-change-set \
  --change-set-name import-workdir-bucket \
  --stack-name nf-reads-profiler-batch
```
