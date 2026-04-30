#!/usr/bin/env bash
# infra/max005_test.sh
#
# Scaling baseline test (I16): runs the 5 largest CHILD samples through
# MetaPhlAn + HUMAnN on AWS Batch, validates outputs, and prints a
# metrics summary (wallclock, S3 workdir size, results size).
#
# Target: complete all 5 samples for ≤ $100 total wall cost.
#
# IMPORTANT — launch under screen (or tmux):
#   screen -dmS nf -L -Logfile logs/max005-$(date +%Y%m%d-%H%M%S).log \
#       bash -lc 'bash infra/max005_test.sh; exec bash'
# (Direct foreground invocation will die on SSH disconnect; see smoke-9 incident
#  in logs/2026-04-27-smoke-test-9.log.)
#
# Usage:
#   bash infra/max005_test.sh                    # fresh run, generates new project name
#   bash infra/max005_test.sh <project-name>     # resume mode — re-runs into the
#                                                  existing project, cache-hits any
#                                                  already-succeeded tasks. Useful after
#                                                  a spot-reclaim cascade or partial run.
#         (run from the repo root on the head-node runner VM)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REGION=us-east-2
RUNS_BUCKET=gutz-nf-reads-profilers-runs
WORKDIR_BUCKET=gutz-nf-reads-profilers-workdir
SAMPLESHEET_LOCAL=assets/samplesheet-max005-child.csv
SAMPLESHEET_S3="s3://${RUNS_BUCKET}/samplesheets/sra-child-max005.csv"
OUTDIR="s3://${RUNS_BUCKET}/results"
TMPDIR_TEST="/tmp/max005-$$"
PASS=0
FAIL=0

# Resume mode: if a project name is passed as $1, reuse it and add -resume.
# Otherwise generate a fresh timestamped project for a clean run.
if [[ -n "${1:-}" ]]; then
    PROJECT="$1"
    RESUME_FLAG="-resume"
    echo "Resume mode: project=$PROJECT (cache will be honoured for already-succeeded tasks)"
else
    PROJECT="max005-$(date +%Y%m%d-%H%M%S)"
    RESUME_FLAG=""
fi

cleanup() { rm -rf "$TMPDIR_TEST"; }
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

# Warn if not running inside screen/tmux (SSH disconnect = SIGHUP = dead Nextflow)
if [[ -z "${STY:-}" && -z "${TMUX:-}" ]]; then
    echo "  WARNING: not running inside screen or tmux. SSH disconnect will kill Nextflow."
    echo "           Ctrl-C now if this is interactive; otherwise continuing in 5s."
    sleep 5
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

# Refuse to start if other jobs are already on the queue (avoids attribution
# headaches in metrics + cost reporting)
busy=0
for s in SUBMITTED PENDING RUNNABLE STARTING RUNNING; do
    n=$(aws batch list-jobs --region "$REGION" --job-queue spot-queue --job-status "$s" \
        --query 'length(jobSummaryList)' --output text)
    busy=$((busy + n))
done
if [[ "$busy" -gt 0 ]]; then
    echo "ERROR: spot-queue has $busy jobs already in flight. Wait or terminate before running this test." >&2
    exit 1
fi
echo "  OK: spot-queue is empty"

aws s3 ls "s3://${RUNS_BUCKET}/" --region "$REGION" > /dev/null 2>&1 || {
    echo "ERROR: Cannot access s3://${RUNS_BUCKET}/." >&2
    exit 1
}
echo "  OK: S3 runs bucket accessible"

echo "  Uploading samplesheet to S3..."
aws s3 cp "$SAMPLESHEET_LOCAL" "$SAMPLESHEET_S3" --region "$REGION" > /dev/null
echo "  OK: Samplesheet uploaded to $SAMPLESHEET_S3"

# Snapshot workdir size before run (for delta calculation later)
PRE_WORKDIR_BYTES=$(aws s3 ls "s3://${WORKDIR_BUCKET}/" --recursive --region "$REGION" --summarize 2>/dev/null \
    | awk '/Total Size:/{print $3}')
PRE_WORKDIR_BYTES=${PRE_WORKDIR_BYTES:-0}
echo "  S3 workdir bytes (pre-run): $PRE_WORKDIR_BYTES"

# ── Run pipeline ──────────────────────────────────────────────────────────────
echo ""
echo "=== Running pipeline (project: $PROJECT) ==="
START_EPOCH=$(date -u +%s)
echo "  Start: $(date -u)"

set +e
nextflow run main.nf \
    -profile aws \
    --input "$SAMPLESHEET_S3" \
    --project "$PROJECT" \
    $RESUME_FLAG
NF_EXIT=$?
set -e

END_EPOCH=$(date -u +%s)
WALLCLOCK_SEC=$((END_EPOCH - START_EPOCH))
echo "  End: $(date -u)"
echo "  Wallclock: ${WALLCLOCK_SEC}s ($((WALLCLOCK_SEC / 60))m $((WALLCLOCK_SEC % 60))s)"

if [[ $NF_EXIT -ne 0 ]]; then
    echo "ERROR: Nextflow exited with code $NF_EXIT." >&2
    exit 1
fi
echo "  OK: Nextflow completed successfully"

