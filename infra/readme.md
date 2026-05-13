# AWS Batch Infrastructure for nf-reads-profiler

This directory contains a CloudFormation template that provisions AWS Batch
infrastructure for running the `nf-reads-profiler` Nextflow pipeline from an
EC2 runner VM. All compute nodes use **Graviton (ARM64)** instances — the
same architecture as the runner (`r8g.2xlarge`).

To see what's running right now, view [the dashboard](https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards/dashboard/nf-reads-profiler-batch?start=PT72H). Or run

```bash
# List all running VMs
aws ec2 describe-instances --region us-east-2 \
  --filters "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime,IamInstanceProfile.Arn]' \
  --output text
```

We expect to see only one VM; the 'head-node' we are connected to now!

```bash
#kill a vm
aws ec2 terminate-instances --region us-east-2 --instance-ids i_asdf_copy_here
```


---

## Part 0: Tear down the stack

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

# 3. Wait for deletion
aws cloudformation wait stack-delete-complete \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2

# 4. Check on head-node-role. We should NOT see nf-reads-profiler-nextflow-runner-policy in this list.
aws iam list-attached-role-policies --role-name head-node-role \
  --query "AttachedPolicies[].PolicyName"

# 4. Detach the runner policy (in case it's not removed automatically)
aws iam detach-role-policy \
  --role-name head-node-role \
  --policy-arn arn:aws:iam::730883236839:policy/nf-reads-profiler-nextflow-runner-policy

```

The output data is in a different bucket!

The **runs bucket** (`gutz-nf-reads-profilers-runs`) survives stack deletion. Delete it
manually only when you no longer need the results:

```bash
# This is the output data, careful!
# aws s3 rm # s3://gutz-nf-reads-profilers-runs --recursive
# aws s3api delete-bucket # --bucket gutz-nf-reads-profilers-runs --region us-east-2
```


## Part 1: First Time Setup

### Architecture

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

### Database placement (worker-local EBS)

Databases (~65 GiB) live on each worker's local 500 GiB gp3 EBS volume at
`/mnt/dbs/`. This keeps read performance high for random-seek tools (Bowtie2,
DIAMOND). Database paths in `conf/aws_batch.config` point to `/mnt/dbs/...`.

**Custom AMI with pre-baked databases.** Workers boot from a custom
Packer-built AMI with `/mnt/dbs/` already populated and Miniconda/awscli
already installed — no S3 sync happens at boot, ECS registers in
seconds. The AMI is rebuilt with `infra/packer/build-ami.sh`, which
publishes the new AMI ID to SSM `/nf-reads-profiler/ami-id`. The Batch
stack reads that SSM parameter at deploy time. See
`issues/I14-custom-ami-worker.md` for the original migration and
`infra/playbook-ami-v2-rebuild.md` for the current rebuild flow.

The earlier S3-sync-at-boot model (~20 min boot delay for 30k objects)
is documented in [ADR-001](adr-001-db-placement.md), now superseded.

---

### Prerequisites

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

## Part 2: Deploy the Stack

### 1. Validate + deploy (use the `/deploy-stack` skill)

The deploy mechanics — validate, deploy, wait for CFN, force compute
environments to pick up the new launch template — live in the
project skill at:

```
.claude/skills/deploy-stack/SKILL.md
```

From a Claude Code session in this repo, invoke:

```
/deploy-stack
```

The skill looks up the custom worker AMI from SSM
(`/nf-reads-profiler/ami-id`, populated by `infra/packer/build-ami.sh`),
validates the template, deploys with the full parameter override block,
then runs `update-compute-environment` with `updateToLatestImageVersion:
true` on both CEs — without that step, Batch keeps booting workers from
the old launch template version even after CFN updates it.

> **`RunsBucketName`** must be globally unique across all AWS accounts.
> If `gutz-nf-reads-profilers-runs` is taken, choose another name and update
> `conf/aws_batch.config` accordingly.
>
> **Subnet note:** Use public subnets (auto-assign public IP) or private subnets
> with a NAT gateway — Batch instances need outbound internet for DockerHub pulls.

### 2. Get stack outputs

```bash
aws cloudformation describe-stacks \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2 \
  --query "Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}" \
  --output text
