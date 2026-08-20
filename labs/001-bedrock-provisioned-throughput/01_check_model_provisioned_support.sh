#!/bin/bash
# 対象モデルが Provisioned Throughput に対応しているか（inferenceTypesSupported に
# PROVISIONED が含まれるか）を確認する。
#
# オンデマンド専用モデルは create-provisioned-model-throughput 自体が失敗するため、
# 購入前にここで対応状況を確認しておく。
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"

aws bedrock list-foundation-models \
  --region "$REGION" \
  --by-provider anthropic \
  --query "modelSummaries[?contains(inferenceTypesSupported, \`PROVISIONED\`)].{modelId:modelId,name:modelName,inferenceTypes:inferenceTypesSupported}" \
  --output table
