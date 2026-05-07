# I18 — FASTERQ_DUMP threading: bump `cpus` and/or pigz `-p`

## Status

Proposed — 2026-04-27. Small scope. Defer until I16 baseline numbers
are in hand so the change can be A/B'd against a measured baseline.

## Background

Observed during I16 max005 run on r6g.2xlarge worker (8 vCPU): a running
FASTERQ_DUMP container was using ~2 threads in fasterq-dump and ~2 threads
in pigz, total ~50% CPU utilization on the host (4 vCPUs idle).

Source: `modules/data_handling.nf:26-54`

```nextflow
process FASTERQ_DUMP {
    label 'process_medium'
    memory 4.GB
    cpus 2

    script:
    """
    fasterq-dump --threads $task.cpus --split-3 --mem 4G $sra_file
    pigz -p $task.cpus *.fastq
    """
}
```

Both fasterq-dump and pigz inherit `task.cpus = 2`.

## Why `cpus 2` is probably intentional (don't naively bump it)

Batch packs 4 jobs onto an 8-vCPU instance with `cpus 2`. With the I10
production run shape (~16,000 FASTERQ_DUMP jobs queued in bulk), this
dense packing minimizes instance-startup overhead and keeps total cost
down. Bumping to `cpus 8` would force one job per instance, multiplying
boot/idle overhead.

But for **smaller runs** (smoke, pilot, max005), the box is sparsely
packed already — so the unused vCPUs are visible waste with no
cost-vs-throughput tradeoff to defend.

## Two cheap experiments worth running

### A. Bump just pigz threads, keep `cpus 2`

```nextflow
fasterq-dump --threads $task.cpus ...
pigz -p ${task.cpus * 4} *.fastq    # or hardcode -p 8
```

Pigz oversubscribes the host briefly (compression is bursty and short),
fasterq-dump is unaffected. Risk: when 4 packed jobs align in their pigz
phase, brief CPU contention. Probably negligible.

Expected gain: 2-4× pigz speedup → small reduction in FASTERQ_DUMP
wallclock (compression is a fraction of total time, but on large SRAs
it's measurable).

### B. Bump `cpus` to 4 (or 8) for small-run profiles only

If we want fasterq-dump to also run faster (for runs where vCPUs are
otherwise idle), bump `cpus`. This implicitly bumps pigz too. Trade-off
flips at scale — measure before recommending for I10.

Could also be parameterized by a profile-level setting if we want
different values for `test`/`smoke` vs `aws`/`prod`.

## Measurement plan

This is the actually valuable part — don't change anything until we have
a baseline.

1. **Baseline (current behavior)**: capture FASTERQ_DUMP per-task duration
   from the I16 max005 trace. Look at
   `results_local_logs/<project>/reports/<ts>_trace.txt` columns
   `realtime` and `%cpu` for each `FASTERQ_DUMP` row.
2. **Try option A** (pigz only): same 5 samples, `pigz -p 8`, measure
   per-task duration delta. Ideally a clean re-run rather than `-resume`,
   so the cache doesn't skip the changed step.
3. **Try option B** (`cpus 8`): same 5 samples, measure per-task duration
   AND total instance-hours (pack ratio drops).
4. Pick the winner per workload size; document in `infra/readme.md` or
   a profile.

Keep results in `logs/I18-fasterq-threading-comparison.md` (or append
to this file).

## Files that would change (when picked up)

| File | Change |
|------|--------|
| `modules/data_handling.nf` | One-line: change `pigz -p $task.cpus` → `pigz -p N` (for option A) or `cpus 2` → `cpus 4/8` (for option B). |
| `logs/I18-...md` | Capture A/B/baseline numbers. |

## Acceptance criteria

- [ ] Baseline FASTERQ_DUMP per-sample duration captured from an
      unmodified run (I16 max005 is sufficient).
- [ ] At least one of A or B tried on the same 5-sample input; measured
      duration delta documented.
- [ ] Decision recorded: keep current, adopt A, adopt B, or
      profile-specific.

## Out of scope

- AWS_DOWNLOAD threading (separate process, separate concern).
- Other Batch-side packing tweaks (job-def `cpus` vs CE config).
- Switching compression algorithm (zstd, etc.) — bigger lift.