```

Save for the next steps: **From April 21st, 2026**
  - `NextflowRunnerPolicyArn` = arn:aws:iam::730883236839:policy/nf-reads-profiler-nextflow-runner-policy
  - `BatchJobRoleArn`         = arn:aws:iam::730883236839:role/nf-reads-profiler-batch-job-role


### 3. Post-Deploy: Attach the `NextflowRunnerPolicyArn` we just recorded

**From April 21st, 2026**

```bash
# Verify
aws iam list-attached-role-policies --role-name head-node-role | grep "runner-policy"
# should show two lines, "PolicyName" and "PolicyArn" with 'runner-policy' near the end

# If not already, pass --role-name name of the IAM role attached to your runner VM
# and pass --policy-arn the full policy arn from Step 3.
aws iam attach-role-policy \
  --role-name head-node-role \
  --policy-arn arn:aws:iam::730883236839:policy/nf-reads-profiler-nextflow-runner-policy

```

### 4. Post-Deploy: Add or update the `BatchJobRoleArn` we just recorded

```bash
grep "jobRole" conf/aws_batch.config
# should show one line matching arn ID from above
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

# Part 3: Confirming Setup Before a Run

Run these checks on the runner VM before submitting a pipeline job.

## Pre-Run Checklist

### 1. Check Batch job queue is ENABLED and VALID

```bash
aws batch describe-job-queues --job-queues spot-queue --region us-east-2 \
  --query "jobQueues[0].{State:state,Status:status}"
```

### 2. Check compute environments are ENABLED and VALID

```bash
aws batch describe-compute-environments \
  --region us-east-2 \
  --query "computeEnvironments[].{Name:computeEnvironmentName,State:state,Status:status}"
```

### 3. Check S3 buckets are accessible

```bash
aws s3 ls s3://gutz-nf-reads-profilers-workdir/ --region us-east-2 | head
aws s3 ls s3://gutz-nf-reads-profilers-runs/samplesheets/ --region us-east-2
```

The DB source bucket (`cjb-gutz-s3-demo`) is no longer touched at
worker runtime — it's only used by Packer at AMI bake time. Verifying
it from the head node here would just check the head node's IAM, not
the worker's. Skip.

### 4. Check IAM runner policy is attached

```bash
aws iam list-attached-role-policies --role-name head-node-role \
  --query "AttachedPolicies[].PolicyName"
```

### 5. Get CloudWatch Dashboard URL

```bash
aws cloudformation describe-stacks \
  --stack-name nf-reads-profiler-batch \
  --query "Stacks[0].Outputs[?OutputKey=='DashboardUrl'].OutputValue" \
  --output text --region us-east-2
```

---

## Run the Pipeline

From the EC2 runner VM:

```bash
# Example run.
# We set the input manifest and output project name here, with
# the goal that the `aws_batch.config` can be more stable / reusable than the
# conf files I used to do incremental runs locally.
# The goal is to keep the confs stable, then just change input path and/or project.
nextflow run main.nf \
  -profile aws \
  --input  s3://gutz-nf-reads-profilers-runs/samplesheets/sra-child-max005.csv \
  --project child_max_aws_batch \
  -resume
```

Check on results. The `_readcount.txt` files are good for this.

```bash
aws s3 ls s3://gutz-nf-reads-profilers-runs/results/child_min/SRP662258/readcount/ --region us-east-2 | wc -l
aws s3 ls s3://gutz-nf-reads-profilers-runs/results/child_mid/SRP662258/readcount/ --region us-east-2 | wc -l
aws s3 ls s3://gutz-nf-reads-profilers-runs/results/child_max/SRP662258/readcount/ --region us-east-2 | wc -l
```

Key flags:
- `-resume` — reuses cached work; essential for long pipelines
- `-profile aws` — loads `conf/aws_batch.config` (spot-queue, S3 work dir)
- No credential files needed when running on an EC2 instance with the runner policy attached

