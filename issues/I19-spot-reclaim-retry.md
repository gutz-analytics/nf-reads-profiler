# I19 — Spot-reclaim retry: enable `aws.batch.maxSpotAttempts`

## Status

Proposed — 2026-04-29. Diagnosed live from `.nextflow.log` after the
2026-04-29 18:32 UTC run aborted on a single spot interruption despite
`process.maxRetries = 5` being set.

## Problem

The 2026-04-29 max005 run aborted at 18:32 UTC when worker
`i-0661383eb3f9f1878` was reclaimed mid-`profile_taxa (SRR36835882)`.
With `maxRetries = 5` on the process, the task should have been
resubmitted; instead the whole pipeline shut down and 5 in-flight
siblings were killed.

Final stats from `.nextflow.log`:

```
WorkflowStats[succeededCount=19; failedCount=1; ...; retriesCount=0; abortedCount=5; ...]
```

`retriesCount=0` confirms no retry was ever attempted.

## Why `maxRetries` didn't help

AWS Batch surfaces a reclaimed host as `Host EC2 (instance i-...) terminated.`
with no exit code. Nextflow treats this as a fatal `ProcessFailedException`
and goes straight to `Session aborted` — it never increments
`task.attempt`, so the `'retry'` errorStrategy (the default when
`maxRetries > 0`) never fires.

The two layers that handle this case are:

| Layer | Setting | What it does |
|---|---|---|
| AWS Batch | `aws.batch.maxSpotAttempts` | Batch re-queues the job transparently on host termination, *before* the failure surfaces to Nextflow. |
| Nextflow process | `errorStrategy = { task.attempt <= N ? 'retry' : 'terminate' }` | Routes the host-terminated branch through `process.maxRetries`. |

`process.maxRetries` alone catches non-zero exits, OOM, and timeouts, but
*not* host termination. Today's config has `maxRetries = 5` and no
`maxSpotAttempts`, which is why a single reclaim killed the run.

## Fix

Set `aws.batch.maxSpotAttempts = 5` in `conf/aws_batch.config`. Batch
will re-queue the job up to 5 times on host termination before failing
through to Nextflow's process-level retry path. Cleanest because:

- Catches the specific failure mode that bypasses `process.maxRetries`.
- Doesn't change behavior for non-spot failures (OOM, timeouts, real
  exit-code failures still go through `maxRetries = 5`).
- No `errorStrategy` closure to maintain per-process.

The two retry layers stack: a job that's reclaimed 5 times *and* then
hits a real failure still gets 5 process-level retries. Total worst-case
is 25 attempts, which is fine — `resourceLimits` already prevents
runaway escalation.

## Files to change

| File | Change |
|---|---|
| `conf/aws_batch.config` | Add `maxSpotAttempts = 5` to the `aws.batch { ... }` block. |

## Acceptance criteria

- [ ] After change, a worker reclaim during a run results in the failed
      task being re-queued (visible as a duplicate Batch job submission
      for the same task) rather than aborting the pipeline.
- [ ] `WorkflowStats` shows `retriesCount > 0` after a run that
      experienced reclaims.
- [ ] No regression on non-spot failures: real OOM / timeout failures
      still hit the `maxRetries = 5` path and don't get 25 attempts
      unless they also looked like host termination.

## Out of scope

- Per-process errorStrategy overrides — not needed if `maxSpotAttempts`
  alone proves sufficient. Reopen this issue if the same failure mode
  recurs after the fix.
- Tuning `maxSpotAttempts` per process. Single global value is fine
  until measurement says otherwise.
- Changing `process.maxRetries` from 5. The two layers are
  complementary, not substitutes.

## Related

- I02 — README hygiene flagged a stale "maxRetries=3" doc string but
  didn't catch that even the corrected `maxRetries = 5` doesn't handle
  host termination.
- I09 — pilot-run playbook tracks spot interruption count; this issue
  is the fix that makes those interruptions non-fatal.
- I24 — Fast Snapshot Restore makes spots boot fast but does not reduce
  reclaim frequency. I19 + I24 together: fast boots *and* survivable
  reclaims.
