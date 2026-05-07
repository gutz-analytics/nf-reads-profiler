# I04: Verify CloudWatch Alarms and `aws logs tail` for AWS Batch

**Status:** **DONE — 2026-04-27.** Verified end-to-end. See "Verification
results" below for what was tested. One follow-up bug uncovered (I17:
`high-pending` alarm watched the wrong Batch state) — fixed and deployed
as `batch-high-runnable` (RunnableJobCount gauge, scheduled poll). See I17.

**Priority:** Medium
**Size:** Small
**Dependencies:** None (stack must already be deployed and SNS subscription confirmed)

---

## Verification results (2026-04-27)

### Alarm pipeline — bidirectional, end-to-end verified

| Test | Result | Details |
|---|---|---|
| `batch-failed-jobs` ALARM transition | PASS | Fired at 19:58:14 UTC (`Sum=6 ≥ 5` in window 19:50:00) |
| `batch-failed-jobs` OK recovery | PASS | Resolved at 20:12:53 UTC (missing-data → notBreaching) |
| SNS email on ALARM | PASS | Delivered to `colin+claude@vasogo.com` ~1 min after state change |
| SNS email on OK | PASS | Delivered ~1 min after state change |
| Lambda emits `FailedJobCount` metric | PASS | Datapoint of 6.0 confirmed via `get-metric-statistics` |
| CloudWatch evaluation on 5-min windows | PASS | Bursty failure pattern detected as expected |

### Alarm pipeline — `high-pending` behavior

| Test | Result | Details |
|---|---|---|
| `batch-high-pending` ALARM transition | **FAIL** | Did NOT fire after 27 min with threshold=5 and 10 jobs queued (8 vCPU each, 80 vCPUs requested vs 16 vCPU spot CE limit) |
| `PendingJobCount` metric publication | NEVER | `get-metric-statistics` returned 0 datapoints in 30-min window |

Root cause: jobs go SUBMITTED → RUNNABLE → STARTING → RUNNING. The Batch
state `PENDING` only fires for dependency-blocked jobs, which Nextflow
never produces. The Lambda only emits on the literal `PENDING` event,
so the metric never receives data. **The alarm watches the wrong state.**

Tracked as **I17 — Fix `high-pending` alarm to track RUNNABLE, not PENDING**.

### Live job logs

| Item | Result |
|---|---|
| Actual log group | `/aws/batch/job` (the Batch default) |
| Stack-provisioned `/aws/batch/nf-reads-profiler` | EMPTY (0 bytes) — Nextflow job defs don't override `logConfiguration` |
| Stream prefix observed | `nf-<image-tag>/default/<job-id>` (e.g. `nf-barbarahelena-humann-4-0-3/default/...`) |
| `aws logs tail /aws/batch/job --follow --region us-east-2` | PASS — confirmed working |

`infra/readme.md` "Live job logs" section updated with the correct log
group, real stream prefix examples, and 3 example commands.

### SNS subscription

| Item | Result |
|---|---|
| Topic ARN | `arn:aws:sns:us-east-2:730883236839:nf-reads-profiler-alerts` |
| Pre-test state | **0 subscriptions** — alarms would have fired silently |
| Post-fix state | 1 confirmed subscription: `colin+claude@vasogo.com` |

`infra/readme.md` "CloudWatch Alarms" section updated with the SNS
verification command operators should run before relying on alarms.

### Test artifacts (cleaned up)

- 6× `alarm-test-fail` jobs submitted, all FAILED, alarm tripped, jobs aged out.
- 10× `alarm-test-pending` jobs submitted, 7 terminated, 3 SUCCEEDED before terminate.
- `alarm-test-fail:1` and `alarm-test-pending:1` job definitions deregistered.
- `batch-high-pending` alarm threshold restored from 5 → 50.

---

## Background

The CFN stack (`infra/batch-stack.yaml`) provisions two CloudWatch alarms:

| Alarm name | Metric | Threshold | Window |
|---|---|---|---|
| `nf-reads-profiler-batch-failed-jobs` | `AWS/Batch / FailedJobCount` | Sum >= 5 | 1 × 5 min period |
| `nf-reads-profiler-batch-high-pending` | `AWS/Batch / PendingJobCount` | Maximum >= 50 | 3 × 5 min periods (15 min) |

Both alarms are dimensioned on the full ARN of `spot-queue` and notify
`nf-reads-profiler-alerts` (SNS → email). Metrics are fed by an EventBridge
rule (`nf-reads-profiler-batch-job-state-change`) that invokes the Lambda
`nf-reads-profiler-batch-metrics` on every Batch Job State Change event. The
Lambda publishes one count (value = 1) per event into the `AWS/Batch`
namespace.

