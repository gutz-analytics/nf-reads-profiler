# Cost Optimization Guide

## Overview

This document describes the cost optimization changes applied to nf-reads-profiler
and how to validate them. These optimizations target both Azure Batch and AWS Batch
deployments.

## Validating Changes Without Nextflow

Run the config validation test suite:

```bash
python tests/scripts/test_config_validation.py
```

This runs 54 automated checks across all config files and process definitions,
covering every optimization described below.

### Manual Verification Checklist

After running a production batch, analyze the trace file:

```bash
# The pipeline now generates trace.txt automatically
# Location: <outdir>/<project>/execution_reports/trace.txt

# Quick cost analysis: find over-provisioned processes
awk -F'\t' 'NR>1 && $8!=""{
  split($8,cpu,"%"); split($11,mem,"%");
  if(cpu[1]<20) print "LOW CPU:", $2, $3, cpu[1]"%";
  if(mem[1]<20) print "LOW MEM:", $2, $3, mem[1]"%"
}' trace.txt

# Find processes that used much less memory than allocated
# peak_rss vs memory columns show actual vs allocated
```

## Optimization Summary

### P0 — Critical Fixes

#### 1. HUMAnN Skip-If-Exists (Issue #5)

**Problem**: `output_exists()` function was defined but never used. Re-running the
pipeline reprocessed every sample through HUMAnN (36-48h on-demand).

**Fix**: `profile_function` now receives `ch_filtered_reads` (which filters out
samples with existing output) instead of `merged_reads`. Also updated
`output_exists()` to check HUMAnN4 file naming convention (`_2_genefamilies.tsv`
instead of the old `_genefamilies.tsv`).

**Estimated savings**: $24/sample on reruns. For a 50-sample study where 45 are
already complete: ~$1,080.

**Verify**: `grep 'profile_function(ch_filtered_reads)' main.nf`

#### 2. Trace File (Issue #7)

**Problem**: No trace output — impossible to measure actual CPU/memory utilization.

**Fix**: Added `trace` block to `nextflow.config` with fields: task_id, name, tag,
status, exit, submit, start, complete, duration, realtime, cpus, %cpu, memory,
peak_rss, peak_vmem, rchar, wchar, queue.

**What this replaces**: This is the free equivalent of Seqera Platform's cost
dashboards. The trace file is a TSV that shows exactly what each process actually
used vs what was allocated.

### P1 — High Impact

#### 3. resourceLimits (Issue #8)

**Problem**: `memory = { 64.GB * task.attempt }` with `maxRetries = 3` could request
192+ GB with no cap.

**Fix**: Added `resourceLimits = [cpus: 64, memory: 512.GB, time: 48.h]` (Azure)
and `resourceLimits = [cpus: 32, memory: 256.GB, time: 48.h]` (AWS) to both
profiles. This is a modern Nextflow feature that replaces the nf-core `check_max()`
pattern.

#### 4. Azure Pool Caps (Issue #13)

**Problem**: Most Azure pools had `maxVmCount = 500`. At ~$0.48/hr per E4 VM,
500 VMs = $240/hr with no budget protection.

**Fix**: Reduced caps to 100 for general pools, 50 for specialized pools. The
kraken_ramdisk pool remains at 2 (dedicated high-memory nodes).

### P2 — Medium Impact

#### 5. copyToolInstallMode (Issue #3)

**Problem**: `'task'` mode reinstalled azcopy for every single task execution.

**Fix**: Changed to `'node'` — installs azcopy once per compute node.

#### 6. Azure Right-Sizing (Issues #1, #2)

**Problem**: `count_reads` (runs `zcat | wc -l`) inherited default 4 CPU / 32 GB.
`convert_tables_to_biom` and `combine_humann_taxonomy_tables` similarly
over-provisioned.

**Fix**: Added explicit `withName` overrides:
- `count_reads`: 2 CPU / 8 GB / 30min
- `convert_tables_to_biom`: 2 CPU / 16 GB
- `combine_humann_taxonomy_tables`: 2 CPU / 16 GB
- `get_software_versions`: 1 CPU / 2 GB / 15min

#### 7. Paired-End Storage (Issue #6)

**Problem**: `clean_reads` created R1, R2, and concatenated file — all three
coexisted in the work directory (3x storage per sample).

**Fix**: Added `rm -f out.R1.fq.gz out.R2.fq.gz` after concatenation.

### P3 — Lower Impact

#### 8. Kraken CPU (Issue #9)

**Problem**: Kraken2 allocated 64 CPUs on Azure despite being memory-I/O bound.

**Fix**: Reduced to 16 CPUs (Azure). AWS was already correct at 32.

#### 9. Orphaned Labels (Issue #4)

**Problem**: `AWS_DOWNLOAD` had label `process_low` and `FASTERQ_DUMP` had label
`process_medium` — neither matched any `withLabel` config block.

**Fix**: Changed `AWS_DOWNLOAD` to `label 'low'` (matches existing config).
Removed orphaned `process_medium` label from `FASTERQ_DUMP` (has explicit
`withName` overrides).

#### 10. publishDir Modes (Issue #10)

**Problem**: 6 MEDI processes had `publishDir` without explicit `mode:`. Default
is `symlink` which doesn't work with cloud storage.

**Fix**: Added `mode: 'copy'` to all MEDI publishDir directives.

#### 11. Double fastp (Issue #11)

**Problem**: When MEDI enabled, raw reads went through MEDI's `preprocess` (fastp)
even though `clean_reads` already ran fastp on the same data.

