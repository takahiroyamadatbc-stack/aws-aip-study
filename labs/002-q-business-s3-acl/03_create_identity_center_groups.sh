#!/usr/bin/env bash
# 検証用のIAM Identity Centerグループ（部門ごと）を作成する。
# 前提: アカウントでIAM Identity Centerが既に有効化されていること。
set -euo pipefail

INSTANCE_ARN=$(aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text)
IDENTITY_STORE_ID=$(aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text)

echo "IAM Identity Center Instance ARN: ${INSTANCE_ARN}"
echo "Identity Store ID: ${IDENTITY_STORE_ID}"

for group in SalesGroup HRGroup FinanceGroup; do
  aws identitystore create-group \
    --identity-store-id "${IDENTITY_STORE_ID}" \
    --display-name "${group}" \
    --description "aip-study lab002: ${group}"
done

echo "作成したグループ: SalesGroup, HRGroup, FinanceGroup"
echo "acl-config.sample.json の Name はこのグループの表示名（DisplayName）と一致させる。"
