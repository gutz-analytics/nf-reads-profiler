# I25 — Instance-type benchmark: per-vCPU-hour cost-effectiveness across Graviton generations

## Status

Proposed — 2026-04-29. Discovered during the post-FSR max005 run, where
Batch packed three workers across two Graviton generations (r8g.2xlarge,
r7g.2xlarge) running the same `profile_taxa` workload — exactly the
data needed to compare per-task cost/wallclock across generations.

## Headline question

**How much do newer-generation Graviton single-thread improvements help
the single-threaded parts of this pipeline, and is the higher hourly
spot rate worth it?**

Generations in scope (ARM-only project — Graviton family only):

| Gen | Family example | Core | In CE today? |
|---|---|---|---|
| G2 | r6g | Neoverse-N1 | yes |
| G3 | r7g | Neoverse-V1 | yes |
| G4 | r8g | Neoverse-V2 | yes |
| G5 | m9g | Neoverse-V3 (latest) | **no — not yet evaluated**; see Phase 2 |

The pipeline has several stages that are wholly or partially single-
threaded, where Amdahl's law caps any benefit from more vCPUs:

| Stage | Single-threaded part(s) | Why it matters |
|---|---|---|
| `profile_taxa` | bowtie2-build (DB prep), MetaPhlAn post-processing | `conf/aws_batch.config` comments that the job is partially single-threaded — wallclock is gated by these phases |
| `FASTERQ_DUMP` | fasterq-dump itself — split phase before pigz | I18 added pigz parallelism for compression, but the fasterq-dump split is still single-threaded |
| `profile_function` | HUMAnN's `read_fastx.py` producer, MetaPhlAn pre-screen, pathway computation | Multiple single-threaded substages interspersed with parallel bowtie2 phases |
| `clean_reads` (fastp) | report writing post-merge | Tiny but non-zero |

Each Graviton generation has improved IPC on the Neoverse roadmap (V1
→ V2 → V3). If a newer generation's wallclock reduction on these
stages exceeds its spot price premium, it wins on $/task even though
it loses on $/hr — exactly the case where Batch's "cheapest spot"
picker would reach the wrong answer.

This issue exists to *measure* that delta rather than guess.

## Problem

The compute environment (`SpotComputeEnvironment`) accepts a list of
allowed instance types (Graviton G2/G3/G4 — `r6g`, `r7g`, `r8g`) and
lets Batch pick whichever is cheapest spot. We've never measured
whether the price difference is justified: is r7g spot actually
cheaper *per task completed* than r8g, or is r8g's faster per-core
performance enough to offset its higher hourly rate?

There's also no measurement of:

- **Per-stage fit**: profile_taxa is bowtie2-bound (memory-bandwidth
  + L2/L3 cache size matter); FASTERQ_DUMP is I/O-bound (NVMe + EBS
  throughput); profile_function is ChocoPhlAn-mmap (RAM size matters).
  The optimal generation could differ by stage.
- **Spot reclaim rate by generation**: G3 (r7g) and G4 (r8g) have
  different spot capacity pools, possibly different interruption rates.

Without data, we either (a) accept whatever Batch's "cheapest spot"
heuristic picks — which optimizes for $/hr not $/task — or (b) constrain
the CE to one type and lose the diversification benefit.

## Why this is worth tracking now

The post-FSR runs (starting 2026-04-29) have a clean baseline: workers
boot fast, page cache warmup is reproducible, no S3-sync confound. So
per-task wallclock differences between r7g and r8g should reflect
actual CPU/memory differences, not boot-phase noise.

Today's run alone produced a useful sample (3 workers, 2 generations,
same workload). Repeated across pilot (I09) and production (I10) runs,
this becomes a real dataset.

## What to measure

For each task that ran on each instance type in a run:

| Metric | Source |
|---|---|
| Wallclock per task | Nextflow trace.txt (`realtime` column) |
| CPU hours per task | trace.txt (`%cpu` × `realtime`) |
| Instance type that ran the task | `aws batch describe-jobs --jobs <id>` → `container.containerInstanceArn` → ECS describe → EC2 instance-type |
| Spot price at task time | `aws ec2 describe-spot-price-history --instance-types <T> --availability-zone <AZ>` |
| Per-task cost | wallclock × spot $/hr |
| Reclaim count by type | `aws batch describe-jobs` → `attempts[]`: any attempt with a terminated host instance counts as a reclaim. Note: with I19's `maxSpotAttempts=5` landed, reclaims no longer surface to `.nextflow.log` — Batch retries them transparently — so the source must be Batch's per-job attempt history, not the Nextflow log. |

## Approach

### Phase 1 — Retroactive analysis (no infra changes)

