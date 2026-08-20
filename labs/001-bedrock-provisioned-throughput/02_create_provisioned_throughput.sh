#!/bin/bash
# Provisioned Throughput を購入し、専用の provisionedModelArn を発行する。
#
# 注意:
# - Claude モデルの Provisioned Throughput はモデルユニット単位で課金が発生する
#   （No Commitment でも 1 時間単位の課金あり、1ヶ月/6ヶ月コミットならさらに高額）。
#   本Labでは標準ルールに従い実行しない前提とし、コードのみ残す。
# - --commitment-duration を省略すると No Commitment（時間単位で解約可）になる。
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
BASE_MODEL_ID="anthropic.claude-3-haiku-20240307-v1:0"
PROVISIONED_MODEL_NAME="aip-001-bedrock-provisioned-throughput"

aws bedrock create-provisioned-model-throughput \
  --region "$REGION" \
  --model-id "$BASE_MODEL_ID" \
  --provisioned-model-name "$PROVISIONED_MODEL_NAME" \
  --model-units 1 \
  --tags Key=Project,Value=aip-study

# 実行結果に含まれる provisionedModelArn を控えておく。
# 例: arn:aws:bedrock:us-east-1:123456789012:provisioned-model/xxxxxxxxxxxx
# これが InvokeModel/Converse の modelId に渡すべき値であり、問23の正解(A)の核心。