### Database paths

`nextflow.config` defaults point to local paths (`/home/ubuntu/disk_dbs/...`).
The `aws` profile overrides these to `/mnt/dbs/...` in `conf/aws_batch.config`.
Workers boot with `/mnt/dbs/` already populated by the custom AMI — no
runtime S3 sync. See "Database placement" above.

---

# Part 4: Troubleshooting

## Compute Environments Show as INVALID

**Symptom:** Pre-run check (Part 3, step 2) returns `"Status": "INVALID"`.

**Diagnose:** Get the status reason:

```bash
aws batch describe-compute-environments \
  --region us-east-2 \
  --query "computeEnvironments[].{Name:computeEnvironmentName,Status:status,Reason:statusReason}"
```

---

### Fix: "Launch Template UserData is not MIME multipart format"

**Cause:** AWS Batch requires UserData in MIME multipart format so it can merge its own
ECS bootstrap script with yours. A plain `#!/bin/bash` script fails validation.

**Fix already applied** in `infra/batch-stack.yaml` (April 2026):
- UserData wrapped in MIME multipart envelope
- `ServiceRole` removed from both compute environments so they use the Batch service-linked role (`AWSServiceRoleForBatch`) — required to allow future launch template updates via CLI

To redeploy: invoke `/deploy-stack` (skill at
`.claude/skills/deploy-stack/SKILL.md`). The skill validates the
template, deploys, waits for `stack-update-complete`, then forces both
compute environments to pick up the new launch template via
`update-compute-environment` with `updateToLatestImageVersion: true`.

> **Important:** the older "disable → wait → re-enable" CE-refresh
> approach (mentioned in earlier docs) is not enough on its own.
> Batch caches the launch template version on the CE; without an
> explicit `updateToLatestImageVersion`, workers keep booting from
> the previous LT version even after the CFN deploy completes. The
> skill encodes the correct refresh.

After the skill finishes, confirm both environments are VALID:

```bash
aws batch describe-compute-environments \
  --region us-east-2 \
  --query "computeEnvironments[].{Name:computeEnvironmentName,State:state,Status:status}"
```

Expected output (names are auto-generated):
```json
[
    {"Name": "nf-reads-profiler-batch-OnDema-XXXXXXXXXXXX", "State": "ENABLED", "Status": "VALID"},
    {"Name": "nf-reads-profiler-batch-SpotCo-XXXXXXXXXXXX", "State": "ENABLED", "Status": "VALID"}
]
```

---

### Fix: HUMAnN "ChocoPhlAn database does not exist" on AWS Batch

**Symptom:** `profile_function` fails immediately (exit 1 within seconds) with:
```
CRITICAL ERROR: The directory provided for the ChocoPhlAn database at /mnt/dbs/chocophlan_v4_alpha/ does not exist.
```

**Cause:** the worker booted from an AMI that doesn't have the
ChocoPhlAn DB baked in — almost always because the launch template is
still pointing at the wrong AMI ID. Possible reasons:

1. The Packer build for the custom worker AMI never landed (stock
   AL2023 ECS AMI has no DBs).
2. CFN deployed a new AMI to the LT but the compute environment never
   refreshed (this is the bug `/deploy-stack` works around with
   `updateToLatestImageVersion: true`).
3. The SSM parameter `/nf-reads-profiler/ami-id` was overwritten with
   a stale or wrong AMI ID.

**Diagnose:**

```bash
# What AMI does the LT think it should use?
aws ec2 describe-launch-template-versions --region us-east-2 \
  --launch-template-name nf-reads-profiler-worker --versions '$Latest' \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData.ImageId' --output text

# What's currently published in SSM?
aws ssm get-parameter --name /nf-reads-profiler/ami-id \
  --region us-east-2 --query 'Parameter.Value' --output text

# Inspect a running worker from the head node:
aws ssm start-session --region us-east-2 --target <instance-id>
# Then on the worker:
ls /mnt/dbs/         # should show all 4 DB directories
cat /mnt/dbs/.ami-build-timestamp
```

