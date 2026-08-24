#!/bin/bash
# バイアスドリフトモニタリングの比較基準となる「ベースライン」を作る。
#
# Monitoring Scheduleは「今のキャプチャデータ」と「ベースライン」を比較して
# ドリフト(乖離)を検出する仕組みなので、まずベースラインとなるバイアス分析を
# 1回実行しておく必要がある。ここでは02で生成したバリアントA(素朴なプロンプト)
# のデータを「基準となる分布」として使い、SageMaker Clarify Processing Jobで
# 事前学習/事後学習バイアスメトリクスを計算させる。
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="aip-003-bedrock-clarify-${ACCOUNT_ID}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/aip-003-bedrock-clarify-role"
JOB_NAME="aip-003-clarify-baseline-$(date -u +%Y%m%d%H%M%S)"

# 直近のcaptureファイルをベースライン入力として使う
CAPTURE_KEY=$(aws s3api list-objects-v2 \
  --bucket "$BUCKET_NAME" --prefix "capture/" \
  --query 'sort_by(Contents,&LastModified)[-1].Key' --output text)

# SageMaker Clarify BiasConfig:
#   label_values_or_threshold: premium_recommended=1 を「有利な判定」とみなす
#   facet_name: age_band / gender をそれぞれ公平性の軸として指定
#   facet_values_or_threshold: 基準グループ(比較の起点)を指定
BIAS_CONFIG=$(cat <<'EOF'
{
  "label_values_or_threshold": [1],
  "facet": [
    {"name_or_index": "age_band", "value_or_threshold": ["under35"]},
    {"name_or_index": "gender", "value_or_threshold": ["female"]}
  ],
  "group_variable": "prompt_variant"
}
EOF
)

echo "BIAS_CONFIG (SageMaker Clarify Processorに渡す設定の骨子):"
echo "$BIAS_CONFIG"

# 実際のベースライン計算はSageMaker Clarify Processing Job(コンテナ:
# sagemaker-clarify-processing)として実行する。Python SDKなら
# clarify.SageMakerClarifyProcessor.run_bias() 相当。
# CLIから直接叩く場合は create-processing-job にClarifyコンテナイメージと
# 上記BIAS_CONFIG相当のanalysis_config.jsonをS3経由で渡す形になる
# (パラメータが多いため、実務ではPython SDK経由での実行が一般的)。
echo ""
echo "=== ベースライン分析ジョブ(意図) ==="
echo "aws sagemaker create-processing-job --processing-job-name $JOB_NAME \\"
echo "  --role-arn $ROLE_ARN \\"
echo "  --app-specification ImageUri=<clarify-processing-image-uri> \\"
echo "  --processing-inputs '[{\"InputName\":\"dataset\",\"S3Input\":{\"S3Uri\":\"s3://${BUCKET_NAME}/${CAPTURE_KEY}\",\"LocalPath\":\"/opt/ml/processing/input/data\",\"S3DataType\":\"S3Prefix\",\"S3InputMode\":\"File\"}}]' \\"
echo "  --processing-output-config '{\"Outputs\":[{\"OutputName\":\"analysis\",\"S3Output\":{\"S3Uri\":\"s3://${BUCKET_NAME}/baseline/\",\"LocalPath\":\"/opt/ml/processing/output\"}}]}' \\"
echo "  --tags Key=Project,Value=aip-study"

echo ""
echo "BASELINE_S3_URI=s3://${BUCKET_NAME}/baseline/"
