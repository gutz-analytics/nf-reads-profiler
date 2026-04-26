#!/usr/bin/env bash
# infra/smoke-test.sh
#
# End-to-end smoke test: runs 2 samples through MetaPhlAn + HUMAnN on AWS Batch,
# then validates that outputs exist and are plausible.
#
# Usage:  bash infra/smoke-test.sh
#         (run from the repo root on the head-node runner VM)

set -euo pipefail

# ── Config ──────��─────────────────────────────────────���───────────────────────
REGION=us-east-2
RUNS_BUCKET=gutz-nf-reads-profilers-runs
SAMPLESHEET_LOCAL=assets/samplesheet-smoke-child.csv
SAMPLESHEET_S3="s3://${RUNS_BUCKET}/samplesheets/samplesheet-smoke-child.csv"
PROJECT="smoke-$(date +%Y%m%d-%H%M%S)"
OUTDIR="s3://${RUNS_BUCKET}/results"
TMPDIR_SMOKE="/tmp/smoke-$$"
PASS=0
FAIL=0

cleanup() { rm -rf "$TMPDIR_SMOKE"; }
trap cleanup EXIT

check() {
    local name="$1"; shift
    if "$@"; then
        echo "  PASS: $name"
        (( PASS++ )) || true
    else
        echo "  FAIL: $name"
        (( FAIL++ )) || true
    fi
}

# ── Pre-flight checks ────────────────────────────────────────────────────────
echo "=== Pre-flight checks ==="

if [[ ! -f main.nf ]]; then
    echo "ERROR: main.nf not found. Run this script from the repo root." >&2
    exit 1
fi

if [[ ! -f "$SAMPLESHEET_LOCAL" ]]; then
    echo "ERROR: $SAMPLESHEET_LOCAL not found." >&2
    exit 1
fi

queue_state=$(aws batch describe-job-queues \
    --job-queues spot-queue --region "$REGION" \
    --query "jobQueues[0].state" --output text 2>/dev/null)
if [[ "$queue_state" != "ENABLED" ]]; then
    echo "ERROR: spot-queue state is '$queue_state', expected ENABLED." >&2
    exit 1
fi
echo "  OK: spot-queue is ENABLED"

ce_count=$(aws batch describe-compute-environments --region "$REGION" \
    --query "computeEnvironments[?state=='ENABLED' && status=='VALID'] | length(@)" \
    --output text 2>/dev/null)
if [[ "$ce_count" -lt 2 ]]; then
    echo "ERROR: Expected 2 ENABLED/VALID compute environments, found $ce_count." >&2
    exit 1
fi
echo "  OK: $ce_count compute environments ENABLED/VALID"

aws s3 ls "s3://${RUNS_BUCKET}/" --region "$REGION" > /dev/null 2>&1 || {
    echo "ERROR: Cannot access s3://${RUNS_BUCKET}/." >&2
    exit 1
}
echo "  OK: S3 runs bucket accessible"

echo "  Uploading samplesheet to S3..."
aws s3 cp "$SAMPLESHEET_LOCAL" "$SAMPLESHEET_S3" --region "$REGION" > /dev/null
echo "  OK: Samplesheet uploaded to $SAMPLESHEET_S3"

# ── Run pipeline ──────────────────────────────────────────────────────────────
echo ""
echo "=== Running pipeline (project: $PROJECT) ==="
echo "  Start: $(date)"

nextflow run main.nf \
    -profile aws \
    --input "$SAMPLESHEET_S3" \
    --project "$PROJECT"

NF_EXIT=$?
echo "  End: $(date)"

if [[ $NF_EXIT -ne 0 ]]; then
    echo "ERROR: Nextflow exited with code $NF_EXIT." >&2
    exit 1
fi
echo "  OK: Nextflow completed successfully"

# ── Validate outputs ───────────────────────────���─────────────────────────────
echo ""
echo "=== Validating outputs ==="
mkdir -p "$TMPDIR_SMOKE"

# Read sample names from samplesheet (skip header)
SAMPLES=()
while IFS=, read -r sample _ _ _ study; do
    SAMPLES+=("$sample")
    STUDY="$study"
done < <(tail -n +2 "$SAMPLESHEET_LOCAL")

for SAMPLE in "${SAMPLES[@]}"; do
    echo "  --- Sample: $SAMPLE ---"
    S3_TAXA="${OUTDIR}/${PROJECT}/${STUDY}/taxa"
    S3_FUNC="${OUTDIR}/${PROJECT}/${STUDY}/function"

    # MetaPhlAn biom — check existence and minimum size
    BIOM="${TMPDIR_SMOKE}/${SAMPLE}_metaphlan.biom"
    if aws s3 cp "${S3_TAXA}/${SAMPLE}_metaphlan.biom" "$BIOM" --region "$REGION" > /dev/null 2>&1; then
        biom_size=$(wc -c < "$BIOM")
        check "MetaPhlAn biom exists and >1KB ($biom_size bytes)" [[ "$biom_size" -gt 1024 ]]
    else
        echo "  FAIL: MetaPhlAn biom not found at ${S3_TAXA}/${SAMPLE}_metaphlan.biom"
        (( FAIL++ )) || true
    fi

    # HUMAnN genefamilies
    GF="${TMPDIR_SMOKE}/${SAMPLE}_2_genefamilies.tsv"
    if aws s3 cp "${S3_FUNC}/${SAMPLE}_2_genefamilies.tsv" "$GF" --region "$REGION" > /dev/null 2>&1; then
        gf_features=$(tail -n +2 "$GF" | grep -v '^UNMAPPED' | grep -v '^UNINTEGRATED' | wc -l)
        check "genefamilies has >50 features ($gf_features)" [[ "$gf_features" -gt 50 ]]

        gf_zeros=$(tail -n +2 "$GF" | grep -v '^UNMAPPED' | grep -v '^UNINTEGRATED' | awk -F'\t' '$2 == 0' | wc -l)
        check "genefamilies has 0 zero-abundance rows ($gf_zeros)" [[ "$gf_zeros" -eq 0 ]]
    else
        echo "  FAIL: genefamilies TSV not found at ${S3_FUNC}/${SAMPLE}_2_genefamilies.tsv"
        (( FAIL++ )) || true
    fi

    # HUMAnN pathabundance
    PA="${TMPDIR_SMOKE}/${SAMPLE}_4_pathabundance.tsv"
    if aws s3 cp "${S3_FUNC}/${SAMPLE}_4_pathabundance.tsv" "$PA" --region "$REGION" > /dev/null 2>&1; then
        pa_features=$(tail -n +2 "$PA" | grep -v '^UNMAPPED' | grep -v '^UNINTEGRATED' | wc -l)
        check "pathabundance has >50 features ($pa_features)" [[ "$pa_features" -gt 50 ]]

        pa_zeros=$(tail -n +2 "$PA" | grep -v '^UNMAPPED' | grep -v '^UNINTEGRATED' | awk -F'\t' '$2 == 0' | wc -l)
        check "pathabundance has 0 zero-abundance rows ($pa_zeros)" [[ "$pa_zeros" -eq 0 ]]
    else
        echo "  FAIL: pathabundance TSV not found at ${S3_FUNC}/${SAMPLE}_4_pathabundance.tsv"
        (( FAIL++ )) || true
    fi
done

# ── Report ──────────────���─────────────────────────────��───────────────────────
echo ""
echo "============================================"
echo "SMOKE TEST RESULTS: ${PASS} passed, ${FAIL} failed"
echo "Project: ${PROJECT}"
echo "Outputs: ${OUTDIR}/${PROJECT}/"
echo "============================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
