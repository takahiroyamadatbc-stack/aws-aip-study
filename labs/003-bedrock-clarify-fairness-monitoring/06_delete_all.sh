#!/bin/bash
# 片付け。作成した順と逆順に削除する。
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="aip-003-bedrock-clarify-${ACCOUNT_ID}"
ROLE_NAME="aip-003-bedrock-clarify-role"
SCHEDULE_NAME="aip-003-bias-monitoring-schedule"
DASHBOARD_NAME="aip-003-bedrock-fairness-weekly"

echo "=== CloudWatchダッシュボード・アラーム削除 ==="
aws cloudwatch delete-dashboards --region "$REGION" --dashboard-names "$DASHBOARD_NAME" || true
aws cloudwatch delete-alarms --region "$REGION" --alarm-names "aip-003-fairness-dppl-threshold" || true

echo "=== EventBridge Scheduler削除 ==="
aws scheduler delete-schedule --name "$SCHEDULE_NAME" || true

echo "=== IAMロール削除 ==="
aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess || true
aws iam delete-role --role-name "$ROLE_NAME" || true

echo "=== S3バケット削除(オブジェクト全削除→バケット削除) ==="
aws s3 rm "s3://${BUCKET_NAME}" --recursive || true
aws s3api delete-bucket --region "$REGION" --bucket "$BUCKET_NAME" || true

echo "=== 消し忘れ確認 ==="
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=aip-study \
  --query "ResourceTagMappingList[?contains(ResourceARN, 'aip-003')].ResourceARN"