**Historical context:** before the I14 custom-AMI migration, this
error was caused by an ECS-agent-vs-S3-sync race (the agent registered
with Batch before the boot-time `aws s3 sync` finished, so jobs landed
on workers with half-empty `/mnt/dbs/`). With baked DBs the race is
gone; if you see this error today it's an AMI-mismatch problem, not a
sync timing problem.

**Fix:** rebuild the AMI with `bash infra/packer/build-ami.sh`, then
redeploy with `/deploy-stack`. The skill picks up the new AMI from SSM
and forces both CEs to refresh.

---

### Fix: Drift — Batch compute environments deleted outside CloudFormation

**Symptom:** `aws cloudformation deploy` fails with `ResourceStatusReason: NotFound` for
`SpotComputeEnvironment` or `OnDemandComputeEnvironment`. Stack status is `UPDATE_ROLLBACK_COMPLETE`.

**Diagnose:**

```bash
# Stack should show UPDATE_ROLLBACK_COMPLETE
aws cloudformation describe-stacks \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2 \
  --query "Stacks[0].StackStatus" --output text

# Compute environments should return empty — confirms drift
aws batch describe-compute-environments \
  --region us-east-2 \
  --query "computeEnvironments[].computeEnvironmentName"
```

**Cause:** A partial deployment deleted the old compute environments but failed to create the
new `-v2` ones. CloudFormation's internal state still shows them as existing. Because the
template has accumulated changes across failed attempts, *every* deploy tries to update the
phantom CEs and immediately fails with NotFound — there is no minimal change that avoids it.

**Fix (preserves workdir bucket files for Nextflow caching):**

Use `--retain-resources` during stack deletion to skip the non-empty workdir bucket. After
deletion the bucket remains intact. CloudFormation's `CreateBucket` is idempotent for
same-account, same-region buckets, so the redeploy "creates" and adopts the existing bucket
with all its files.

**Step 1 — Detach the runner policy:**

```bash
aws iam detach-role-policy \
  --role-name head-node-role \
  --policy-arn arn:aws:iam::730883236839:policy/nf-reads-profiler-nextflow-runner-policy
```

**Step 2 — Delete the stack, retaining the workdir bucket and phantom Batch resources:**

`--retain-resources` only works from `DELETE_FAILED` state, so this is a two-step process.
First trigger the delete (it will fail on the non-empty bucket), then retry with the retain flag.

```bash
# Step 2a — start deletion; will fail on the non-empty workdir bucket
aws cloudformation delete-stack \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2

# Wait until it enters DELETE_FAILED (watch the console or poll):
aws cloudformation describe-stacks \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2 \
  --query "Stacks[0].StackStatus" --output text

# Step 2b — retry, skipping only the bucket (phantom Batch resources already deleted)
aws cloudformation delete-stack \
  --stack-name nf-reads-profiler-batch \
  --retain-resources S3WorkDirBucket \
  --region us-east-2

aws cloudformation wait stack-delete-complete \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2
```

**Step 3 — Redeploy:** invoke `/deploy-stack` (skill at
`.claude/skills/deploy-stack/SKILL.md`). With the phantom Batch resources
gone from CFN's view, the redeploy creates fresh CEs and a fresh LT;
the workdir bucket is adopted intact thanks to CFN's idempotent
`CreateBucket`.

**Step 4 — Re-attach the runner policy:**

```bash
aws iam attach-role-policy \
  --role-name head-node-role \
  --policy-arn arn:aws:iam::730883236839:policy/nf-reads-profiler-nextflow-runner-policy
```

**Step 5 — Confirm both environments are VALID:**

```bash
aws batch describe-compute-environments \
  --region us-east-2 \
  --query "computeEnvironments[].{Name:computeEnvironmentName,State:state,Status:status}"
```

> **Note on `DeletionPolicy`:** The template currently has `DeletionPolicy: Retain` on
> `S3WorkDirBucket`. The workdir bucket will survive future stack teardowns. To restore the
> original behaviour (bucket deleted with stack), empty the bucket and change `DeletionPolicy`
> back to `Delete` before tearing down.

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
| `batch-high-runnable` | ≥ 10 RUNNABLE for 15 min | Spot + on-demand capacity exhausted |

