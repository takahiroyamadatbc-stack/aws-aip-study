#!/bin/bash
# バイアス監視パイプラインの土台(S3バケット + SageMaker Clarify実行用IAMロール)を作る。
#
# Bedrock自体にはSageMakerエンドポイントのData Captureに相当する
# 「呼び出しを自動でS3にキャプチャする」ネイティブ機能が存在しない。
# そのためこのS3バケットは、02のスクリプトでアプリ側が明示的に
# プロンプト・レスポンス・デモグラフィック属性を書き込む先として使う。
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="aip-003-bedrock-clarify-${ACCOUNT_ID}"
ROLE_NAME="aip-003-bedrock-clarify-role"

echo "=== S3バケット作成 ==="
aws s3api create-bucket \
  --region "$REGION" \
  --bucket "$BUCKET_NAME" \
  --create-bucket-configuration LocationConstraint="$REGION"

aws s3api put-bucket-tagging \
  --region "$REGION" \
  --bucket "$BUCKET_NAME" \
  --tagging 'TagSet=[{Key=Project,Value=aip-study}]'

# レイアウト:
#   s3://<bucket>/capture/     … 02で生成する推論結果(構造化データ)
#   s3://<bucket>/baseline/    … 03で作るベースラインデータ
#   s3://<bucket>/monitoring/  … 04のMonitoring Scheduleの出力先
echo "=== IAMロール作成(SageMaker Clarify Processing/Monitoring Job用) ==="
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "sagemaker.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --tags Key=Project,Value=aip-study

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess

echo "BUCKET_NAME=$BUCKET_NAME"
echo "ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