Write `bin/analyze_run_by_instance_type.py` that:

1. Reads `outdir/<project>/reports/<ts>_trace.txt`.
2. Joins each `process` row to its Batch job ID, then to the ECS task
   ARN, then to the EC2 instance-type, then to the spot price for that
   AZ at task start.
3. Emits a per-stage × per-instance-type table:
   ```
   stage              type           N    median_wall  $/task   $/sample
   profile_taxa       r8g.2xlarge    2    1280s        $0.064   $0.064
   profile_taxa       r7g.2xlarge    1    1410s        $0.058   $0.058
   profile_function   r8g.2xlarge    3    7200s        $0.36    $0.36
   ```
4. Optionally compares against the previous run's table to detect
   spot-price drift.

Acceptance for Phase 1: run the script against today's max005-resume
and the next pilot (I09) and have a real number for "is r7g cheaper
*per task* than r8g for profile_taxa, or not?"

### Phase 2 — Act on findings (depends on data)

Possible CE config changes (only if data justifies):

- Drop older generations (r7g/r6g) if a newer one is consistently
  cheaper-per-task (modern generations often have better $/perf
  despite higher $/hr).
- Drop a newer generation if older spot is meaningfully cheaper *and*
  reclaim rate on the older one isn't materially worse.
- Add r8g.4xlarge (or m9g.4xlarge once available) to the CE if
  I20-style memory-packing (2-4 tasks per worker) would amortize the
  extra cost.
- **Add G5 (`m9g.*`) to the CE** once it's available in `us-east-2`
  with non-trivial spot capacity. m9g uses Neoverse-V3 and should be
  the next-best candidate after r8g. Don't add it blind — first sample
  it in a small pilot, because:
    - Spot capacity is thin on brand-new generations (high reclaim risk).
    - `m9g.*` is "memory-balanced" not memory-optimized — for `profile_function`
      (60 GB working set) we'd want the equivalent r9g if/when it ships,
      not m9g (which tops out lower per vCPU).
- Per-stage CE pinning if generations behave differently across
  stages (overlaps with I22 — coordinate before splitting CEs).

## Files to create

| File | Change |
|---|---|
| `bin/analyze_run_by_instance_type.py` (new) | Phase 1 analysis tool |
| `infra/readme.md` | Document the analysis tool + how to interpret output |
| `infra/batch-stack.yaml` | Phase 2: when adding G5 (`m9g.*`) to the CE, update the allowed-instance-types list and bump the CE rev |

## Acceptance criteria

- [ ] Phase 1 script runs against an existing trace.txt and produces
      a stage × instance-type cost table.
- [ ] Documented finding (in this issue or `infra/readme.md`) of the
      form: "for `profile_taxa`, the cheapest-per-task generation is
      `<r8g|r7g|r6g>`, with per-task cost figures and rationale."
- [ ] Same finding for `profile_function` and `FASTERQ_DUMP`.
- [ ] At least 2 runs of data per instance-type per stage before any
      CE config change.
- [ ] G5 evaluation: once `m9g.*` is in CE allowed-types, capture at
      least one pilot run's data and add to the comparison.

## Out of scope

- ARM vs x86 comparison — the project is ARM-only (DBs are baked into
  ARM AMIs, container images are Graviton).
- Burstable types (`t4g.*`) — not used and not expected to fit
  long-running bowtie2/HUMAnN workloads.
- AWS Compute Optimizer — its recommendations are for steady-state
  long-running workloads; our jobs are short and bursty, so its
  signal is weak.
- Cost-Explorer cost-allocation report (24h lag) — useful sanity check
  but not the per-task granularity we need.

## Related

- **I22 — per-process AMIs / multi-queue.** Tightly coupled. I22
  proposes splitting the workflow across multiple queues with
  per-stage-tuned instance types; I25 produces the data that decides
  which type to assign to which queue. Don't land I22's CE split
  before I25's first analysis pass — otherwise the assignments are
  guesses, not measurements. Specifically, I22 calls out that
  FASTERQ_DUMP doesn't need 64 GB RAM; I25 should answer "what does
  it actually need, and which generation runs it cheapest per task?"
- I16 — max005 scaling baseline. I25 reuses I16's runs as data sources.
- I09 — pilot run produces the next dataset.
- I10 — production playbook should reference final CE config informed
  by I25 findings (and I22's queue layout, in that order).
- I24 — FSR enables clean measurement (no boot-phase noise).
- I18 — FASTERQ_DUMP threading. Note that I18's pigz autoscale doesn't
  make fasterq-dump itself parallel; the single-thread question still
  applies to that stage and is exactly what I25 is set up to measure.
