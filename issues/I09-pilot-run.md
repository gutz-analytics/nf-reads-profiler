# I09: Pilot run — ~100 samples on AWS Batch (cost/time measurement)

**Priority:** High
**Size:** Medium
**Dependencies:** I00 (containerOptions fix — blocker), I06 (memory + time-cap fix — blocker); I05 (smoke test) strongly recommended first
**Files:** `infra/pilot-results.md` (created by this run), `infra/readme.md` (document lessons learned)

> **DO NOT execute this pilot until explicitly authorized.** This issue documents
> the procedure and acceptance criteria; it does not constitute a go-ahead.

---

## Goal

Run ~100 small metagenomics samples through the full MetaPhlAn + HUMAnN4
pipeline on AWS Batch (Graviton spot) to:

1. Validate end-to-end correctness at non-trivial scale.
2. Measure per-sample wall time and memory (`peak_rss`) for each major process.
3. Estimate total cost and extrapolate to the 16K production run.
4. Surface any spot-interruption, DB-sync, or head-node issues before they
   affect 16K samples.

MEDI is **deferred** — not included in this pilot. No `--enable_medi` flag.

---

## Prerequisites

All of the following must be confirmed complete before kicking off the pilot:

- [ ] **I00 landed:** `profile_function` and `combine_humann_tables`
  `containerOptions` use escaped `\$(id -u):\$(id -g)` (or the flag is
  removed for Batch). Without this fix every job fails at submission.
- [ ] **I06 landed:** `resourceLimits.time` raised from 2h to ≥6h;
  `profile_function` memory raised from 32 GB to 64 GB;
  `nreads` lowered to 32M; `cleanup = true` disabled for debugging.
  Without I06, HUMAnN jobs are silently killed at 2h and OOM-killed at 32 GB.
- [ ] **I05 completed (recommended):** 2–4 sample smoke test passed, TSV
  outputs sanity-checked. If I05 has not run, proceed only with explicit
  authorization and accept higher risk of wasted spend.
- [ ] Head-node runner VM is reachable and the `head-node-role` IAM role has
  `nf-reads-profiler-nextflow-runner-policy` attached.
- [ ] `MaxvCPUsSpot=16` is the active value in the deployed stack — do NOT
  raise this for the pilot (see Parallelism section below).
- [ ] AWS Budgets alert is set to $200 for the debugging phase (I03).
- [ ] Samplesheet `sra-child-min100.csv` exists in S3 and is validated:
  `aws s3 ls s3://gutz-nf-reads-profilers-runs/samplesheets/sra-child-min100.csv`

---

## Run command

Execute on the head-node runner VM from the `nf-reads-profiler` repo root,
on the `ongoing-infra` branch (or whichever branch carries I00 + I06):

```bash
nextflow run main.nf \
  -profile aws \
  --input s3://gutz-nf-reads-profilers-runs/samplesheets/sra-child-min100.csv \
  --project child_min_aws_batch \
  -resume
```

No additional flags. Do not set `--enable_medi`. Do not override `nreads`,
`minreads`, or any DB paths — these are set correctly in `conf/aws_batch.config`.

### Parallelism guardrail

`MaxvCPUsSpot=16` limits the stack to 2 concurrent 8-vCPU jobs (one
`profile_taxa` or `profile_function` job per worker). Do **not** raise this
value for the pilot. Raising it before cost/time data is in hand could
multiply any per-sample failure into a large and expensive failure storm.

Production `MaxvCPUsSpot` will be set explicitly in I10 after pilot results
are reviewed.

---

## Metrics to capture

All metrics come from the Nextflow trace file
(`outdir/child_min_aws_batch/reports/trace-<timestamp>.txt`) and from the
AWS Batch job history in the console.

### 1. Total wall time

The elapsed time from `nextflow run` invocation to pipeline completion.
Record start and end timestamps from the Nextflow log or terminal session.

### 2. Per-sample runtime — p50 and p95

From the trace file, compute the 50th and 95th percentile of the `realtime`
column, broken down by process name. Processes of interest:

| Process | Typical role | Expected range |
|---|---|---|
| `clean_reads` | fastp trimming | minutes |
| `profile_taxa` | MetaPhlAn4 | 30–120 min |
| `profile_function` | HUMAnN4 | 60–360 min |
| `FASTERQ_DUMP` | SRA download (if applicable) | varies |

Report p50 and p95 for each. If p95 for `profile_function` exceeds 5h,
flag for review before the production run — the 6h `time` cap in I06 may
need to be raised.

### 3. `peak_rss` validation

Extract the `peak_rss` column from the trace for each process. The hard
limits are:

| Process | Limit | Action if exceeded |
|---|---|---|
| `profile_function` | **< 64 GB** (must not exceed) | STOP — do not run 16K until memory is addressed |
| `profile_taxa` | **< 38 GB** (should not exceed) | investigate — DB may have grown |

If any `profile_function` sample exceeds 64 GB `peak_rss`, the job will have
been killed by the OS/Batch; investigate OOM events in CloudWatch logs before
proceeding.

### 4. Spot interruption count

In the AWS Batch console, filter the job history for project
`child_min_aws_batch` and count FAILED jobs where the status reason contains
`"host terminated"` or `"Host EC2 was terminated"`. This is the spot
interruption count for the pilot.

If interruptions exceed 10% of submitted jobs (~10 of 100), consider switching
`profile_function` to the on-demand queue for production, or raising the spot
bid percentage.