`batch-high-runnable` tracks the `RunnableJobCount` gauge emitted every 60s
by the `nf-reads-profiler-batch-queue-depth` Lambda (a list-jobs poll). The
old `batch-high-pending` alarm tracked `PendingJobCount` from the event-driven
Lambda, which never fired because Nextflow-submitted jobs never enter
`PENDING` state. See issue I17 for the rewrite.

Both alarms publish to the SNS topic `nf-reads-profiler-alerts`. Verify the
email subscription is `Confirmed` before relying on alarms:

```bash
aws sns list-subscriptions-by-topic \
  --region us-east-2 \
  --topic-arn arn:aws:sns:us-east-2:730883236839:nf-reads-profiler-alerts
```

A `SubscriptionArn` of `pending confirmation` means the recipient still needs
to click the AWS confirmation link in their inbox — until then no alarm
emails will be delivered.

Spot interruptions are retried automatically (`process.maxRetries = 5`
in `conf/aws_batch.config`, with `resourceLimits` capping retries at
8 vCPU / 64 GB / 6 h). `-resume` is still useful to recover after
losing the Nextflow runner itself or after the retry budget is exhausted.

### Live job logs

Job stdout/stderr lands in CloudWatch log group **`/aws/batch/job`** (the
Batch default), not the `/aws/batch/nf-reads-profiler` group the stack
provisions. The stack-provisioned group exists but is empty because the
Nextflow-submitted job definitions don't override `logConfiguration`.

Stream names follow `nf-<image-tag>/default/<job-id>`, e.g.
`nf-barbarahelena-humann-4-0-3/default/20050178771c43229872feed13f00c8d`.

```bash
# Tail every running job in real time
aws logs tail /aws/batch/job --follow --region us-east-2

# Tail a specific image (e.g. HUMAnN jobs only)
aws logs tail /aws/batch/job --follow --region us-east-2 \
  --log-stream-name-prefix nf-barbarahelena-humann-

# Fetch logs for a specific job ID
JOB_ID=<paste-job-id>
LOG_STREAM=$(aws batch describe-jobs --region us-east-2 --jobs "$JOB_ID" \
  --query 'jobs[0].container.logStreamName' --output text)
aws logs get-log-events --region us-east-2 \
  --log-group-name /aws/batch/job \
  --log-stream-name "$LOG_STREAM" \
  --query 'events[].message' --output text
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
- Recommended budget threshold: **$200/month** during pilot/debugging
  (template default; bump to $500 once production runs are routine)

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

---

## Storage Lifecycle and Cleanup

### Work directory (`gutz-nf-reads-profilers-workdir`)

The CloudFormation template applies a **30-day lifecycle rule** that expires all
objects after 30 days. This is the primary cleanup mechanism — no manual action
needed for routine use.

For immediate cleanup after a completed run:

```bash
# Remove a specific project's work files
aws s3 rm "s3://gutz-nf-reads-profilers-workdir/" --recursive

# Or remove only files older than a timestamp (requires listing + filtering)
```

**Warning:** Deleting work directory files breaks `-resume`. Only clean up after
confirming all samples completed successfully.

### Results bucket (`gutz-nf-reads-profilers-runs`)

No automatic lifecycle — results persist indefinitely. Clean up manually per
project:

```bash
# List projects
aws s3 ls s3://gutz-nf-reads-profilers-runs/results/

# Remove a specific project's results (irreversible)
# aws s3 rm s3://gutz-nf-reads-profilers-runs/results/<project>/ --recursive
```

### Worker-local storage (`/mnt/dbs/`)

Worker EBS volumes are configured with `DeleteOnTermination: true` — they are
automatically destroyed when the instance terminates. No manual cleanup needed.

### Nextflow reports and traces

Timeline, report, and trace files are written to
`<outdir>/<project>/reports/` with timestamps. These accumulate across runs.
Periodically clean up old reports if storage becomes a concern.
