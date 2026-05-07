#!/usr/bin/env bash
# Kill-switch for EBS Fast Snapshot Restore billing.
#
# Disables FSR on EVERY snapshot/AZ pair currently in 'enabled',
# 'enabling', or 'optimizing' state in this region — not just the
# current AMI's snapshot. This protects against forgotten FSR on a
# rolled-over (stale) AMI snapshot.
#
# Required IAM (on the caller's role):
#   ec2:DescribeFastSnapshotRestores
#   ec2:DisableFastSnapshotRestores
#
# Billing stops as soon as state transitions out of 'enabled'/'enabling'/
# 'optimizing'. Minimum 1-hour-per-enable-cycle has already been billed.
set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"

echo "=== Disable FSR (kill switch) ==="
echo "Region: $REGION"
echo ""

# 1. Enumerate all currently-billing FSR pairs
ACTIVE=$(aws ec2 describe-fast-snapshot-restores --region "$REGION" \
  --filters "Name=state,Values=enabled,enabling,optimizing" \
  --query 'FastSnapshotRestores[].[SnapshotId,AvailabilityZone,State]' \
  --output text)

if [[ -z "$ACTIVE" ]]; then
  echo "No FSR-enabled snapshots in $REGION. Nothing to disable."
  echo ""
  echo "=== FSR INACTIVE — NO BILLING ==="
  exit 0
fi

echo "Currently billing:"
echo "$ACTIVE" | sed 's/^/  /'
echo ""

# 2. Group by snapshot, disable each (one API call per snapshot, all AZs)
SNAPS=$(echo "$ACTIVE" | awk '{print $1}' | sort -u)
for SNAP in $SNAPS; do
  AZS=$(echo "$ACTIVE" | awk -v s="$SNAP" '$1 == s {print $2}')
  echo "Disabling $SNAP in: $(echo $AZS | tr '\n' ' ')"
  # Re-running disable on already-disabling pairs is idempotent on AWS's
  # side, so we don't treat Unsuccessful entries as fatal here — the
  # final verify-loop is the source of truth.
  aws ec2 disable-fast-snapshot-restores --region "$REGION" \
    --availability-zones $AZS --source-snapshot-ids "$SNAP" \
    --output json | jq -r '
      "  Successful: " + ((.Successful // []) | length | tostring) +
      "  Unsuccessful: " + ((.Unsuccessful // []) | length | tostring)'
done

# 3. Verify — final state should have no enabled/enabling/optimizing
echo ""
echo "=== Verifying no AZ-snapshot pairs remain billing ==="
sleep 3  # give AWS a moment to reflect state change
REMAINING=$(aws ec2 describe-fast-snapshot-restores --region "$REGION" \
  --filters "Name=state,Values=enabled,enabling,optimizing" \
  --query 'FastSnapshotRestores[].[SnapshotId,AvailabilityZone,State]' \
  --output text)

STOP_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ -n "$REMAINING" ]]; then
  echo "WARN: some pairs still in billing state (may be transitioning):"
  echo "$REMAINING" | sed 's/^/  /'
  echo ""
  echo "Re-run this script in 1 min to confirm; transition to 'disabled' is usually instant."
  exit 1
fi

echo "All FSR pairs are 'disabled' or 'disabling'."
echo ""
echo "=== FSR DISABLED — BILLING STOPPED ==="
echo "Stopped:  $STOP_TS"
echo ""
echo "Note: AWS bills a 1-hour minimum per enable-cycle, regardless of how"
echo "      quickly disable was called."
