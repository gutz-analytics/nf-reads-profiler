# I05: E2E smoke test on AWS Batch (2–4 CHILD samples)

**Status:** **DONE — 2026-04-27.** Driver script merged in commit `64eaeac`.
First clean end-to-end pass is run #9 (`smoke-20260427-040532`) — completed
2026-04-27 15:00 UTC after a 9-hour interruption caused by an SSH-disconnect
killing a foreground `nextflow run`. Resume succeeded under `screen -S nf`.
Results: 48 objects in `s3://gutz-nf-reads-profilers-runs/results/smoke-20260427-040532/`,
including a 4.4 MiB MultiQC report. Reports/trace at
`results_local_logs/smoke-20260427-040532/reports/20260427_135437_*`.
Validated the I14 custom-AMI migration. See `logs/2026-04-27-smoke-test-9.log`.

**Priority:** medium — gates all infra changes; run after any significant deployment
**Size:** medium (new shell script ~100 lines + small samplesheet asset)
**Dependencies:** I00 must land first (containerOptions fix is a hard blocker for any
Batch run); I06 should land first (correct time/memory settings reduce false negatives
from resource-limit failures)

---

## Goal

Provide a repeatable end-to-end smoke test that:

1. Runs 2–4 real metagenomic samples from the CHILD cohort through the full pipeline on
   AWS Batch (MetaPhlAn + HUMAnN, no MEDI).
2. Validates that outputs are plausible (sufficient feature counts, no zero-abundance rows)
   without requiring a gold-standard reference diff.
3. Exits non-zero if any check fails, so CI / manual gating is unambiguous.

The smoke test is the green-light gate after any significant infrastructure change
(CloudFormation stack update, new Docker image, DB sync change, etc.).

---

## Samplesheet

Create a 4-sample samplesheet using SRA accessions from the CHILD study.
Use accessions that are known to produce enough reads to clear `minreads`
(100,000) after fastp trimming.

> Verify accessions exist in SRA before finalizing the samplesheet.
> Select small samples for fast turnaround.

Place as `assets/samplesheet-smoke-child.csv`.

---

## Plausibility checks (no gold-standard diff)

| Output | Check | Threshold |
|--------|-------|-----------|
| MetaPhlAn TSV (`*_profile.tsv`) | Non-comment, non-header lines (taxa identified) | > 50 per sample |
| HUMAnN genefamilies TSV (`*_genefamilies.tsv`) | Non-UNMAPPED, non-UNINTEGRATED feature lines | > 50 per sample |
| HUMAnN pathabundance TSV (`*_pathabundance.tsv`) | Non-UNMAPPED, non-UNINTEGRATED feature lines | > 50 per sample |
| HUMAnN genefamilies TSV | Rows with abundance == 0 | 0 (none allowed) |
| HUMAnN pathabundance TSV | Rows with abundance == 0 | 0 (none allowed) |

**No MEDI outputs** — the script must not pass `--enable_medi` and must not check for
any `medi/` directory. MEDI is deferred.

---

## Files to create

```
assets/samplesheet-smoke-child.csv       # 4-row samplesheet (SRA accessions, CHILD study)
infra/smoke-test.sh                      # Executable smoke-test driver script
```

### `infra/smoke-test.sh` — outline

```bash
#!/usr/bin/env bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REGION=us-east-2
RUNS_BUCKET=gutz-nf-reads-profilers-runs
SAMPLESHEET=s3://${RUNS_BUCKET}/samplesheets/samplesheet-smoke-child.csv
PROJECT=smoke-test-$(date +%Y%m%d-%H%M%S)
OUTDIR=s3://${RUNS_BUCKET}/results
PASS=0; FAIL=0

# ── Pre-flight checks ─────────────────────────────────────────────────────────
# 1. Batch queue and CEs are ENABLED + VALID
# 2. S3 buckets are reachable
# 3. Samplesheet exists in S3 (upload if not)

# ── Run pipeline ──────────────────────────────────────────────────────────────
nextflow run main.nf \
  -profile aws \
  --input  "${SAMPLESHEET}" \
  --project "${PROJECT}"
# Note: no --enable_medi; no -resume (smoke tests run clean)

# ── Validate outputs ─────────────────────────────────────────────────────────
# For each sample × {_profile.tsv, _genefamilies.tsv, _pathabundance.tsv}:
#   aws s3 cp <file> /tmp/smoke/<sample>_<type>.tsv
#   Count qualifying feature lines; assert > 50
#   Assert no zero-abundance rows (for HUMAnN files)

# ── Report ────────────────────────────────────────────────────────────────────
echo "PASS: ${PASS}  FAIL: ${FAIL}"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
```

---

## Exact checks (implementation guide)

### MetaPhlAn TSV

A MetaPhlAn profile TSV has a comment header (`#`) and a column-header line,
then one taxon per row.

```bash
feature_count=$(grep -v '^#' "$tsv" | grep -v '^clade_name' | wc -l)
[[ $feature_count -gt 50 ]] || { echo "FAIL: $tsv has only $feature_count features"; FAIL=$((FAIL+1)); }
```

### HUMAnN genefamilies / pathabundance TSVs

HUMAnN TSVs have a single header line, then feature rows. Exclude the
`UNMAPPED` and `UNINTEGRATED` sentinel rows from the count.

```bash
data_rows=$(tail -n +2 "$tsv" | grep -v '^UNMAPPED' | grep -v '^UNINTEGRATED')
feature_count=$(echo "$data_rows" | wc -l)
[[ $feature_count -gt 50 ]] || { echo "FAIL: $tsv has only $feature_count features"; FAIL=$((FAIL+1)); }

zero_rows=$(echo "$data_rows" | awk -F'\t' '$2 == 0' | wc -l)
[[ $zero_rows -eq 0 ]] || { echo "FAIL: $tsv has $zero_rows zero-abundance rows"; FAIL=$((FAIL+1)); }
```

---

## Verification

1. Upload `assets/samplesheet-smoke-child.csv` to S3.
2. Run `bash infra/smoke-test.sh` from the runner VM.
3. Confirm Nextflow logs show all four samples completing (no `FAILED` tasks).
4. Confirm the script exits 0.
5. Spot-check one MetaPhlAn TSV — should contain recognizable gut taxa
   (e.g. `Bacteroides`, `Prevotella`, `Bifidobacterium`).
6. Spot-check one genefamilies TSV — should have UniRef90 gene family lines.

## What this test does NOT cover

- Correctness of abundance values (no reference diff).
- MEDI / food-microbiome quantification (deferred).
- Combined/merged per-study output TSVs (only per-sample outputs checked).
- MultiQC report content.

## Notes

- Use a fresh `--project` name each run (timestamped) to avoid the
  `output_exists()` early-exit logic in `main.nf` skipping samples from a
  previous smoke run.
- Do **not** pass `-resume` — the goal is to validate a complete fresh execution.
- The 4-sample size keeps wall-clock time under ~2 hours while exercising the
  per-sample → combine → split pipeline graph.
