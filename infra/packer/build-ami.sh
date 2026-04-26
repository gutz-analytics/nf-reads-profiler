#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-us-east-2}"
DB_BUCKET="${DB_SOURCE_BUCKET:-cjb-gutz-s3-demo}"
SSM_PARAM="${SSM_PARAMETER:-/nf-reads-profiler/ami-id}"

echo "=== Building nf-reads-profiler worker AMI ==="
echo "Region:     $REGION"
echo "DB Bucket:  $DB_BUCKET"
echo "SSM Param:  $SSM_PARAM"
echo ""

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

# Extract AMI ID from manifest and write to SSM
AMI_ID=$(jq -r '.builds[-1].artifact_id | split(":")[1]' packer-manifest.json)

if [[ -z "$AMI_ID" || "$AMI_ID" == "null" ]]; then
  echo "ERROR: Failed to extract AMI ID from packer-manifest.json" >&2
  exit 1
fi

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
