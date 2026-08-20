#!/usr/bin/env bash
# S3バケットを作成し、部門ごとのプレフィックスにサンプルドキュメントを配置する。
set -euo pipefail

BUCKET="aip-002-q-business-s3-acl"
REGION="${AWS_REGION:-us-east-1}"

aws s3api create-bucket \
  --bucket "${BUCKET}" \
  --region "${REGION}" \
  $( [ "${REGION}" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=${REGION}" )

aws s3api put-bucket-tagging \
  --bucket "${BUCKET}" \
  --tagging 'TagSet=[{Key=Project,Value=aip-study}]'

# 各部門のプレフィックスにダミードキュメントを配置する。
# オブジェクト名（キー）にそのまま部門プレフィックスが含まれる想定（問題文の前提）。
for dept in dept-sales dept-hr dept-finance; do
  echo "${dept} department internal memo (sample content for AIP lab)." \
    > "/tmp/${dept}-memo.txt"
  aws s3 cp "/tmp/${dept}-memo.txt" "s3://${BUCKET}/${dept}/memo.txt"
  rm -f "/tmp/${dept}-memo.txt"
done

echo "作成したバケット: s3://${BUCKET}"
echo "配置したプレフィックス: dept-sales/ dept-hr/ dept-finance/"
