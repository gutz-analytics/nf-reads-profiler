# I11: Add human read removal step (host decontamination)

**Priority:** high — affects accuracy of all downstream profiling
**Size:** medium (new process + new DB parameter + pipeline wiring)
**Dependencies:** I00 (containerOptions fix); independent of I01-I10

---

## Goal

Add a host-read removal step between `clean_reads` (fastp) and
`profile_taxa` / `profile_function` / MEDI to filter human-origin reads
before metagenomic profiling. Human contamination inflates UNMAPPED
fractions, wastes compute on non-microbial reads, and can bias abundance
estimates.

## Pipeline position

```
clean_reads (fastp, nreads=32M cap)
    → [NEW] remove_human_reads (Bowtie2 or similar)
        ├── profile_taxa (MetaPhlAn)
        ├── profile_function (HUMAnN)
        └── MEDI_QUANT (when enabled)
```

Currently `merged_reads = clean_reads.out.reads_cleaned` feeds directly into
`profile_taxa` and `profile_function` at `main.nf:231-242`. The new process
inserts between these, and its output replaces `merged_reads` as input to
all downstream processes.

## Tool options

| Tool | Approach | Pros | Cons |
|------|----------|------|------|
| **Bowtie2** against CHM13/hg38 | Align reads, keep unmapped | Simple, well-understood, fast | Needs ~16 GB index on disk |
| **KneadData** (wraps Bowtie2 + Trimmomatic) | All-in-one QC + decontam | Common in HUMAnN workflows | Redundant with fastp already running; heavier container |
| **Minimap2** against CHM13 | Align reads, keep unmapped | Faster than Bowtie2, lower memory | Less standard for short reads |
| **hostile** | Purpose-built host removal | Fast, minimal config | Newer tool, less community validation |

**Recommendation:** Bowtie2 against CHM13v2 (T2T human genome). This is the
standard approach used by HUMAnN's own documentation and most metagenomics
pipelines. CHM13 is preferred over hg38 because it has no unplaced contigs
or ALT loci, giving cleaner alignments.

## Implementation sketch

### New process in `modules/house_keeping.nf`

```groovy
process remove_human_reads {
  tag "${meta.id}"
  label 'process_medium'
  container params.docker_container_bowtie2  // or a container that includes bowtie2

  input:
  tuple val(meta), path(reads)

  output:
  tuple val(meta), path("*_decontam.fq.gz"), emit: reads_decontam
  tuple val(meta), path("*_human_reads_log.txt"), emit: decontam_log

  script:
  name = task.ext.name ?: "${meta.id}"
  """
  bowtie2 -x ${params.human_ref_db} \
    -1 ${reads[0]} -2 ${reads[1]} \
    --very-sensitive \
    --threads ${task.cpus} \
    --un-conc-gz ${name}_decontam.fq.gz \
    -S /dev/null \
    2> ${name}_human_reads_log.txt
  """
  // For single-end: use -U and --un-gz instead
}
```

### New parameters in `nextflow.config`

```groovy
params {
    skip_host_removal = false
    human_ref_db = "/mnt/dbs/human_genome/CHM13v2"  // Bowtie2 index prefix
}
```

### New DB in S3

The CHM13v2 Bowtie2 index (~16 GB) needs to be:
1. Built and uploaded to `s3://cjb-gutz-s3-demo/human_genome/`
2. Synced to workers via the existing UserData `aws s3 sync` (already
   included since it syncs everything except `referencedata/*`)
3. Referenced in `aws_batch.config` as a path parameter override

### Wiring in `main.nf`

```groovy
// After clean_reads, before profile_taxa/profile_function:
if (!params.skip_host_removal) {
    remove_human_reads(clean_reads.out.reads_cleaned)
    decontam_reads = remove_human_reads.out.reads_decontam
} else {
    decontam_reads = clean_reads.out.reads_cleaned
}

profile_taxa(decontam_reads)
// ... and profile_function, MEDI, etc.
```

## Resource requirements

- **CPU:** 4 (same as other processes)
- **Memory:** 16–20 GB (Bowtie2 loads index into memory; CHM13 index ~8 GB
  resident + reads)
- **Time:** ~10–20 min per sample for paired-end at 32M reads
- **Disk:** ~16 GB for the Bowtie2 index on `/mnt/dbs/`

## Container

Need a Docker image with `bowtie2` and `samtools` that publishes ARM64
manifests (Graviton workers). Options:
- `biocontainers/bowtie2` (check ARM64 availability)
- Build a custom multi-arch image
- Use an existing pipeline container that includes bowtie2

## Files to change

| File | Change |
|------|--------|
| `modules/house_keeping.nf` | Add `remove_human_reads` process |
| `main.nf` | Wire new process between `clean_reads` and `profile_taxa`/`profile_function` |
| `nextflow.config` | Add `skip_host_removal` and `human_ref_db` params |
| `conf/aws_batch.config` | Add `human_ref_db` path override for `/mnt/dbs/` |
| `conf/test.config` | Add `human_ref_db` path for local testing (or `skip_host_removal = true`) |

## Verification

1. Run a small sample with and without `--skip_host_removal`
2. Compare read counts: decontaminated output should have fewer reads
3. Check that `profile_taxa` output no longer shows `Homo_sapiens` as a
   significant fraction (if it did before)
4. Verify decontam log shows number of human reads removed
5. Confirm no regression in MetaPhlAn/HUMAnN feature counts (should be
   similar or slightly different, not dramatically fewer)

## Notes

- The `skip_host_removal` flag allows bypassing for samples known to be
  host-free (e.g. environmental metagenomes, food samples).
- MultiQC should pick up the decontam log if formatted correctly; consider
  adding a custom content section.
- This step adds ~15 min per sample to wall time. At 16K samples with
  MaxvCPUsSpot=16, this is negligible compared to HUMAnN's 4-6h.
- The human genome DB is small (~16 GB) and will be included in the existing
  `aws s3 sync` without significant overhead.
