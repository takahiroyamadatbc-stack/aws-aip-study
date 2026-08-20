#!/usr/bin/env bash
# Q Businessアプリケーション/インデックス/リトリーバーを作成し、
# S3V2データソースを accessControlConfiguration.aclConfigurationFilePath 付きで作成する。
#
# 注意: --role-arn には、S3読み取り権限とQ Businessサービスへの信頼ポリシーを持つ
#       既存のIAMロールARNを指定する必要がある（本Labではロール作成は割愛）。
set -euo pipefail

BUCKET="aip-002-q-business-s3-acl"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
INSTANCE_ARN=$(aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/aip-002-qbusiness-service-role"  # 事前に作成しておく

# 1. アプリケーション作成（IAM Identity Center連携）
APP_ID=$(aws qbusiness create-application \
  --display-name "aip-002-q-business-s3-acl" \
  --identity-center-instance-arn "${INSTANCE_ARN}" \
  --role-arn "${ROLE_ARN}" \
  --tags Key=Project,Value=aip-study \
  --query 'applicationId' --output text)
echo "Application ID: ${APP_ID}"

# 2. インデックス作成
INDEX_ID=$(aws qbusiness create-index \
  --application-id "${APP_ID}" \
  --display-name "aip-002-index" \
  --tags Key=Project,Value=aip-study \
  --query 'indexId' --output text)
echo "Index ID: ${INDEX_ID}"

# 3. リトリーバー作成（ネイティブインデックスを使用）
aws qbusiness create-retriever \
  --application-id "${APP_ID}" \
  --type NATIVE_INDEX \
  --display-name "aip-002-retriever" \
  --configuration "{\"nativeIndexConfiguration\":{\"indexId\":\"${INDEX_ID}\"}}" \
  --tags Key=Project,Value=aip-study

# 4. S3V2データソース作成
#    ここが本Labの検証ポイント: accessControlConfiguration.aclConfigurationFilePath に
#    単一のACL設定ファイル（02で配置したもの）を指定する。部門ごとに複数ファイルを
#    指定するパラメータは存在しない（配列ではなく単一の文字列プロパティ）。
CONFIGURATION=$(cat <<JSON
{
  "type": "S3V2",
  "connectionConfiguration": {
    "bucketName": "${BUCKET}",
    "bucketOwnerAccountId": "${ACCOUNT_ID}"
  },
  "filterConfiguration": {
    "inclusionPrefixes": ["dept-sales/", "dept-hr/", "dept-finance/"],
    "exclusionPrefixes": ["config/"]
  },
  "accessControlConfiguration": {
    "aclConfigurationFilePath": "config/acl-config.json"
  }
}
JSON
)

DATA_SOURCE_ID=$(aws qbusiness create-data-source \
  --application-id "${APP_ID}" \
  --index-id "${INDEX_ID}" \
  --display-name "aip-002-s3-datasource" \
  --configuration "${CONFIGURATION}" \
  --tags Key=Project,Value=aip-study \
  --query 'dataSourceId' --output text)
echo "Data Source ID: ${DATA_SOURCE_ID}"

# 後続スクリプトで使う値をファイルに退避
cat > .lab002-ids.env <<ENV
APP_ID=${APP_ID}
INDEX_ID=${INDEX_ID}
DATA_SOURCE_ID=${DATA_SOURCE_ID}
ENV
echo "IDを .lab002-ids.env に保存した"
