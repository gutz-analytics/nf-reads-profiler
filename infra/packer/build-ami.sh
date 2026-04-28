#!/usr/bin/env bash
# Note: not -e — Packer can exit non-zero (e.g. aws_polling timeout)
# even when the AMI was created successfully. We handle that below by
# falling back to an EC2 query.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-us-east-2}"
DB_BUCKET="${DB_SOURCE_BUCKET:-cjb-gutz-s3-demo}"
SSM_PARAM="${SSM_PARAMETER:-/nf-reads-profiler/ami-id}"

echo "=== Building nf-reads-profiler worker AMI ==="
echo "Region:     $REGION"
echo "DB Bucket:  $DB_BUCKET"
echo "SSM Param:  $SSM_PARAM"
echo ""

# Capture build start time so we can identify "this run's AMI" in the
# EC2 fallback path.
BUILD_START_EPOCH=$(date -u +%s)

cd "$SCRIPT_DIR"

packer init worker-ami.pkr.hcl

packer validate \
  -var "region=$REGION" \
  -var "db_source_bucket=$DB_BUCKET" \
  worker-ami.pkr.hcl

packer build \
  -var "region=$REGION" \
  -var "db_source_bucket=$DB_BUCKET" \
  worker-ami.pkr.hcl
PACKER_RC=$?

# Happy path: manifest is present, parse the AMI ID out of it.
AMI_ID=""
if [[ -f packer-manifest.json ]]; then
  AMI_ID=$(jq -r '.builds[-1].artifact_id | split(":")[1] // empty' packer-manifest.json 2>/dev/null)
fi

# Fallback: Packer's aws_polling timeout can fire on large (500 GB)
# snapshots even though the AMI was created. The post-processor
# manifest is then never written, but the AMI is real. Query EC2
# directly for any self-owned nf-reads-profiler-worker AMI created
# during this run.
if [[ -z "$AMI_ID" || "$AMI_ID" == "null" ]]; then
  echo ""
  echo "=== packer-manifest.json absent or empty; querying EC2 for newly-created AMI (Packer rc=$PACKER_RC) ==="
  AMI_ID=$(aws ec2 describe-images --owners self --region "$REGION" \
    --filters "Name=name,Values=nf-reads-profiler-worker-*" \
    --query 'reverse(sort_by(Images, &CreationDate))[0].ImageId' \
    --output text 2>/dev/null)

  if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    echo "ERROR: no nf-reads-profiler-worker AMI found in account; nothing to publish." >&2
    exit "${PACKER_RC:-1}"
  fi

  AMI_CREATED=$(aws ec2 describe-images --owners self --region "$REGION" \
    --image-ids "$AMI_ID" --query 'Images[0].CreationDate' --output text 2>/dev/null)
  AMI_EPOCH=$(date -u -d "$AMI_CREATED" +%s 2>/dev/null || echo 0)

  if [[ "$AMI_EPOCH" -lt "$BUILD_START_EPOCH" ]]; then
    echo "ERROR: most recent AMI ($AMI_ID, $AMI_CREATED) predates this build (started $(date -u -d @$BUILD_START_EPOCH))." >&2
    echo "       Build produced no AMI; treating as failure." >&2
    exit "${PACKER_RC:-1}"
  fi

  echo "Recovered AMI from EC2: $AMI_ID (created $AMI_CREATED)"
fi

# AMI may still be 'pending' — snapshots are slow and Packer's wait may
# have given up early. Wait for it to reach 'available' before publishing
# to SSM, otherwise stack deploys would race ahead and fail.
echo ""
echo "=== Waiting for AMI $AMI_ID to reach 'available' ==="
aws ec2 wait image-available --image-ids "$AMI_ID" --region "$REGION"

aws ssm put-parameter \
  --name "$SSM_PARAM" \
  --type String \
  --value "$AMI_ID" \
  --overwrite \
  --region "$REGION"

echo ""
echo "=== AMI built successfully ==="
echo "AMI ID:     $AMI_ID"
echo "SSM Param:  $SSM_PARAM"
echo ""
echo "To deploy: run /deploy-stack with EcsAmiId=$AMI_ID"
