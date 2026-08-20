#!/bin/bash
# 問23の核心を再現する: modelId にベースモデルID(オンデマンド)を渡した場合と、
# provisionedModelArn を渡した場合とで、同じリクエストがどちらのキャパシティに
# ルーティングされるかを比較する。
#
# CloudWatch 上では、Provisioned 側にルーティングされたリクエストのみ
# AWS/Bedrock 名前空間の ProvisionedModelArn ディメンションにメトリクスが記録される。
# オンデマンドの modelId のままだと、いくら Provisioned Throughput を購入していても
# このディメンションにメトリクスが乗らない = 専用キャパシティが使われていない、
# という形で確認できる。
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
BASE_MODEL_ID="anthropic.claude-3-haiku-20240307-v1:0"
PROVISIONED_MODEL_NAME="aip-001-bedrock-provisioned-throughput"

PROVISIONED_MODEL_ARN=$(aws bedrock get-provisioned-model-throughput \
  --region "$REGION" \
  --provisioned-model-id "$PROVISIONED_MODEL_NAME" \
  --query "provisionedModelArn" \
  --output text)

PAYLOAD='{
  "anthropic_version": "bedrock-2023-05-31",
  "max_tokens": 100,
  "messages": [{"role": "user", "content": "1文で自己紹介して"}]
}'

echo "=== NG: modelId にベースモデルID(オンデマンド)を渡す ==="
aws bedrock-runtime invoke-model \
  --region "$REGION" \
  --model-id "$BASE_MODEL_ID" \
  --body "$(echo "$PAYLOAD" | base64)" \
  --content-type application/json \
  --accept application/json \
  ondemand_response.json
echo "-> オンデマンドエンドポイントで処理される。購入済みのProvisioned容量は消費されない。"

echo ""
echo "=== OK: modelId に provisionedModelArn を渡す ==="
aws bedrock-runtime invoke-model \
  --region "$REGION" \
  --model-id "$PROVISIONED_MODEL_ARN" \
  --body "$(echo "$PAYLOAD" | base64)" \
  --content-type application/json \
  --accept application/json \
  provisioned_response.json
echo "-> Provisioned Throughputの専用キャパシティにルーティングされる。"

echo ""
echo "=== CloudWatchメトリクスで確認(ProvisionedModelArnディメンション) ==="
echo "aws cloudwatch get-metric-statistics \\"
echo "  --region $REGION \\"
echo "  --namespace AWS/Bedrock \\"
echo "  --metric-name Invocations \\"
echo "  --dimensions Name=ProvisionedModelArn,Value=$PROVISIONED_MODEL_ARN \\"
echo "  --start-time \$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S) \\"
echo "  --end-time \$(date -u +%Y-%m-%dT%H:%M:%S) \\"
echo "  --period 300 --statistics Sum"
