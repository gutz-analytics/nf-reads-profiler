# I08 — S3 workdir storage lifecycle: measurement, alarm, and EBS review

**Priority:** medium
**Size:** small-medium
**Files to change:** `infra/readme.md` (manual-drain runbook), `infra/batch-stack.yaml` (CloudWatch S3 size alarm)
**Dependencies:** I06 must land first (disables `cleanup = true` so pilot measurements reflect real intermediate storage growth); I09 pilot provides the per-sample size data that drives the peak-storage calculation in task 2
**Verification:** see per-task checklists below

---

## Background

`conf/aws_batch.config` sets `workDir = 's3://gutz-nf-reads-profilers-workdir'` and
`cleanup = true`. When cleanup is active, Nextflow deletes each task's work directory from S3
immediately after the task succeeds, so the bucket stays near-zero between runs. The 30-day
lifecycle rule on the bucket handles any residual objects (failed tasks, aborted runs, orphaned
temp files) automatically.

At 16 K samples the concern is whether cleanup = true plus a 30-day lifecycle is actually
sufficient, or whether a burst of parallel jobs could produce tens of TB of live intermediate
data before cleanup catches up. This issue provides the measurement, guard-rail alarm, and
runbook to answer that question and respond to any anomaly.

---

## Task 1 — Quantify workdir growth per sample

### Why the measurement matters

With `cleanup = true` active, S3 workdir size reflects only in-flight data: objects written by
tasks that are currently running or have finished but whose cleanup has not yet completed.
The observed peak depends on pipeline concurrency (`MaxvCPUsSpot / cpus-per-task`) and task
duration, not on total sample count. Once a task finishes and cleanup fires, its objects
vanish — so per-sample growth measured during a production run is near-zero and is
**misleading as an input to a peak-storage projection**.

I06 disables `cleanup = true` for debugging purposes. While cleanup is off, every task's
intermediate files accumulate in S3 and are not removed until the 30-day lifecycle expires
(or a manual drain). Measuring bucket size after an I09 pilot run with cleanup disabled gives
the true per-sample intermediate footprint.

### What to measure

After the I09 pilot run completes (cleanup off):

```bash
# Total size of the workdir bucket (bytes and object count)
aws s3 ls s3://gutz-nf-reads-profilers-workdir --recursive --summarize --region us-east-2 \
  | tail -2
```

Record:
- Total size in GB
- Number of objects
- Number of samples processed in the pilot run

Calculate:
- **GB per sample** = total size / sample count
- Break down by process if possible. The two large contributors are expected to be:
  - `FASTERQ_DUMP` — raw FASTQ pairs before fastp trimming (can be 5–30 GB/sample depending on read depth)
  - `profile_function` (HUMAnN4) — nucleotide alignment intermediates and protein search scratch

### Process-level breakdown

The workdir bucket uses S3 key prefixes that match Nextflow's `<hash>/<task-name>/` layout.
To break down by process:

```bash
# List top-level prefixes (one per task hash)
aws s3 ls s3://gutz-nf-reads-profilers-workdir/ --region us-east-2

# For a finer breakdown, use the Nextflow trace file (outdir/<project>/reports/trace-*.txt)
# and join on task hash to get per-process sizes
```

The Nextflow trace TSV includes a `workdir` column with the full S3 key. Cross-referencing
with `aws s3 ls` sizes gives per-process intermediate footprints without custom instrumentation.

### Caveat: re-enable cleanup before production

Once the I06 debugging window closes, restore `cleanup = true` in `conf/aws_batch.config`.
With cleanup re-enabled the per-sample steady-state S3 cost is effectively zero (modulo
failed tasks held for 30 days). The measurements from this task inform the lifecycle
adequacy check (task 2) and the alarm threshold (task 3), but do not describe the ongoing
production steady state.

---

## Task 2 — Confirm the 30-day lifecycle rule is adequate

### Calculation

Using the per-sample footprint from task 1, estimate peak workdir size at 16 K samples
assuming cleanup remains disabled (worst case) or cleanup is re-enabled (expected case).

**Worst case (cleanup disabled, all 16 K samples in-flight simultaneously):**

```
peak_TB = (GB_per_sample / 1000) * 16000
```