AWS Batch does **not** emit `FailedJobCount` / `PendingJobCount` natively;
these metrics only exist when the Lambda pipeline has fired at least once.
The CloudWatch log group for job output is `/aws/batch/nf-reads-profiler`, but
the log **stream** names vary per job definition and are only visible after
real jobs run.

This issue covers end-to-end manual verification of both alarms and the log
tail command.

---

## Tasks

### Task 1 — Trip `batch-failed-jobs`

The threshold is **5 failures in a single 5-minute period**. One failing job
will NOT trigger it. You must submit at least 5 jobs in quick succession so
all their FAILED events land in the same 5-minute CloudWatch evaluation window.

#### 1a. Look up the queue ARN and a registered job definition

```bash
# Get spot-queue ARN (needed for the alarm dimension — already set in CFN)
QUEUE_ARN=$(aws cloudformation describe-stacks \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2 \
  --query "Stacks[0].Outputs[?OutputKey=='SpotQueueArn'].OutputValue" \
  --output text)
echo "Queue ARN: $QUEUE_ARN"

# List registered job definitions — pick any ACTIVE one
aws batch describe-job-definitions \
  --region us-east-2 \
  --status ACTIVE \
  --query "jobDefinitions[].{Name:jobDefinitionName,Arn:jobDefinitionArn}" \
  --output table
```

#### 1b. Register a minimal failing job definition (if none exists)

```bash
# Registers a one-shot job that always exits 1
aws batch register-job-definition \
  --region us-east-2 \
  --job-definition-name alarm-test-fail \
  --type container \
  --container-properties '{
    "image": "public.ecr.aws/amazonlinux/amazonlinux:2023",
    "vcpus": 1,
    "memory": 512,
    "command": ["sh", "-c", "exit 1"]
  }'
```

#### 1c. Submit 6 failing jobs at once

Six jobs gives a comfortable buffer above the threshold of 5, in case one
completes in an adjacent evaluation window.

```bash
for i in $(seq 1 6); do
  aws batch submit-job \
    --region us-east-2 \
    --job-name "alarm-test-fail-$i" \
    --job-queue spot-queue \
    --job-definition alarm-test-fail
done
```

#### 1d. Watch job statuses

```bash
# Poll until all 6 reach a terminal state (SUCCEEDED or FAILED)
aws batch list-jobs \
  --region us-east-2 \
  --job-queue spot-queue \
  --job-status FAILED \
  --query "jobSummaryList[?starts_with(jobName,'alarm-test-fail')].[jobName,status]" \
  --output table
```

#### 1e. Verify the alarm fired

```bash
aws cloudwatch describe-alarms \
  --region us-east-2 \
  --alarm-names "nf-reads-profiler-batch-failed-jobs" \
  --query "MetricAlarms[0].{State:StateValue,Reason:StateReason}"
```

Expected: `"State": "ALARM"`. Wait for the SNS email to arrive (usually within
1–2 minutes of the alarm transitioning).

---

### Task 2 — Trip `batch-high-pending`

The threshold is **Maximum >= 50 pending for 3 consecutive 5-minute periods
(15 minutes total)**. The easiest approach for a test environment is to
temporarily lower the threshold to 5, submit enough jobs to saturate the
vCPU limit, then restore the threshold.

#### 2a. Lower the alarm threshold to 5 for testing

```bash
# Fetch the queue ARN (used as the dimension value)
QUEUE_ARN=$(aws cloudformation describe-stacks \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2 \
  --query "Stacks[0].Outputs[?OutputKey=='SpotQueueArn'].OutputValue" \
  --output text)

SNS_ARN=$(aws sns list-topics --region us-east-2 \
  --query "Topics[?ends_with(TopicArn,'nf-reads-profiler-alerts')].TopicArn" \
  --output text)

aws cloudwatch put-metric-alarm \
  --region us-east-2 \
  --alarm-name "nf-reads-profiler-batch-high-pending" \
  --alarm-description "TEST: threshold temporarily lowered to 5 for verification" \
  --namespace AWS/Batch \
  --metric-name PendingJobCount \
  --dimensions Name=JobQueue,Value="$QUEUE_ARN" \
  --statistic Maximum \
  --period 300 \
  --evaluation-periods 3 \
  --threshold 5 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$SNS_ARN"
```

#### 2b. Submit enough jobs to exceed vCPU limits

