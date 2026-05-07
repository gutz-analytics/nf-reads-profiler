# I06: Fix resource limits, HUMAnN memory, nreads cap, and cleanup flag for AWS Batch

**Priority:** CRITICAL — must land before any real production run
**Size:** Medium (eight targeted changes across four files)
**Dependencies:** I00 must land first (I00 fixes `containerOptions`; `profile_function` must submit successfully before these resource settings matter)

---

## Problems

### 1. `resourceLimits.time = 2.h` silently caps all processes at 2 hours

`conf/aws_batch.config` lines 54–58:

```groovy
resourceLimits = [
    cpus: 8,
    memory: 64.GB,
    time: 2.h
]
```

Nextflow's `resourceLimits` is a hard ceiling that overrides any per-process
`time` directive. HUMAnN routinely runs 4–6 hours on real samples against the
full uniref90 protein database. With the current cap every `profile_function`
job is killed by Batch after exactly 2 hours, producing a silent timeout rather
than a recognisable error.

Setting `time = '6h'` inside a `withName: 'profile_function'` block is
insufficient — `resourceLimits` clips it back to 2 h before the value reaches
the Batch API. The `resourceLimits.time` value must be raised to at least 6 h,
or removed from `resourceLimits` entirely so per-process directives are
respected without a global cap.

**Affected file/lines:** `conf/aws_batch.config` lines 54–58

### 2. `profile_function` memory too low for HUMAnN diamond search

`modules/community_characterisation.nf` line 69:

```groovy
memory 32.GB
```

HUMAnN4 loads the full uniref90 diamond database into memory during translated
search. The database requires approximately 60–64 GB of resident memory. With
only 32 GB allocated, the diamond step either OOM-kills the job or falls back
to a disk-paging mode that extends runtime far beyond 6 hours.

`resourceLimits.memory = 64.GB` already allows this value. The process
directive just needs to be raised to match what the task actually needs.

**Affected file/line:** `modules/community_characterisation.nf` line 69

### 3. `nreads` cap is 33 333 333 — should be 32 000 000

`nextflow.config` line 90:

```groovy
nreads = 33333333
```

The current value is 33.3 M reads. Lowering to 32 M provides additional safety
margin (cleaner power-of-two alignment with downstream memory estimates) and
reduces the tail of the runtime distribution for large samples.

**Affected file/line:** `nextflow.config` line 90

### 4. `maxRetries = 0` — confirm no auto-retry

`conf/aws_batch.config` line 51:

```groovy
maxRetries = 0
```

This is already correct. With identical failure modes (OOM, timeout) retrying
the same job wastes Spot budget without a different outcome. The setting is
documented here so it is not accidentally changed during refactoring.

**Affected file/line:** `conf/aws_batch.config` line 51 (no change needed; confirm during review)

### 5. `cleanup = true` deletes work files — blocks debugging and `-resume`

`conf/aws_batch.config` line 2:

```groovy
cleanup = true
```

When `cleanup = true` Nextflow purges the S3 work directory on pipeline
completion. This means:

- Failed intermediate files are deleted before they can be inspected.
- `-resume` has no cached work to reuse and re-runs everything from scratch.
- The I08 storage-measurement issue cannot record accurate peak S3 usage
  because files are removed before the measurement window closes.

Disabling cleanup during the debugging and pilot-run phase preserves work files
for post-mortem inspection and allows `-resume` to function as intended.

**Affected file/line:** `conf/aws_batch.config` line 2

### 6. No explicit time allocation for `profile_function`

Even after raising `resourceLimits.time`, the process uses the global default
`time = '1h'` (line 50 of `conf/aws_batch.config`). A `withName` block should
pin `profile_function` to `'6h'` so the allocation is self-documenting and
explicit. This also ensures the value survives any future change to the global
default.

**Affected file/line:** `conf/aws_batch.config` — add `withName: 'profile_function'` block

---

## Fixes

### `conf/aws_batch.config`

**Change 1 — disable cleanup (line 2)**

```groovy
// Before
cleanup = true

// After
cleanup = false  // Keep work files for debugging, -resume, and I08 storage measurement
```

**Change 2 — raise resourceLimits.time (lines 54–58)**

```groovy
// Before
resourceLimits = [
    cpus: 8,
    memory: 64.GB,
    time: 2.h
]

// After
resourceLimits = [
    cpus: 8,
    memory: 64.GB,
    time: 6.h
]
```

**Change 3 — add withName block for profile_function**

Add alongside the existing `withName: 'get_software_versions'` block:

```groovy
withName: 'profile_function' {
    time   = '6h'
    memory = '60 GB'
    cpus   = 4
}
```

Memory is 60 GB, not 64 GB — ECS agent + OS reserve ~512 MB on the 64 GiB
`r8g.2xlarge`, so requesting exactly 64 GB causes jobs to sit in RUNNABLE
forever (never placed). This overrides the global 1 h and 32 GB defaults.

### `modules/community_characterisation.nf`

**Change 4 — raise profile_function memory (line 69)**

```groovy
// Before
memory 32.GB

// After
memory 60.GB
```

### `main.nf`

