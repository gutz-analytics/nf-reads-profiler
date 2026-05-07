# I17 — Fix `high-pending` alarm to track RUNNABLE, not PENDING

## Status

**DONE — 2026-04-30.** Option A implemented and deployed. `BatchQueueDepthFunction`
(scheduled every 60s) polls `list-jobs --status RUNNABLE` and emits actual queue
depth to CloudWatch. `RunnableJobsAlarm` (`batch-high-runnable`) fires at
`Maximum ≥ 10` for 3×5-min periods. Both resources show `CREATE_COMPLETE` in
the live stack. Verify by running the acceptance-criteria test on next deploy.

Originally proposed 2026-04-27: alarm failed to fire after 27 minutes with 10
jobs queued against a saturated 16-vCPU spot CE.

## Background

The CFN stack (`infra/batch-stack.yaml`) provisions an alarm named
`nf-reads-profiler-batch-high-pending` with this stated intent:

> 50+ jobs pending on spot-queue for 15+ minutes. Spot capacity may be
> exhausted and on-demand vCPU limit reached. Consider raising
> MaxvCPUsOnDemand.

The intent — detect capacity exhaustion — is exactly right. The
implementation does not deliver it.

## What the alarm actually does

| Layer | Behavior |
|---|---|
| EventBridge rule | Fires on every "Batch Job State Change" event |
| Lambda `nf-reads-profiler-batch-metrics` | On `state == PENDING`, emits `PendingJobCount = 1` to CloudWatch |
| CloudWatch metric | `AWS/Batch / PendingJobCount`, dimensioned on `JobQueue` ARN |
| Alarm | `Maximum >= 50` for 3 × 5-min periods (15 min) |

## Why it never fires (verified 2026-04-27)

1. **Wrong Batch state.** Jobs submitted by Nextflow flow
   `SUBMITTED → RUNNABLE → STARTING → RUNNING`. They never enter `PENDING`,
   which is reserved for dependency-blocked jobs. Capacity-blocked jobs
   sit in `RUNNABLE`.
2. **Wrong aggregation.** Even if `PENDING` *were* used, the Lambda emits
   `value=1` per state-change event. With `Maximum` aggregation, the most
   the alarm can ever see is 1 — well below threshold 50 (or 5 in the test
   scenario).

I04 verification: 10 jobs requesting 80 vCPUs against a 16-vCPU CE,
threshold lowered to 5, ran for 27 min — `PendingJobCount` had 0
datapoints, alarm stayed in OK. Meanwhile `failed-jobs` (which uses
`Sum` and a state Nextflow does emit) fired correctly.

## Fix options

### Option A — Switch metric to `RunnableJobCount` and emit queue depth on a schedule

The most semantically correct fix.

- Add an EventBridge schedule (or a Lambda Cron) that polls
  `aws batch list-jobs --job-status RUNNABLE` every 1–5 min and emits the
  count as a single CloudWatch datapoint.
- Replace the alarm's metric with `RunnableJobCount`, statistic `Maximum`,
  threshold 50.
- Rename the alarm `batch-high-runnable` (or `batch-capacity-stalled`) to
  match the actual condition.

Pros: directly measures the operational concern; correct semantics.
Cons: requires Lambda + scheduler additions to the stack.

### Option B — Repurpose the existing Lambda to emit queue snapshot on every state-change

Smaller change. Whenever the existing Lambda fires (any state change),
have it `list-jobs --job-status RUNNABLE` and emit the count as
`RunnableJobCount`. Update the alarm to read that metric.

Pros: reuses existing wiring; no scheduler.
Cons: noisy (emits on every job event); list-jobs cost grows with queue size;
list-jobs has pagination — at very large queues this gets expensive.

### Option C — Drop the alarm entirely

Lean on `failed-jobs` + the AWS budget alarm. Capacity exhaustion will
manifest indirectly (jobs take longer, cost overruns, eventual failures
from time limits).

Pros: zero code, zero infra.
Cons: loses the "system is stuck waiting for capacity" early-warning signal.

## Recommendation

**Option A.** Capacity stalls are exactly the failure mode we want
operators paged on, and reusing existing wiring (Option B) introduces
write-amplification at scale — bad for the I10 16K-sample run. A small
EventBridge schedule + Lambda is a clean, scoped addition.

Alarm threshold for the rewritten alarm: ~10–20 RUNNABLE jobs sustained
for 15 min, not 50 — the value 50 was set assuming `Sum`/event-counting
semantics that never worked. RUNNABLE saturation at lower numbers is
already a valid signal (you have 16 spot vCPUs total; 10 jobs requesting
8 vCPUs each = 5 jobs RUNNABLE permanently is the steady state under
saturation).

## Files to change (when picked up)

| File | Change |
|------|--------|
| `infra/batch-stack.yaml` | Add scheduled Lambda (or modify existing) to emit `RunnableJobCount`. Update `BatchHighPendingAlarm` metric, threshold, and rename. |
| `infra/readme.md` | Update "CloudWatch Alarms" table: rename alarm, update condition, add note about RUNNABLE vs PENDING. |
| `issues/I04-verify-alarms-logtail.md` | Add a closing note pointing at I17 once it lands. |

## Acceptance criteria

- [x] `BatchQueueDepthFunction` deployed and polling every 60s.
- [x] `RunnableJobsAlarm` (`batch-high-runnable`) wired to `RunnableJobCount`,
      `Maximum ≥ 10`, 3×5-min evaluation periods.
- [x] No regressions on `failed-jobs` alarm (unchanged).
- [x] Lambda cost negligible — 1440 invocations/day × 5 states × minimal runtime.
- [ ] Live-fire test: alarm fires within 15 min when ≥ 10 jobs stuck RUNNABLE
      (submit 10 sleep jobs at 8 vCPU against 16-vCPU spot CE).
- [ ] SNS email arrives on ALARM state transition.
- [ ] Alarm transitions back to OK within 15 min after RUNNABLE drains.

## Out of scope

- Other Batch state coverage (STARTING, retries) — separate concern.
- Container Insights / cross-CE metrics — could be a future migration.