### 5. Total cost estimate

From the trace file, sum the `realtime` values for all jobs that ran on
`r8g.2xlarge` workers (the expected instance type). Convert to instance-hours
and multiply by the spot price:

```
cost_estimate = (sum_realtime_hours) × $0.18/hr
```

Spot price for `r8g.2xlarge` in `us-east-2` is approximately **$0.18/hr**
as of 2026-04. Verify the current spot price in the EC2 console before
computing — it fluctuates. The trace `realtime` column reports wall time per
task; instance cost accrues for the full instance hour, so round up each task
to the nearest hour when the instance is not shared.

Note: `clean_reads` and `FASTERQ_DUMP` run on smaller/cheaper instances
(default 4 vCPU / 32 GB); separate their cost if instance type data is
available from the trace or Batch job detail.

### 6. Extrapolation to 16K samples

From the pilot p50 per-sample wall time for `profile_function` (the
bottleneck):

```
16K_wall_time_days = (p50_profile_function_hours × 16000) / (MaxvCPUsSpot / 8)
16K_cost_estimate  = (p50_profile_function_hours × 16000) × $0.18
```

Report as a point estimate with ±30% confidence bounds (derived from the
p95/p50 ratio observed in the pilot). If the p95/p50 ratio exceeds 3×,
widen the bounds accordingly and flag in the results.

---

## Output validation

For each sample, confirm the following outputs exist and pass a plausibility
check. Do not diff against a gold standard — sanity checks only.

### MetaPhlAn TSVs (`outdir/.../taxa/`)

```bash
# Count non-header lines (features) in each MetaPhlAn profile
for f in outdir/child_min_aws_batch/*/taxa/*_profile.tsv; do
  count=$(grep -v '^#' "$f" | wc -l)
  echo "$count $f"
done | sort -n
```

- **Pass:** All samples have > 50 features.
- **Fail:** Any sample has 0 features (empty file or parse error) — investigate
  that sample's `profile_taxa` log before proceeding.
- Samples with 1–50 features are low-diversity; flag them but do not block the
  pilot on this alone.

### HUMAnN genefamilies and pathabundance TSVs (`outdir/.../function/`)

```bash
for f in outdir/child_min_aws_batch/*/function/*genefamilies*.tsv; do
  count=$(grep -v '^#' "$f" | wc -l)
  echo "$count $f"
done | sort -n
```

- **Pass:** All samples have > 50 features and all abundance values > 0.
- **Fail:** Any sample has 0 features, or a file is missing entirely — the
  HUMAnN job may have OOM-killed or timed out; check the trace `exit` column
  and the Batch job logs.

### No MEDI outputs expected

Confirm that no `medi/` output directory exists under any sample. If one
appears, the `--enable_medi` flag was set inadvertently.

---

## Results file

After the pilot completes and metrics are computed, write findings to
`infra/pilot-results.md`. At minimum include:

- Date and branch used.
- Nextflow version and run command.
- Sample count: submitted / completed / failed.
- Total wall time (clock time).
- Per-process p50/p95 runtime table.
- `peak_rss` summary (max observed for `profile_function` and `profile_taxa`).
- Spot interruption count and percentage.
- Total cost (observed) and cost per sample.
- Extrapolated 16K wall time and cost with confidence bounds.
- Any anomalies or failures and their root cause.
- Go / No-go recommendation for the 16K production run (I10).

---

## Budget guardrail

The debugging-phase AWS Budgets alert is set to **$200** (I03). If pilot spend
approaches this ceiling before all ~100 samples complete:

1. Stop the Nextflow run (`Ctrl-C` or `scancel`).
2. Note how many samples completed and their costs.
3. Do not re-run or raise the budget without explicit review.
4. Assess whether a smaller pilot (25 samples) is sufficient to get the
   cost/time signal needed for extrapolation.

The $200 ceiling covers both the pilot and any preceding debugging runs
(I05 smoke test, I06 memory validation, etc.). If prior debugging has already
consumed significant budget, reduce pilot scope accordingly before starting.

---

## Failure modes and mitigations

| Failure | Likely cause | Mitigation |
|---|---|---|
| All jobs fail at submission | I00 not landed | Apply containerOptions fix (I00) |
| `profile_function` OOM at ~2h | `resourceLimits.time = 2.h` still in place | Verify I06 landed; check `aws_batch.config` |
| `profile_function` OOM at 32 GB | I06 memory fix not applied | Verify `profile_function` memory = 64 GB in `community_characterisation.nf` |
| DB sync fails on workers | `cjb-gutz-s3-demo` bucket access denied | Verify `EcsInstanceRole` S3 policy; check CloudWatch UserData logs |
| Samples stuck in RUNNABLE | `MaxvCPUsSpot` exhausted or instance type unavailable | Check Batch CE status; verify Graviton instance types in CE config |
| Head node OOM at 100 jobs | Nextflow JVM heap | Add `-Xmx8g` to Nextflow JVM options; monitor head node memory |
| `combine_humann_tables` never fires | One sample blocking `groupTuple` | Check if a sample is hung; `--project` groups all samples — one failure can stall combine |

---

## Background

This pilot is issue 9 of 11 in the AWS Batch scale-out plan
(`monkey-hand/plan.md`). It gates the 16K production run (I10): the
production run checklist requires that pilot per-sample cost and runtime data
are in hand before `MaxvCPUsSpot` is raised and the full samplesheet is
submitted.