This scenario is unrealistic: `MaxvCPUsSpot = 16` with `cpus = 4` allows at most 4 tasks
in parallel. Even at `MaxvCPUsSpot = 256`, parallel task count is bounded by queue
throughput. The realistic concurrent task count is:

```
max_concurrent_tasks = MaxvCPUsSpot / cpus_per_task   # e.g. 16 / 4 = 4
peak_live_GB = GB_per_sample * max_concurrent_tasks    # e.g. 20 GB * 4 = 80 GB
```

**Expected case (cleanup enabled):**

Peak live S3 = intermediate data for in-flight tasks only (a few GB at any moment).
Failed tasks accumulate until the 30-day lifecycle expires. With `maxRetries = 0` and
`minreads = 100,000` (samples below this are dropped, not retried), failed-task accumulation
is bounded by the number of samples that fail quality checks or encounter spot interruptions.
Estimate conservatively at 5% of 16 K = 800 samples, at `GB_per_sample` each.

### Lifecycle adequacy

The 30-day expiry currently covers:
- `ExpirationInDays: 30` on current-version objects
- `NoncurrentVersionExpiration: NoncurrentDays: 7` on previous versions
- `AbortIncompleteMultipartUpload: DaysAfterInitiation: 3`

Verdict (to be confirmed after pilot):
- If `failed_samples * GB_per_sample < 5 TB`, the 30-day rule is adequate and no change
  is needed.
- If footprint is larger, consider reducing `ExpirationInDays` to 7 or 14, or adding a
  prefix-scoped rule that expires only `FASTERQ_DUMP` scratch more aggressively (e.g. 3 days).

Add a note to `infra/readme.md` documenting the measured footprint and the conclusion, so the
next operator does not have to re-derive it.

---

## Task 3 — Add a CloudWatch alarm on workdir bucket size

### Why this is non-trivial

S3 `BucketSizeBytes` is a daily metric published to the `AWS/S3` namespace. It is **not**
emitted by default — the bucket must have **S3 Storage Lens** or **request metrics** enabled,
or the metric must be published via a scheduled Lambda. However, there is a simpler path: S3
daily storage metrics are emitted to CloudWatch automatically for buckets with versioning
enabled or, since 2023, for any bucket in a Storage Lens configuration with CloudWatch
publishing enabled.

The most practical approach for this stack is a **Storage Lens configuration** scoped to
the workdir bucket with CloudWatch metrics enabled. This does not require Lambda, does not
require versioning, and publishes `BucketSizeBytes` to `AWS/S3` once per day at no cost
beyond the standard CloudWatch metric storage fee.

### Changes to `infra/batch-stack.yaml`

#### 1. Add a Storage Lens configuration (or use a scheduled Lambda)

**Option A — S3 Storage Lens (recommended, declarative):**

Add to the `Resources:` section:

```yaml
  WorkDirStorageLens:
    Type: AWS::S3::StorageLens
    Properties:
      StorageLensConfiguration:
        Id: !Sub "${ProjectTag}-workdir-lens"
        IsEnabled: true
        DataExport:
          CloudWatchMetrics:
            IsEnabled: true
        Include:
          Buckets:
            - !Sub "arn:aws:s3:::${WorkDirBucketName}"
        AccountLevel:
          BucketLevel: {}
      Tags:
        - Key: Project
          Value: !Ref ProjectTag
        - Key: Environment
          Value: !Ref EnvironmentTag
```

Storage Lens publishes `BucketSizeBytes` to `AWS/S3` with dimensions
`BucketName` and `StorageLensId` once per day (metric lag: up to 48 hours).

**Option B — Scheduled Lambda (more immediate, slightly more complex):**

Add a Lambda function (similar to `BatchMetricsFunction` already in the stack) triggered
by EventBridge Scheduler every 6 hours that calls `s3api list-objects-v2` with
`--query 'sum([].Size)'` and publishes a custom metric. This avoids the 48-hour lag and
gives hourly granularity but adds Lambda cold-start complexity.

Start with Option A; switch to Option B if daily granularity proves inadequate.

#### 2. Add the CloudWatch alarm