With `MaxvCPUsSpot=16` and `MaxvCPUsOnDemand=8`, submitting 10+ jobs each
requesting 8 vCPUs will saturate capacity and leave the remainder pending.
Use a long-running command so jobs stay in RUNNING/PENDING long enough for
three evaluation windows.

```bash
aws batch register-job-definition \
  --region us-east-2 \
  --job-definition-name alarm-test-pending \
  --type container \
  --container-properties '{
    "image": "public.ecr.aws/amazonlinux/amazonlinux:2023",
    "vcpus": 8,
    "memory": 4096,
    "command": ["sh", "-c", "sleep 1200"]
  }'

for i in $(seq 1 10); do
  aws batch submit-job \
    --region us-east-2 \
    --job-name "alarm-test-pending-$i" \
    --job-queue spot-queue \
    --job-definition alarm-test-pending
done
```

#### 2c. Verify pending count is rising

```bash
aws batch list-jobs \
  --region us-east-2 \
  --job-queue spot-queue \
  --job-status PENDING \
  --query "length(jobSummaryList)"
```

#### 2d. Wait 15+ minutes, then check alarm state

```bash
aws cloudwatch describe-alarms \
  --region us-east-2 \
  --alarm-names "nf-reads-profiler-batch-high-pending" \
  --query "MetricAlarms[0].{State:StateValue,Reason:StateReason}"
```

#### 2e. Clean up — terminate test jobs and restore alarm threshold

```bash
# Terminate all pending/running test jobs
for JOB_ID in $(aws batch list-jobs --region us-east-2 \
    --job-queue spot-queue --job-status PENDING \
    --query "jobSummaryList[?starts_with(jobName,'alarm-test-pending')].jobId" \
    --output text); do
  aws batch terminate-job --region us-east-2 --job-id "$JOB_ID" --reason "test cleanup"
done

for JOB_ID in $(aws batch list-jobs --region us-east-2 \
    --job-queue spot-queue --job-status RUNNING \
    --query "jobSummaryList[?starts_with(jobName,'alarm-test-pending')].jobId" \
    --output text); do
  aws batch terminate-job --region us-east-2 --job-id "$JOB_ID" --reason "test cleanup"
done

# Restore alarm to production threshold (50, matching the CFN template)
QUEUE_ARN=$(aws cloudformation describe-stacks \
  --stack-name nf-reads-profiler-batch \
  --region us-east-2 \
  --query "Stacks[0].Outputs[?OutputKey=='SpotQueueArn'].OutputValue" \
  --output text)

SNS_ARN=$(aws sns list-topics --region us-east-2 \
  --query "Topics[?ends_with(TopicArn,'nf-reads-profiler-alerts')].TopicArn" \
  --output text)

aws cloudwatch put-metric-alarm \
  --region us-east-2 \
  --alarm-name "nf-reads-profiler-batch-high-pending" \
  --alarm-description "50+ jobs pending on spot-queue for 15+ minutes. Spot capacity may be exhausted and on-demand vCPU limit reached. Consider raising MaxvCPUsOnDemand." \
  --namespace AWS/Batch \
  --metric-name PendingJobCount \
  --dimensions Name=JobQueue,Value="$QUEUE_ARN" \
  --statistic Maximum \
  --period 300 \
  --evaluation-periods 3 \
  --threshold 50 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$SNS_ARN"
```

---

### Task 3 — Confirm SNS email notifications

After each alarm fires:

1. Check the inbox for the `BudgetAlertEmail` address (currently `colin@vasogo.com`).
2. Expected subject: `ALARM: "nf-reads-profiler-batch-failed-jobs" in US East (Ohio)` (or `batch-high-pending`).
3. The email arrives from `no-reply@sns.amazonaws.com` via the SNS topic
   `nf-reads-profiler-alerts`.
4. If the email does not arrive within 5 minutes, check whether the SNS
   subscription is confirmed:

```bash
aws sns list-subscriptions-by-topic \
  --region us-east-2 \
  --topic-arn "$SNS_ARN" \
  --query "Subscriptions[].{Protocol:Protocol,Endpoint:Endpoint,Status:SubscriptionArn}"
```

   An unconfirmed subscription shows `"Status": "PendingConfirmation"`. Re-send
   the confirmation email if needed:

```bash
# SNS does not have a resend API; re-subscribe to trigger a new confirmation email
aws sns subscribe \
  --region us-east-2 \
  --topic-arn "$SNS_ARN" \
  --protocol email \
  --notification-endpoint colin@vasogo.com
```

---

### Task 4 — Document working `aws logs tail` command

The CloudWatch log group `/aws/batch/nf-reads-profiler` is created by the CFN
stack, but log **streams** are created per job definition and only appear after
real jobs have run. The stream name format used by Batch is:

