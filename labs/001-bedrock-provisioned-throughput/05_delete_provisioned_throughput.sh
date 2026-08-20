#!/bin/bash
# 片付け: Provisioned Throughput を削除する。
# No Commitmentでも時間単位の課金が発生し続けるため、検証後は必ず削除する。
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PROVISIONED_MODEL_NAME="aip-001-bedrock-provisioned-throughput"

aws bedrock delete-provisioned-model-throughput \
  --region "$REGION" \
  --provisioned-model-id "$PROVISIONED_MODEL_NAME"

echo "削除リクエスト送信済み。list-provisioned-model-throughputs で残骸がないか確認すること。"
