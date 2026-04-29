#!/usr/bin/env bash
# Enable EBS Fast Snapshot Restore on the worker AMI's root snapshot
# across all 3 us-east-2 AZs. Idempotent — re-running while already
# enabled is a no-op.
#
# Required IAM (on the caller's role):
#   ec2:EnableFastSnapshotRestores
#   ec2:DescribeFastSnapshotRestores
#   ec2:DescribeImages
#   ssm:GetParameter
#
# Billing starts the moment a snapshot/AZ pair enters `enabling` state.
# Minimum 1 hour per AZ per enable-cycle. See I24 for cost framing.
set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
SSM_PARAM="${SSM_PARAMETER:-/nf-reads-profiler/ami-id}"
AZS=("${REGION}a" "${REGION}b" "${REGION}c")
RATE_PER_AZ_HR="0.75"
TOTAL_HR=$(awk "BEGIN{print ${RATE_PER_AZ_HR} * ${#AZS[@]}}")
TIMEOUT_SEC="${FSR_TIMEOUT_SEC:-3600}"  # 60 min — large snapshots take 30+ min
POLL_SEC="${FSR_POLL_SEC:-30}"

echo "=== Enable FSR on nf-reads-profiler worker AMI ==="
echo "Region:    $REGION"
echo "SSM Param: $SSM_PARAM"
echo "AZs:       ${AZS[*]}"
echo ""

# 1. Resolve AMI -> snapshot
AMI_ID=$(aws ssm get-parameter --name "$SSM_PARAM" --region "$REGION" \
  --query 'Parameter.Value' --output text)
if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
  echo "ERROR: SSM parameter $SSM_PARAM is empty or missing" >&2
  exit 1
fi

SNAP_ID=$(aws ec2 describe-images --image-ids "$AMI_ID" --region "$REGION" \
  --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)
if [[ -z "$SNAP_ID" || "$SNAP_ID" == "None" ]]; then
  echo "ERROR: could not resolve root snapshot for $AMI_ID" >&2
  exit 1
fi

echo "AMI:       $AMI_ID"
echo "Snapshot:  $SNAP_ID"
echo ""

# 2. Billing confirmation gate
DAILY_COST=$(awk "BEGIN{printf \"%.0f\", ${TOTAL_HR} * 24}")
cat <<EOF
=========================== BILLING NOTICE ===========================
 Enabling FSR starts billing immediately.
   Rate:    \$${RATE_PER_AZ_HR}/AZ/hr × ${#AZS[@]} AZs = \$${TOTAL_HR}/hr
   Minimum: 1 hour per AZ per enable-cycle (cannot be shortened).
   24h:     ~\$${DAILY_COST}

 Run disable-fsr.sh after the pipeline finishes to stop billing.
======================================================================
EOF

if [[ "${FSR_CONFIRM:-no}" != "yes" ]]; then
  echo ""
  echo "ABORT: set FSR_CONFIRM=yes to acknowledge billing and proceed."
  echo "  FSR_CONFIRM=yes $0"
  exit 1
fi

# 3. Enable across all AZs in one call (atomic, returns Successful/Unsuccessful)
echo ""
echo "=== Submitting enable request ==="
ENABLE_OUT=$(aws ec2 enable-fast-snapshot-restores --region "$REGION" \
  --availability-zones "${AZS[@]}" --source-snapshot-ids "$SNAP_ID" \
  --output json)

UNSUCCESSFUL=$(echo "$ENABLE_OUT" | jq -r '.Unsuccessful // [] | length')
if [[ "$UNSUCCESSFUL" -gt 0 ]]; then
  # Idempotent path: API returns "already enabled" as Unsuccessful with a
  # specific code. Treat that as success; bail on anything else.
  REAL_FAILS=$(echo "$ENABLE_OUT" | jq -r '
    .Unsuccessful[] | select(
      (.FastSnapshotRestoreStateErrors // [])
        | map(.Error.Code)
        | any(. != "InvalidFastSnapshotRestoreState.AlreadyEnabled")
    ) | .SnapshotId')
  if [[ -n "$REAL_FAILS" ]]; then
    echo "ERROR: enable failed for some AZs:" >&2
    echo "$ENABLE_OUT" | jq '.Unsuccessful' >&2
    exit 1
  fi
  echo "Note: some AZs were already enabled (idempotent re-run)."
fi

# 4. Poll until all AZs reach 'enabled' (not 'enabling' or 'optimizing')
echo ""
echo "=== Waiting for all ${#AZS[@]} AZs to reach 'enabled' state ==="
echo "(typical: 15-30 min for a 150 GB snapshot; timeout: ${TIMEOUT_SEC}s)"
echo ""

DEADLINE=$(($(date +%s) + TIMEOUT_SEC))
while true; do
  STATE_TABLE=$(aws ec2 describe-fast-snapshot-restores --region "$REGION" \
    --filters "Name=snapshot-id,Values=$SNAP_ID" \
    --query 'FastSnapshotRestores[].[AvailabilityZone,State]' --output text)

  TS=$(date -u +%H:%M:%S)
  echo "[$TS UTC]"
  echo "$STATE_TABLE" | sed 's/^/  /'

  PENDING=$(echo "$STATE_TABLE" | awk '$2 != "enabled" {print $1}' | wc -l)
  if [[ "$PENDING" -eq 0 ]]; then
    break
  fi

  if [[ "$(date +%s)" -gt "$DEADLINE" ]]; then
    echo ""
    echo "ERROR: timeout after ${TIMEOUT_SEC}s with $PENDING AZs still not 'enabled'." >&2
    echo "       Run disable-fsr.sh to stop billing if you want to abort." >&2
    exit 1
  fi

  sleep "$POLL_SEC"
done

# 5. Final summary
START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo ""
echo "=== FSR ENABLED — BILLING ACTIVE ==="
echo "Snapshot:    $SNAP_ID"
echo "AZs:         ${AZS[*]} (all 'enabled')"
echo "Started:     $START_TS"
echo "Rate:        \$${TOTAL_HR}/hr (\$${RATE_PER_AZ_HR}/AZ × ${#AZS[@]} AZs)"
echo ""
echo "Run infra/packer/disable-fsr.sh after the pipeline run completes."
