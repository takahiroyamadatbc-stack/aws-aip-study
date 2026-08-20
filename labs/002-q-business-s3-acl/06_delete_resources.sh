#!/usr/bin/env bash
# 作成したリソースを逆順に削除する。
set -euo pipefail

BUCKET="aip-002-q-business-s3-acl"

if [ -f .lab002-ids.env ]; then
  # shellcheck source=.lab002-ids.env
  source .lab002-ids.env

  aws qbusiness delete-data-source \
    --application-id "${APP_ID}" --index-id "${INDEX_ID}" --data-source-id "${DATA_SOURCE_ID}"
  aws qbusiness delete-index \
    --application-id "${APP_ID}" --index-id "${INDEX_ID}"
  aws qbusiness delete-application \
    --application-id "${APP_ID}"

  rm -f .lab002-ids.env
fi

INSTANCE_ARN=$(aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text)
IDENTITY_STORE_ID=$(aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text)
for group in SalesGroup HRGroup FinanceGroup; do
  GROUP_ID=$(aws identitystore get-group-id \
    --identity-store-id "${IDENTITY_STORE_ID}" \
    --alternate-identifier "{\"UniqueAttribute\":{\"AttributePath\":\"displayName\",\"AttributeValue\":\"${group}\"}}" \
    --query 'GroupId' --output text 2>/dev/null || true)
  if [ -n "${GROUP_ID:-}" ]; then
    aws identitystore delete-group \
      --identity-store-id "${IDENTITY_STORE_ID}" --group-id "${GROUP_ID}"
  fi
done

aws s3 rm "s3://${BUCKET}" --recursive
aws s3api delete-bucket --bucket "${BUCKET}"

echo "片付け完了"
