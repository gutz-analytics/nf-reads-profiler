# I12: Run combine/reduce steps locally on the head node

**Priority:** medium — cost optimization and simplification
**Size:** medium (executor overrides on 5+ processes)
**Dependencies:** I00 (containerOptions fix); benefits from I06 (cleanup/resume)

---

## Problem

The pipeline follows a map-reduce pattern: per-sample "map" steps
(`profile_taxa`, `profile_function`) are compute-heavy and belong on Batch
workers, but the "reduce" steps that combine per-sample outputs into
per-study tables are lightweight. Currently, all reduce steps submit to
AWS Batch, which means:

1. **Unnecessary overhead:** Each reduce job spins up or reuses a Batch
   worker, syncs ~65 GB of databases to `/mnt/dbs/`, and runs a process
   that typically takes seconds to minutes and uses minimal CPU/memory.
2. **Straggler blocking is worse on Batch:** `groupTuple` waits for all
   samples in a study group. If a reduce job is queued behind map jobs
   in the Batch queue, it adds scheduling latency on top of the wait.
3. **Container image pulls:** Each reduce job pulls a container image
   on a Batch worker. At 16K scale, these small jobs multiply image
   pull pressure on DockerHub.
4. **Cost:** Reduce jobs are billed at the same instance rate as map jobs
   but use a fraction of the resources.

The head node already has Docker enabled and the containers available.
Running reduce steps locally eliminates Batch overhead entirely.

## Which processes are reduce steps

| Process | Module | What it does | Resource needs |
|---------|--------|-------------|----------------|
| `combine_humann_tables` | `community_characterisation.nf:113` | `humann_join_tables` on per-study TSVs | Minimal CPU/memory, seconds |
| `combine_metaphlan_tables` | `community_characterisation.nf:159` | Python biom merge of per-study `.biom` files | Minimal CPU/memory, seconds |
| `combine_humann_taxonomy_tables` | `community_characterisation.nf:202` | `merge_metaphlan_tables.py` on HUMAnN taxonomy TSVs | Minimal CPU/memory, seconds |
| `split_stratified_tables` | `community_characterisation.nf` | `humann_split_stratified_table` | Minimal, seconds |
| `get_software_versions` | `house_keeping.nf` | Collects version strings | Trivial |
| `MULTIQC` | `house_keeping.nf` | Aggregates QC logs into HTML report | Low CPU, moderate memory for large runs |

All of these run after `groupTuple` collects per-sample outputs, so they
execute once per study group (not once per sample). At 16K samples across
a handful of study groups, there are only a few reduce invocations total.

**Not reduce steps** (keep on Batch): `profile_taxa`, `profile_function`,
`clean_reads`, `count_reads`, `AWS_DOWNLOAD`, `FASTERQ_DUMP`, and all
MEDI processes.

## Implementation

### Option A: `withName` executor override in `aws_batch.config` (recommended)

Add `executor = 'local'` to each reduce process in the AWS Batch config:

```groovy
withName: 'combine_humann_tables' {
    executor = 'local'
    memory   = '4 GB'
    cpus     = 1
}
withName: 'combine_metaphlan_tables' {
    executor = 'local'
    memory   = '4 GB'
    cpus     = 1
}
withName: 'combine_humann_taxonomy_tables' {
    executor = 'local'
    memory   = '4 GB'
    cpus     = 1
}
withName: 'split_stratified_tables' {
    executor = 'local'
    memory   = '4 GB'
    cpus     = 1
}
withName: 'get_software_versions' {
    executor = 'local'
    memory   = '1 GB'
    cpus     = 1
}
withName: 'MULTIQC' {
    executor = 'local'
    memory   = '8 GB'
    cpus     = 2
}
```

This keeps the process definitions unchanged — only the config profile
decides where they run. Local Docker and Azure profiles are unaffected.

### Option B: Labels

Add a `label 'process_reduce'` to each reduce process, then configure
the label in the AWS config:

```groovy
withLabel: 'process_reduce' {
    executor = 'local'
    memory   = '4 GB'
    cpus     = 1
}
```

Cleaner but requires touching module files (adding labels).

**Recommendation:** Option A for now (config-only, no module changes).
Refactor to labels later if the pattern grows.

## Considerations

### containerOptions on local executor

`combine_humann_tables` uses `containerOptions '-u $(id -u):$(id -g)'`.
When `executor = 'local'`, Docker runs locally on the head node and
`$(id -u)` evaluates correctly in the local shell (no Batch regex issue).
The I00 escaping fix is still needed for any processes that remain on Batch,
but local-executor processes can use either escaped or unescaped form.

### Data locality

Reduce steps consume S3-staged outputs from map steps. With `executor = 'local'`,
Nextflow stages these files from S3 to the head node's local disk before
running the process. For `combine_humann_tables` at 16K samples, this means
downloading all per-sample TSVs for a study group to the head node. TSVs
are small (KB each), so even 16K files is manageable.

### Head-node disk and memory

The head node needs enough disk for staged reduce inputs and enough memory
for the reduce processes. At 16K samples:
- TSV staging: ~16K files x ~10 KB = ~160 MB per study group per table type
- MultiQC: aggregates all QC logs, may need several GB for 16K samples
- Memory: 4–8 GB is sufficient for all reduce steps

The head node (`r8g.2xlarge`, 64 GiB) has ample resources for this.

### `/mnt/dbs` not needed

Reduce steps don't access reference databases. They only process pipeline
outputs (TSVs, biom files, logs). No `/mnt/dbs` bind mount is needed,
and the `aws.batch.volumes` config is irrelevant for local-executor processes.

## Files to change

| File | Change |
|------|--------|
| `conf/aws_batch.config` | Add `withName` blocks with `executor = 'local'` for 6 reduce processes |

No changes to module files or `main.nf` (Option A).

## Verification

1. Run a 2–4 sample test with `-profile aws` and the new `withName` blocks
2. Confirm reduce processes show `executor: local` in the Nextflow log
   (not `awsbatch`)
3. Confirm reduce outputs (combined TSVs, biom files, MultiQC report) are
   identical to a baseline run without the change
4. Check that map processes (`profile_taxa`, `profile_function`) still
   submit to Batch
5. At pilot scale (100 samples), verify head-node disk and memory are
   sufficient for staging and reduce execution