```yaml
  WorkDirBucketSizeAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${ProjectTag}-workdir-size-high"
      AlarmDescription: >
        Workdir bucket (gutz-nf-reads-profilers-workdir) exceeds 5 TB.
        With cleanup=true this should stay near-zero; a sustained breach
        indicates cleanup is disabled (debugging mode) or a large run is
        accumulating failed-task debris. Review and drain if needed —
        see infra/readme.md, "Manual-drain runbook".
      Namespace: AWS/S3
      MetricName: BucketSizeBytes
      Dimensions:
        - Name: BucketName
          Value: !Ref WorkDirBucketName
        - Name: StorageType
          Value: StandardStorage
      Statistic: Maximum
      Period: 86400          # daily metric; 1-day period is the minimum useful window
      EvaluationPeriods: 1
      Threshold: 5497558138880   # 5 TB in bytes (5 * 1024^4)
      ComparisonOperator: GreaterThanOrEqualToThreshold
      TreatMissingData: notBreaching   # bucket may be empty; missing = OK
      AlarmActions:
        - !Ref AlarmTopic
      OKActions:
        - !Ref AlarmTopic
```

Also add the alarm ARN to the `BatchDashboard` `"alarms"` list so it appears in the
"Active Alarms" panel alongside the existing Batch job alarms.

#### 3. Add the alarm to the runner policy

The `NextflowRunnerPolicy` does not currently need `cloudwatch:DescribeAlarms` — the
operator checks the dashboard, not the CLI. No IAM change is required for the alarm itself.

### Threshold rationale

5 TB is chosen as the alarm threshold based on the following reasoning:
- With `cleanup = true` and `maxRetries = 0`, expected steady-state is < 100 GB.
- 5 TB is ~50x the expected steady state — a clear signal of an anomaly.
- At $0.023/GB/month (S3 Standard), 5 TB costs ~$115/month, which is a meaningful
  but not catastrophic cost signal that warrants investigation.

After the pilot measurements from task 1 are available, revisit whether 5 TB is
appropriate or should be tuned up/down.

---

## Task 4 — Manual-drain runbook

Add a new section to `infra/readme.md` immediately after the existing "Part 0: Tear down
the stack" section (or as a subsection of it). Suggested heading and content:

---

### Post-run workdir drain (manual cleanup)

Use this runbook when:
- The `workdir-size-high` alarm fires and you want to clear accumulated debris immediately.
- You are about to tear down the stack and want to empty the workdir bucket first (required
  before CloudFormation can delete it).
- `cleanup = true` was disabled for debugging (I06) and you want to reclaim storage before
  re-enabling it.

**Safety checks before draining:**

```bash
# 1. Confirm no pipeline run is currently active
#    (if a run is active, Nextflow will lose its cached work files and cannot -resume)
aws batch list-jobs --job-queue spot-queue --job-status RUNNING --region us-east-2 \
  --query "jobSummaryList[].{Id:jobId,Name:jobName,Status:status}" --output table

# 2. Check workdir size before and after drain
aws s3 ls s3://gutz-nf-reads-profilers-workdir --recursive --summarize --region us-east-2 \
  | tail -2
```

**Drain command:**

```bash
# Remove all objects in the workdir bucket.
# This is irreversible. Nextflow cannot resume any prior run after this.
aws s3 rm s3://gutz-nf-reads-profilers-workdir --recursive --region us-east-2
```

For very large buckets (millions of objects), `aws s3 rm --recursive` can be slow. Use
`s3api delete-objects` in batches or the S3 batch operations console for faster deletion.

**Verify the drain:**

```bash
aws s3 ls s3://gutz-nf-reads-profilers-workdir --recursive --summarize --region us-east-2 \
  | tail -2
# Expected: "Total Objects: 0" and "Total Size: 0"
```

**After draining:**
- The next pipeline run must start without `-resume` (no cached work to resume from).
- If `cleanup = true` is still disabled, re-enable it in `conf/aws_batch.config` to
  prevent the bucket from filling again.

---

Note: this runbook is distinct from the stack-teardown drain in "Part 0". The teardown
drain removes all objects so CloudFormation can delete the bucket. This post-run drain
removes debris while the stack (and bucket) remain in place.

---

## Task 5 — EBS 500 GB root volume: necessity by process type

### Current configuration

`infra/batch-stack.yaml` `BatchWorkerLaunchTemplate` sets:

```yaml
BlockDeviceMappings:
  - DeviceName: /dev/xvda
    Ebs:
      VolumeSize: 500
      VolumeType: gp3
      DeleteOnTermination: true
      Encrypted: true
```

The comment explains the reasoning:
> AL2023 ECS-optimized defaults to 30 GB, which is exhausted by fasterq-dump scratch +
> pigz output on medium SRA runs.

### Disk usage by process

| Process | Peak local disk use | Notes |
|---|---|---|
| `FASTERQ_DUMP` | 5–50 GB | fasterq-dump writes prefetch cache + two FASTQ pairs; size depends on SRA run depth |
| `clean_reads` (fastp) | 2–5 GB | reads in + reads out (compressed); modest |
| `profile_taxa` (MetaPhlAn4) | 1–2 GB | input FASTQs + BowTie2 index already on `/mnt/dbs` |
| `profile_function` (HUMAnN4) | 10–40 GB | nucleotide BLAST and diamond intermediates written to local scratch before results land in S3 |
| `count_reads`, `MULTIQC`, combine steps | < 1 GB | text files only |
| `MEDI_QUANT` (Kraken2 + Bracken) | 2–5 GB | classification output + Bracken re-estimation |

### Discussion

All Batch workers in both compute environments share the same launch template, so all process
types get the same 500 GB root volume. This is correct for `FASTERQ_DUMP` and
`profile_function` but wastes EBS provisioning cost for lightweight processes (fastp,
MultiQC, combine steps).

AWS Batch does not support per-job-definition EBS overrides on launch templates without
creating separate launch templates per compute environment. The practical options are:

1. **Keep 500 GB for all workers (current approach):** Simple, safe. Cost is ~$0.055/hr
   per worker while the instance is running, $0 when the fleet scales to zero. For short
   tasks (fastp runs in minutes), the EBS cost is negligible relative to EC2 instance cost.

2. **Two launch templates: large (500 GB) for FASTERQ_DUMP + HUMAnN4, small (100 GB)
   for everything else:** Requires two separate compute environments pointed at different
   launch templates, and process-level `queue` overrides in `aws_batch.config` to route
   heavy processes to the large-EBS CE and light processes to the small-EBS CE. Reduces EBS
   cost but significantly increases infrastructure complexity.

3. **Reduce to 200–300 GB:** If pilot measurements show HUMAnN4 scratch never exceeds
   150 GB on the deepest samples, a smaller volume may be safe. The current 500 GB provides
   ~3x headroom over the largest plausible fasterq-dump output; confirm against pilot data.

### Recommendation

After the I09 pilot, inspect worker disk usage during active jobs:

```bash
# From a worker node (SSM session):
df -h /
du -sh /tmp /var/lib/docker /home
```

Or check Nextflow's `disk` column in the trace TSV (if `process.disk` is set; it is not
currently set in `aws_batch.config`, which means Nextflow does not track or request a
minimum disk size). Consider adding `disk = '200 GB'` to resource requests for
`FASTERQ_DUMP` and `profile_function` in `aws_batch.config` to make disk requirements
explicit in traces, even though they do not affect EBS provisioning under the current
single-launch-template model.

Document the outcome — whether 500 GB is confirmed adequate, reduced, or split across two
templates — in `infra/readme.md` alongside the EBS cost note already present in the
`BatchWorkerLaunchTemplate` comment.

---

## Verification checklist

- [ ] Task 1: pilot measurements recorded (GB/sample, breakdown by process)
- [ ] Task 2: lifecycle adequacy conclusion documented in `infra/readme.md`
- [ ] Task 3: `WorkDirStorageLens` and `WorkDirBucketSizeAlarm` added to `infra/batch-stack.yaml`; template validates cleanly; alarm appears in dashboard "Active Alarms" panel
- [ ] Task 3: alarm fires correctly in a test (set threshold temporarily to a small value, upload a test object, confirm SNS email arrives)
- [ ] Task 4: manual-drain runbook added to `infra/readme.md`; safety checks tested (list running jobs, verify size before/after a test drain on an empty or staging bucket)
- [ ] Task 5: EBS sizing decision documented in `infra/readme.md`; pilot disk-usage measurements recorded; `disk` resource added to `aws_batch.config` for `FASTERQ_DUMP` and `profile_function` if column is absent from traces
