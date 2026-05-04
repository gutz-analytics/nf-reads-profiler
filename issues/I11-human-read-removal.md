# I11: Add human read removal step (host decontamination)

**Priority:** high — affects accuracy of all downstream profiling
**Size:** medium (new process + pipeline wiring; no external DB required)
**Dependencies:** I00 (containerOptions fix); independent of I01-I10
**Decision:** use `sra-human-scrubber` (NCBI k-mer scrubber) — see tool options below

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
| **sra-human-scrubber** (NCBI) | k-mer lookup against NCBI human k-mer DB | No genome index needed, NCBI-maintained, purpose-built, fast | ARM64 Docker image needs verification |
| **Bowtie2** against CHM13/hg38 | Align reads, keep unmapped | Simple, well-understood | Needs ~16 GB index on disk |
| **KneadData** (wraps Bowtie2 + Trimmomatic) | All-in-one QC + decontam | Common in HUMAnN workflows | Redundant with fastp already running; heavier container |
| **Minimap2** against CHM13 | Align reads, keep unmapped | Faster than Bowtie2, lower memory | Less standard for short reads |
| **hostile** | Python wrapper around minimap2; downloads human index on first run | Pure-Python `noarch` + minimap2 has native ARM64 builds → works on Graviton; active development | Newer tool, less community validation; requires index download |

**Decision: `sra-human-scrubber`** — NCBI's k-mer-based scrubber
([`ncbi/sra-human-scrubber`](https://github.com/ncbi/sra-human-scrubber)).
No large genome index required (k-mer DB is bundled in the container).
Eliminates the 16 GB DB staging problem and the S3-sync overhead. NCBI
maintains and validates the human k-mer set. Docker image:
`docker.io/ncbi/sra-human-scrubber`.

**ARM64 / Graviton blocker:** the core `aligns_to` binary in sra-human-scrubber
is compiled for x86_64 only. The bioconda package is `noarch` but bundles this
same x86 binary — the `linux/arm64` Docker image will build successfully but
fail at runtime on Graviton. Running this step would require a separate x86 CE/queue.
`hostile` (pure Python + minimap2) is the Graviton-compatible alternative.

## Implementation sketch

### New process in `modules/house_keeping.nf`

```groovy
process remove_human_reads {
  tag "${meta.id}"
  label 'process_medium'
  container params.docker_container_sra_human_scrubber  // custom miniforge3-based image

  input:
  tuple val(meta), path(reads)

  output:
  tuple val(meta), path("*_scrubbed*.fastq.gz"), emit: reads_decontam
  tuple val(meta), path("*_scrub_report.txt"),   emit: decontam_log

  script:
  name = task.ext.name ?: "${meta.id}"
  if (meta.single_end) {
    """
    scrub.sh -i ${reads[0]} -o ${name}_scrubbed.fastq.gz \
      2> ${name}_scrub_report.txt
    """
  } else {
    """
    scrub.sh -p ${reads[0]} ${reads[1]} \
      -o ${name}_scrubbed_R1.fastq.gz -O ${name}_scrubbed_R2.fastq.gz \
      2> ${name}_scrub_report.txt
    """
  }
}
```

> **Note:** confirm `scrub.sh` paired-end flags from the container's docs;
> the exact flag names may differ between releases.

### New parameters in `nextflow.config`

```groovy
params {
    skip_host_removal = false
    // No human_ref_db needed — k-mer DB is bundled in the container
}
```

### No new DB required

Unlike Bowtie2, sra-human-scrubber bundles its k-mer database inside the
container image. No S3 upload, no launch-template sync change, no
`/mnt/dbs/` path needed.

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

- **CPU:** 4
- **Memory:** ~4–8 GB (k-mer DB loaded in memory; much lighter than Bowtie2)
- **Time:** ~5–10 min per sample for paired-end at 32M reads
- **Disk:** none beyond the container layer

## Container

Custom multi-arch image built from `docker/sra-human-scrubber/Dockerfile`.
Uses `condaforge/miniforge3` + `mamba install bioconda::sra-human-scrubber=2.2.1`.

The bioconda package is `noarch` only — no pre-built ARM64 binary exists —
so we build our own. `miniforge3` supports `linux/arm64` natively, which
covers our Graviton workers.

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
- **sra-human-scrubber ARM64 path:** `aligns_to` source is in
  `ncbi/ngs-tools` at `tools/tax/src/aligns_to.cpp`. If we want to run
  sra-human-scrubber on Graviton, we could compile it from source in the
  Dockerfile rather than using the pre-built x86 binary. Confirmed via smoke
  test that the bioconda image fails at runtime on ARM64 with
  `Exec format error`.