# ── Validate outputs ─────────────────────────────────────────────────────────
echo ""
echo "=== Validating outputs ==="
mkdir -p "$TMPDIR_TEST"

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

    BIOM="${TMPDIR_TEST}/${SAMPLE}_metaphlan.biom"
    if aws s3 cp "${S3_TAXA}/${SAMPLE}_metaphlan.biom" "$BIOM" --region "$REGION" > /dev/null 2>&1; then
        biom_size=$(wc -c < "$BIOM")
        check "MetaPhlAn biom exists and >1KB ($biom_size bytes)" test "$biom_size" -gt 1024
    else
        echo "  FAIL: MetaPhlAn biom not found at ${S3_TAXA}/${SAMPLE}_metaphlan.biom"
        (( FAIL++ )) || true
    fi

    GF="${TMPDIR_TEST}/${SAMPLE}_2_genefamilies.tsv"
    if aws s3 cp "${S3_FUNC}/${SAMPLE}_2_genefamilies.tsv" "$GF" --region "$REGION" > /dev/null 2>&1; then
        gf_features=$(tail -n +2 "$GF" | grep -v '^UNMAPPED' | grep -v '^UNINTEGRATED' | wc -l)
        check "genefamilies has >50 features ($gf_features)" test "$gf_features" -gt 50

        gf_zeros=$(tail -n +2 "$GF" | grep -v '^UNMAPPED' | grep -v '^UNINTEGRATED' | awk -F'\t' '$2 == 0' | wc -l)
        check "genefamilies has 0 zero-abundance rows ($gf_zeros)" test "$gf_zeros" -eq 0
    else
        echo "  FAIL: genefamilies TSV not found at ${S3_FUNC}/${SAMPLE}_2_genefamilies.tsv"
        (( FAIL++ )) || true
    fi

    # NB: pathabundance assertion is strict. Smoke #9 produced 90-byte
    # pathabundance files (suspected utility_DEMO pathways DB issue). If this
    # check fails on max005, the DEMO-DB problem is not yet resolved; treat
    # it as data-quality info, not a script bug.
    PA="${TMPDIR_TEST}/${SAMPLE}_4_pathabundance.tsv"
    if aws s3 cp "${S3_FUNC}/${SAMPLE}_4_pathabundance.tsv" "$PA" --region "$REGION" > /dev/null 2>&1; then
        pa_features=$(tail -n +2 "$PA" | grep -v '^UNMAPPED' | grep -v '^UNINTEGRATED' | wc -l)
        check "pathabundance has >50 features ($pa_features)" test "$pa_features" -gt 50

        pa_zeros=$(tail -n +2 "$PA" | grep -v '^UNMAPPED' | grep -v '^UNINTEGRATED' | awk -F'\t' '$2 == 0' | wc -l)
        check "pathabundance has 0 zero-abundance rows ($pa_zeros)" test "$pa_zeros" -eq 0
    else
        echo "  FAIL: pathabundance TSV not found at ${S3_FUNC}/${SAMPLE}_4_pathabundance.tsv"
        (( FAIL++ )) || true
    fi
done

# ── Metrics summary ───────────────────────────────────────────────────────────
echo ""
echo "=== Metrics summary ==="

POST_WORKDIR_BYTES=$(aws s3 ls "s3://${WORKDIR_BUCKET}/" --recursive --region "$REGION" --summarize 2>/dev/null \
    | awk '/Total Size:/{print $3}')
POST_WORKDIR_BYTES=${POST_WORKDIR_BYTES:-0}
WORKDIR_DELTA=$((POST_WORKDIR_BYTES - PRE_WORKDIR_BYTES))

RESULTS_BYTES=$(aws s3 ls "${OUTDIR}/${PROJECT}/" --recursive --region "$REGION" --summarize 2>/dev/null \
    | awk '/Total Size:/{print $3}')
RESULTS_BYTES=${RESULTS_BYTES:-0}

# Human-readable byte formatter
fmt_bytes() {
    local b=$1
    if   (( b > 1073741824 )); then printf '%.2f GiB' "$(echo "$b / 1073741824" | bc -l)"
    elif (( b > 1048576 ));    then printf '%.2f MiB' "$(echo "$b / 1048576"    | bc -l)"
    elif (( b > 1024 ));       then printf '%.2f KiB' "$(echo "$b / 1024"       | bc -l)"
    else printf '%d B' "$b"
    fi
}

cat <<EOF

  Project:            $PROJECT
  Samples processed:  ${#SAMPLES[@]}
  Wallclock:          ${WALLCLOCK_SEC}s ($((WALLCLOCK_SEC / 60))m $((WALLCLOCK_SEC % 60))s)
  S3 workdir delta:   $(fmt_bytes "$WORKDIR_DELTA") (pre=$(fmt_bytes "$PRE_WORKDIR_BYTES"), post=$(fmt_bytes "$POST_WORKDIR_BYTES"))
  S3 results size:    $(fmt_bytes "$RESULTS_BYTES")
  Reports (local):    results_local_logs/${PROJECT}/reports/
  Results (S3):       ${OUTDIR}/${PROJECT}/

  Cost data is NOT captured here — query Cost Explorer for the
  $PROJECT project tag (24h lag) or filter by run window
  $(date -u -d "@$START_EPOCH" '+%Y-%m-%d %H:%M') – $(date -u -d "@$END_EPOCH" '+%Y-%m-%d %H:%M').
EOF

# ── Report ────────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "MAX005 TEST RESULTS: ${PASS} passed, ${FAIL} failed"
echo "Project: ${PROJECT}"
echo "Outputs: ${OUTDIR}/${PROJECT}/"
echo "============================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
