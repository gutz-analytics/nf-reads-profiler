# I01: Parameterize the DB source bucket in batch-stack.yaml

**Priority:** High
**Size:** Small
**Dependencies:** None

---

## Problem

The S3 bucket `cjb-gutz-s3-demo` — where the metaomics databases (MetaPhlAn,
HUMAnN4, ChocoPhlAn, UniRef, MEDI) live — is hardcoded in two places inside
`infra/batch-stack.yaml`. This makes the stack non-portable: anyone deploying
into a different AWS account or using a differently-named DB bucket must hand-
edit the template, and the hardcoded name is easy to miss.

### Affected lines

1. **`EcsInstanceRole` IAM policy** (lines 181–182) — `s3:GetObject` / `s3:ListBucket`
   permissions for the DB bucket are expressed as bare string ARNs:

   ```yaml
   # Database bucket
   - "arn:aws:s3:::cjb-gutz-s3-demo"
   - "arn:aws:s3:::cjb-gutz-s3-demo/*"
   ```

2. **`BatchWorkerLaunchTemplate` UserData** (line 427) — the `aws s3 sync`
   command that populates `/mnt/dbs` on every worker before ECS starts:

   ```bash
   /opt/conda-aws/bin/aws s3 sync s3://cjb-gutz-s3-demo /mnt/dbs/ \
       --exclude "referencedata/*" --quiet
   ```

---

## Proposed fix

### 1. Add a new CloudFormation parameter

Insert after the existing `EcsAmiId` parameter block (around line 90, just
before the `# S3` / `Resources:` section):

```yaml
  DbSourceBucket:
    Type: String
    Default: cjb-gutz-s3-demo
    Description: >
      S3 bucket that holds the pre-staged metaomics databases (MetaPhlAn,
      HUMAnN4, ChocoPhlAn, UniRef, MEDI). Workers sync this bucket to
      /mnt/dbs at startup via the BatchWorkerLaunchTemplate UserData.
      The EcsInstanceRole is granted read-only access to this bucket.
      This bucket is NOT created or deleted by this stack.
```

### 2. Replace hardcoded ARNs in `EcsInstanceRole` IAM policy

Replace (lines 181–182):

```yaml
                  - "arn:aws:s3:::cjb-gutz-s3-demo"
                  - "arn:aws:s3:::cjb-gutz-s3-demo/*"
```

With:

```yaml
                  - !Sub "arn:aws:s3:::${DbSourceBucket}"
                  - !Sub "arn:aws:s3:::${DbSourceBucket}/*"
```

### 3. Replace hardcoded bucket name in `BatchWorkerLaunchTemplate` UserData

The UserData is MIME multipart; the bash script segment uses a literal bucket
name. Replace (line 427):

```bash
            /opt/conda-aws/bin/aws s3 sync s3://cjb-gutz-s3-demo /mnt/dbs/ \
```

With a CloudFormation `!Sub` substitution. Because UserData is already inside
a `!Sub` block (or must be wrapped in one), the replacement is:

```bash
            /opt/conda-aws/bin/aws s3 sync s3://${DbSourceBucket} /mnt/dbs/ \
```

Keep `--exclude "referencedata/*" --quiet` unchanged — this exclusion skips
the MEDI Kraken2 reference data regardless of which bucket is used.

### 4. Do NOT touch `BatchJobRole`

Containers read databases from `/mnt/dbs` on local disk (synced at instance
startup) and never access the DB bucket directly. Adding `DbSourceBucket`
permissions to `BatchJobRole` would be unnecessary and would widen the attack
surface of the task role. Leave `BatchJobRole` unchanged.

---

## Files to change

| File | Change |
|------|--------|
| `infra/batch-stack.yaml` | Add `DbSourceBucket` parameter; replace 2 hardcoded bucket references with `!Sub "${DbSourceBucket}"` / `!Sub "arn:aws:s3:::${DbSourceBucket}"` |
| `infra/readme.md` | Add `DbSourceBucket=cjb-gutz-s3-demo` to every `--parameter-overrides` block in the deploy and redeploy steps |

---

## Changes to `infra/readme.md`

Every `aws cloudformation deploy` invocation in the readme lists explicit
`--parameter-overrides`. Add `DbSourceBucket=cjb-gutz-s3-demo` to each of
these blocks:

- **Part 2 § 2 "Deploy"** (initial deploy command, around line 311)
- **Troubleshooting § "Fix: MIME multipart format" Step 1** (around line 521)
- **Troubleshooting § "Fix: Drift" Step 3** (around line 657)

Also update the pre-run checklist item that verifies DB bucket access
(Part 2 § 3, around line 416) to note that the bucket name comes from the
`DbSourceBucket` parameter rather than being fixed.

---

## Verification steps

1. **Template validates cleanly:**

   ```bash
   aws cloudformation validate-template \
     --template-body file://./infra/batch-stack.yaml \
     --region us-east-2
   ```

2. **Grep confirms no remaining hardcoded references:**

   ```bash
   grep -n "cjb-gutz-s3-demo" infra/batch-stack.yaml
   # Expected: no output
   ```

3. **Dry-run changeset against the live stack** (does not execute):

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
     --no-execute-changeset \
     --parameter-overrides \
       VpcId=vpc-06ad1e39bb8cd26df \
       SubnetIds="subnet-09159c654acc505a3,subnet-03afe111356916511,subnet-0d0f1d152c1656677" \
       WorkDirBucketName=gutz-nf-reads-profilers-workdir \
       RunsBucketName=gutz-nf-reads-profilers-runs \
       DbSourceBucket=cjb-gutz-s3-demo \
       BudgetAlertEmail=colin@vasogo.com \
       MonthlyBudgetThreshold=100 \
       SpotBidPercentage=70 \
       MaxvCPUsSpot=16 \
       MaxvCPUsOnDemand=8 \
       ProjectTag=nf-reads-profiler \
       EnvironmentTag=development \
       EcsAmiId="$EcsAmiId"
   ```

   Expected result: changeset created showing only the `EcsInstanceRole`
   policy and `BatchWorkerLaunchTemplate` as modified resources. No
   replacement of compute environments or job queue.

4. **After a real deploy:** launch a Batch test job and confirm the worker
   can reach `/mnt/dbs` — check that at least one DB directory (e.g.
   `/mnt/dbs/metaphlan`) exists and is non-empty after the UserData script
   completes. CloudWatch logs for the launch template execution will show
   the `aws s3 sync` command with the correct (parameterized) bucket name.

---

## Notes

- The default value (`cjb-gutz-s3-demo`) preserves the current behaviour —
  existing deployments continue to work without any `--parameter-overrides`
  change until the operator explicitly sets a different bucket.
- Because `DbSourceBucket` is a plain `Type: String` (not
  `AWS::S3::Bucket::Name`), CloudFormation will not attempt to validate
  that the bucket exists at deploy time. This is intentional: the bucket is
  externally managed, just like `RunsBucketName`.
- If the DB bucket is ever renamed or moved to a different account, the only
  required change is passing the new name via `--parameter-overrides
  DbSourceBucket=<new-name>` — no template edits needed.