**Change 6 — fix `output_exists` dead code AND filename mismatch (lines 68-75, 237-242)**

The `output_exists()` function has TWO bugs:

1. **Dead code:** `ch_filtered_reads` is created at line 237 but never consumed.
   Line 242 passes unfiltered `merged_reads` to `profile_function`.

2. **Filename mismatch:** The function checks for `_pathcoverage.tsv`,
   `_genefamilies.tsv`, and `_pathabundance.tsv` (lines 71-73), but
   `profile_function` outputs `_2_genefamilies.tsv`, `_3_reactions.tsv`, and
   `_4_pathabundance.tsv` (lines 80-82). There is no `pathcoverage` output —
   the process emits `reactions`.

```groovy
// Before (lines 68-75)
def output_exists(meta) {
  def run = meta.run
  def name = meta.id
  def pathcoverage_file = file("${params.outdir}/${params.project}/${run}/function/${name}_pathcoverage.tsv")
  def genefamilies_file = file("${params.outdir}/${params.project}/${run}/function/${name}_genefamilies.tsv")
  def pathabundance_file = file("${params.outdir}/${params.project}/${run}/function/${name}_pathabundance.tsv")
  return pathcoverage_file.exists() && genefamilies_file.exists() && pathabundance_file.exists()
}

// After — fix filenames to match actual HUMAnN output
def output_exists(meta) {
  def run = meta.run
  def name = meta.id
  def genefamilies_file = file("${params.outdir}/${params.project}/${run}/function/${name}_2_genefamilies.tsv")
  def reactions_file = file("${params.outdir}/${params.project}/${run}/function/${name}_3_reactions.tsv")
  def pathabundance_file = file("${params.outdir}/${params.project}/${run}/function/${name}_4_pathabundance.tsv")
  return genefamilies_file.exists() && reactions_file.exists() && pathabundance_file.exists()
}

// Before (line 242)
profile_function(merged_reads)

// After — use the filtered channel
profile_function(ch_filtered_reads)
```

### `nextflow.config`

**Change 5 — lower nreads cap (line 90)**

```groovy
// Before
nreads = 33333333

// After
nreads = 32000000
```

---

## Files to change

```
conf/aws_batch.config
  line   2  – cleanup = true  →  cleanup = false
  line  57  – time: 2.h  →  time: 6.h  (inside resourceLimits)
  (new)     – add withName: 'profile_function' block with time/memory/cpus

modules/community_characterisation.nf
  line  69  – memory 32.GB  →  memory 60.GB  (process profile_function)

main.nf
  lines 68-75  – fix output_exists() filenames to match actual HUMAnN outputs
  line  242    – profile_function(merged_reads)  →  profile_function(ch_filtered_reads)

nextflow.config
  line  90  – nreads = 33333333  →  nreads = 32000000
```

No changes to `maxRetries` — value of `0` at line 51 of `conf/aws_batch.config`
is already correct.

---

## Verification

1. Submit a pilot run with a small samplesheet (2–4 real samples, not test
   stubs) against the full `/mnt/dbs` databases:

   ```bash
   nextflow run main.nf -profile aws \
     --input s3://gutz-nf-reads-profilers-runs/samplesheets/<pilot>.csv \
     --project pilot-I06 -resume
   ```

2. In the AWS Batch console, confirm `profile_function` jobs reach `RUNNING`
   state and are allocated 64 GB memory containers (visible in job definition
   details).

3. Monitor job duration. Jobs should complete within 6 h. Jobs previously
   timing out at exactly 2 h will now either complete or fail for a different
   (diagnosable) reason.

4. After the run completes, inspect the Nextflow trace file at
   `outdir/pilot-I06/reports/*_trace.txt`. Confirm:
   - `peak_rss` for `profile_function` rows is below 64 GB.
   - `realtime` for `profile_function` rows is below 6 h.

5. Confirm the S3 work directory (`s3://gutz-nf-reads-profilers-workdir/`)
   retains intermediate files after pipeline completion (cleanup is disabled).
   This validates that `-resume` will work on a subsequent run and that I08
   storage measurement will see the full working set.

---

## Background

The `resourceLimits` block is a Nextflow feature introduced to prevent retry
storms from escalating memory or CPU unboundedly. The `time` field was added
as a precaution but was set conservatively (2 h) without accounting for
HUMAnN's protein-search phase. Because `resourceLimits` acts as a ceiling
rather than a default, it silently discards any per-process `time` value above
the cap. The failure mode is a job killed by AWS Batch when the wallclock
limit is reached — the Batch console shows `FAILED` with reason
`Host EC2 terminated` or a similar wallclock exit, which is easy to misread as
an infrastructure problem rather than a config issue.

The 32 GB memory setting on `profile_function` was inherited from an earlier
workflow configuration designed for MetaPhlAn-only runs. HUMAnN's diamond
translated-search phase loads the full protein database into memory; 32 GB is
insufficient for the `uniref90_annotated_v4_alpha_ec_filtered` database used
in production. The `resourceLimits.memory = 64.GB` ceiling already exists
specifically to accommodate this requirement; only the process-level directive
needs updating.