**Fix**: MEDI now receives pre-cleaned reads from `clean_reads.out.reads_cleaned`.
Added `precleaned` parameter to `MEDI_QUANT` workflow that skips `preprocess` when
true.

## Ramdisk Strategy

Ramdisks are already used for Kraken2 on Azure (via `startTask` on the
`kraken_ramdisk` pool). This is the correct approach for Kraken2 because:

1. Kraken2 loads the entire database into memory for classification
2. The database is ~30-50 GB and must be loaded for every sample
3. With a ramdisk, the database is loaded once per node and shared across tasks
4. Without it, each task would read from Azure File Shares (network I/O)

### Where Ramdisks Help

| Process | I/O Pattern | Ramdisk Benefit |
|---------|------------|-----------------|
| Kraken2 | Loads full DB into memory, streams reads | **HIGH** — already implemented |
| MetaPhlAn | Loads bowtie2 index, sequential search | **MODERATE** — DB on file share is fine |
| HUMAnN | Diamond + bowtie2 against large DBs | **LOW** — bottleneck is compute, not I/O |
| fastp | Streaming read processing | **NONE** — sequential I/O, no random access |

### When NOT to Use Ramdisks

- HUMAnN: The 36h runtime is dominated by Diamond protein alignment (CPU-bound),
  not database loading. Ramdisk would speed up the initial ~5min DB load but not
  the remaining 35h 55min.
- MetaPhlAn: Database is accessed via Azure File Share mount which provides
  adequate throughput for sequential bowtie2 alignment.
- Any process with small input files: The overhead of ramdisk setup exceeds
  the I/O savings.

### For AWS: Instance Store as Free Ramdisk

On AWS, NVMe instance stores (available on `d`-class instances like r6id, m6id)
provide local SSD that functions similarly to a ramdisk but persists across tasks
on the same node. This is free (included in instance price) and faster than EBS.

To use it, configure a launch template in your Batch compute environment that
mounts the instance store to `/tmp/local-ssd` and stage databases there via
a custom AMI or user-data script.

## S3 Work Directory Cleanup

Nextflow's `cleanup = true` does **not** work with S3 work directories. You must
configure an S3 lifecycle policy on your work bucket:

```json
{
  "Rules": [{
    "ID": "cleanup-nextflow-work",
    "Status": "Enabled",
    "Filter": { "Prefix": "work/" },
    "Expiration": { "Days": 14 },
    "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 3 }
  }]
}
```

Apply with:
```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket YOUR-WORK-BUCKET \
  --lifecycle-configuration file://lifecycle.json
```

## Cost Reduction Levers

### `--humann_spot` — Run HUMAnN on Spot Instances

```bash
nextflow run main.nf -profile aws --humann_spot true
```

Default: `false` (on-demand queue for guaranteed completion).

When enabled, HUMAnN runs on the spot queue. At 6hr average runtime, spot eviction
risk is ~5-8%. The smart errorStrategy retries evicted jobs automatically (up to 3
attempts). Even with 15% reprocessing overhead, spot saves 60-65% on HUMAnN compute.

**Cost impact at 20K samples**:
- On-demand: 20K × $2.28 = $45,600
- Spot with retries: 20K × $0.66 × 1.10 = $14,520
- **Savings: $31,080**

### `--bypass_translated_search` — Skip Diamond Protein Alignment

```bash
nextflow run main.nf -profile aws --bypass_translated_search true
```

Default: `false` (full nucleotide + translated search).

Skips HUMAnN's Diamond protein alignment against UniRef. This reduces runtime from
~6hr to ~2hr but misses novel genes not in ChocoPhlAn. Use when:
- Speed matters more than novel gene discovery
- Samples are from well-characterized environments (human gut)
- Running a preliminary/screening analysis

**Cost impact at 20K samples**:
- Full search (6hr): 20K × $2.28 on-demand / $0.66 spot
- Bypass (2hr): 20K × $0.76 on-demand / $0.22 spot
- **Savings: $8,800-$30,400** depending on spot choice

### Combined: Spot + Bypass

```bash
nextflow run main.nf -profile aws --humann_spot true --bypass_translated_search true
```

This is the most aggressive cost configuration:
- HUMAnN: ~2hr on spot = $0.22/sample
- Total pipeline: ~$1.20/sample (well under $3 budget)

### Duplicate MetaPhlAn (Potential Future Optimization)

Currently, MetaPhlAn runs twice per sample:
1. `profile_taxa` — standalone MetaPhlAn (index: `mpa_vJan25`, 20min)
2. `profile_function` — HUMAnN's internal MetaPhlAn (index: `mpa_vOct22`, 20min)

These use **different database versions** intentionally (HUMAnN4 requires its
compatible MetaPhlAn DB). If you align the database versions, HUMAnN can accept
a pre-computed profile via `--taxonomic-profile`, saving 20min/sample (6,667
CPU-hours at 20K samples). This requires scientific validation that the newer
MetaPhlAn DB produces compatible results with HUMAnN4.

## Seqera vs Built-in Nextflow Monitoring

| Feature | Nextflow (free) | Seqera Platform |
|---------|----------------|-----------------|
| Per-process CPU/memory usage | trace.txt | Dashboard |
| Execution timeline | timeline.html | Interactive timeline |
| Resource utilization charts | report.html | Real-time charts |
| Cost estimation | Parse trace.txt yourself | Automatic |
| Multi-run comparison | Manual | Built-in |
| Team access control | N/A | Yes |
| Pipeline marketplace | N/A | Yes |

**Recommendation**: For a single pipeline team, the built-in Nextflow reports plus
these optimizations will save more money than Seqera costs. Consider Seqera when
you have >50 runs/month, multiple teams, or need audit trails.