```
<job-definition-name>/<container-name>/<job-id>
```

#### 4a. List actual stream names after jobs run

```bash
# List the 20 most recent log streams in the group
aws logs describe-log-streams \
  --region us-east-2 \
  --log-group-name /aws/batch/nf-reads-profiler \
  --order-by LastEventTime \
  --descending \
  --max-items 20 \
  --query "logStreams[].logStreamName"
```

Note the exact prefix (job definition name) from the output — it will look
something like `nf-job-<process-name>/default/<job-id>` or
`alarm-test-fail/default/<job-id>` depending on the job definition name.

#### 4b. Tail all streams in the group (most common usage)

```bash
# Follow all streams — new log events from any running job appear in real time
aws logs tail /aws/batch/nf-reads-profiler \
  --follow \
  --region us-east-2
```

#### 4c. Tail a specific job definition prefix

Once you know the stream prefix from 4a:

```bash
# Replace <job-definition-name> with the actual name observed in 4a
aws logs tail /aws/batch/nf-reads-profiler \
  --log-stream-name-prefix "<job-definition-name>/" \
  --follow \
  --region us-east-2
```

#### 4d. Fetch logs for a specific job ID

```bash
# Get the log stream name from a job's detail
JOB_ID="<paste-job-id-here>"
aws batch describe-jobs \
  --region us-east-2 \
  --jobs "$JOB_ID" \
  --query "jobs[0].container.logStreamName"

# Then tail that specific stream
LOG_STREAM=$(aws batch describe-jobs \
  --region us-east-2 \
  --jobs "$JOB_ID" \
  --query "jobs[0].container.logStreamName" \
  --output text)

aws logs get-log-events \
  --region us-east-2 \
  --log-group-name /aws/batch/nf-reads-profiler \
  --log-stream-name "$LOG_STREAM" \
  --query "events[].message" \
  --output text
```

---

### Task 5 — Document results in `infra/readme.md`

After completing tasks 1–4, update the "Untested: CloudWatch Alarms" section
and "Untested: Live job logs" section in `infra/readme.md`:

- Change "Untested" heading labels to "Verified (date)".
- Record the actual log stream name prefix observed in Task 4a.
- Replace the placeholder `aws logs tail` command with the confirmed working form.
- Note the email address that received the alarm notifications and confirm the
  SNS subscription is in `Confirmed` state.

---

## Acceptance Criteria

- [ ] `batch-failed-jobs` alarm transitions to ALARM state after 5+ failing jobs in 5 min.
- [ ] `batch-high-pending` alarm transitions to ALARM state (tested at threshold = 5 before restoring to 50).
- [ ] SNS email notification received for both alarms at `colin@vasogo.com`.
- [ ] SNS subscription status is `Confirmed` (not `PendingConfirmation`).
- [ ] `aws logs tail /aws/batch/nf-reads-profiler --follow --region us-east-2` confirmed working.
- [ ] Actual log stream name prefix documented (observed from real job output).
- [ ] `infra/readme.md` updated: "Untested" sections replaced with verified commands and date.
- [ ] `batch-high-pending` threshold restored to 50 after testing.
- [ ] Test job definitions (`alarm-test-fail`, `alarm-test-pending`) deregistered after verification:

```bash
aws batch deregister-job-definition \
  --region us-east-2 \
  --job-definition alarm-test-fail:1

aws batch deregister-job-definition \
  --region us-east-2 \
  --job-definition alarm-test-pending:1
```

---

## Notes

- The Lambda (`nf-reads-profiler-batch-metrics`) publishes one data point per
  job state-change event. CloudWatch aggregates these with `Sum` over the
  5-minute period. If jobs fail faster than one per second, all 5+ FAILED
  events should land in the same period — submitting 6 jobs simultaneously
  is sufficient.
- The `PendingJobsAlarm` uses `Maximum` statistic, not `Sum`. Each Lambda
  invocation with `status: PENDING` emits value = 1. To accumulate 50+ on the
  Maximum statistic, the same job would need to emit 50 PENDING events, which
  does not happen. This means the production threshold of 50 is likely
  unreachable with the current Lambda design (emits 1 per event, not the
  actual queue depth). **This is a potential bug to investigate separately.**
  For this verification task, lower the threshold to 5 to confirm the alarm
  pipeline is wired correctly end-to-end.
- Spot interruptions are retried by `maxRetries=3` in `aws_batch.config` and
  show up as FAILED then re-SUBMITTED in the EventBridge stream — they will
  eventually count toward `FailedJobCount` if all retries are exhausted.
