#!/bin/bash
# 購入した Provisioned Throughput のステータスと ARN を確認する。
# status が InService になるまで、購入直後は Creating の状態を経由する。
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PROVISIONED_MODEL_NAME="aip-001-bedrock-provisioned-throughput"

aws bedrock get-provisioned-model-throughput \
  --region "$REGION" \
  --provisioned-model-id "$PROVISIONED_MODEL_NAME" \
  --query "{status:status,arn:provisionedModelArn,modelUnits:modelUnits,desiredModelUnits:desiredModelUnits}" \
  --output table
