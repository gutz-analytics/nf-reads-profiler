# I13: Feed HUMAnN unmapped reads into MEDI to reduce compute burden

**Priority:** medium — optimization for when MEDI is re-enabled
**Size:** medium (new output channel + pipeline rewiring)
**Dependencies:** MEDI re-enablement; benefits from I12 (local reduce steps)

---

## Problem

Currently, `MEDI_QUANT` in `main.nf` receives the same full read set as
`profile_taxa` and `profile_function` — up to 32M reads per sample through
Kraken2. This is wasteful because:

1. HUMAnN already classifies the majority of reads against ChocoPhlAn
   (nucleotide) and UniRef90 (protein). Reads that map to known microbial
   genes are already accounted for.
2. Kraken2 on 32M reads requires significant memory (~512 GB in the Azure
   config's `kraken` label) and wall time.
3. If MEDI runs locally on the head node, 32M reads through Kraken2 is
   infeasible — the head node doesn't have 512 GB RAM.

## Proposal

Pipe HUMAnN's **fully-unaligned reads** (reads that didn't map during either
nucleotide or translated search) into MEDI instead of the full read set. These
represent the fraction of the metagenome that couldn't be assigned to any known
microbial gene, which is exactly the fraction most likely to contain
food-origin sequences.

When `skipHumann = true`, fall back to the full read set so MEDI can still run
independently.

## Pipeline position (current vs proposed)

```
Current:
  clean_reads ──┬── profile_taxa
                ├── profile_function
                └── MEDI_QUANT (full 32M reads)

Proposed:
  clean_reads ──┬── profile_taxa
                └── profile_function
                      └── fully-unaligned reads ── MEDI_QUANT (much smaller read set)

Fallback (skipHumann = true):
  clean_reads ──┬── profile_taxa
                └── MEDI_QUANT (full read set, same as today)
```

## Implementation sketch

### 1. Capture fully-unaligned reads from `profile_function`

HUMAnN generates intermediate files including fully-unaligned reads after both
nucleotide and translated search phases. Add a new output channel to
`profile_function` in `modules/community_characterisation.nf`:

```groovy
output:
// ... existing outputs ...
tuple val(meta), path("*_unaligned.fa"), emit: unmapped_reads, optional: true
```

**TO VERIFY:** Does HUMAnN retain fully-unaligned reads by default, or does it
require `--remove-temp-output false`? Check HUMAnN4 documentation and test
with a sample run. If temp outputs are removed by default, either:
- Add `--remove-temp-output false` to the HUMAnN command, or
- Add a copy/move step before HUMAnN cleanup

The exact filename pattern for the fully-unaligned output also needs
verification — run a sample with temp outputs retained and check what files
remain after both search phases.

### 2. Wire into MEDI in `main.nf`

```groovy
if (params.enable_medi) {
    if (!params.skipHumann) {
        MEDI_QUANT(profile_function.out.unmapped_reads)
    } else {
        MEDI_QUANT(merged_reads)
    }
}
```

### 3. Adjust MEDI resource requirements

With a much smaller input (likely 5-20% of original reads depending on sample
diversity), MEDI's Kraken2 step needs far less memory and time. This may make
`executor = 'local'` feasible for MEDI on the head node.

## Trade-offs

| Pro | Con |
|-----|-----|
| Dramatically smaller input to Kraken2 | MEDI now depends on `profile_function` completing first (serial, not parallel) |
| Makes local-executor MEDI feasible on head node | If `skipHumann = true`, falls back to full read set (no savings) |
| Focuses on the "unknown" fraction — biologically more relevant for food detection | HUMAnN's unaligned fraction may exclude some food-origin reads that partially match microbial genes |
| Reduces Kraken2 DB memory pressure | Need to verify HUMAnN retains unaligned reads (may need config flag) |

## Files to change

| File | Change |
|------|--------|
| `modules/community_characterisation.nf` | Add `unmapped_reads` output channel to `profile_function`; possibly add `--remove-temp-output false` |
| `main.nf` | Rewire MEDI input: use `profile_function.out.unmapped_reads` when HUMAnN runs, fall back to `merged_reads` when `skipHumann = true` |
| `subworkflows/quant.nf` | Possibly adjust input expectations (unaligned reads may be single-end FASTA, not paired FASTQ) |

## Verification

1. Run a sample with `--remove-temp-output false` (if needed) and confirm
   the fully-unaligned read file is produced and non-empty
2. Compare MEDI results from full reads vs unmapped reads — food detections
   should be similar or identical (food reads shouldn't map to microbial DBs)
3. Measure Kraken2 memory and time with the reduced input — confirm it fits
   within head-node resources if running locally
4. Test the `skipHumann = true` fallback path — MEDI should run on full reads

## Resolved questions

1. **Which unaligned file?** Fully-unaligned (after both nucleotide and
   translated search). This is the smallest set and appropriate because
   microbial reads are already accounted for by HUMAnN.
2. **HUMAnN temp output retention?** Unknown — must verify during
   implementation whether `--remove-temp-output false` is needed.
3. **`skipHumann = true` behavior?** Fall back to full read set so MEDI
   can still run independently.
