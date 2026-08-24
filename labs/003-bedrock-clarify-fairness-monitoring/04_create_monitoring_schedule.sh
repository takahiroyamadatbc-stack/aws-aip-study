#!/bin/bash
# 「継続的なバイアスドリフト監視」をどう構成するかの核心部分。
#
# 重要な制約(このLabの仮説の検証ポイント):
# SageMaker Model MonitorのネイティブなMonitoring Schedule(ModelBiasMonitor)は
# ジョブ定義(create-model-bias-job-definition)に `EndpointName` を指定する設計で、
# 「SageMakerエンドポイントのData Capture」と密結合している。
# Bedrockの呼び出しはSageMakerエンドポイントを経由しないため、
# このネイティブなMonitoring Scheduleをそのまま向けることはできない
# (notes/22-bedrock-knowledge-bases-and-agents.mdの
#  「SageMaker Model MonitorはBedrock呼び出しに直接は適用できない」と同じ制約)。
#
# そのため実務では、SageMaker Clarifyの「バイアス分析Processing Job」を
# EventBridge Schedulerで定期実行し、結果(analysis.json)をLambdaでパースして
# CloudWatchへ明示的にPutMetricDataする、という自前のスケジューリング構成が必要になる。
# 問題文の正解解説は「Monitoring Scheduleを設定してCloudWatchに発行」と簡略化して
# 書かれているが、Bedrock文脈では実質この構成を指すと解釈するのが技術的に正確。
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="aip-003-bedrock-clarify-${ACCOUNT_ID}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/aip-003-bedrock-clarify-role"
SCHEDULE_NAME="aip-003-bias-monitoring-schedule"
LAMBDA_NAME="aip-003-clarify-metric-publisher"

echo "=== (参考)ネイティブMonitoring Scheduleが要求する形(Bedrockには使えない) ==="
echo "aws sagemaker create-model-bias-job-definition \\"
echo "  --job-definition-name aip-003-bias-job-def \\"
echo "  --model-bias-app-specification ImageUri=<clarify-processing-image-uri> \\"
echo "  --model-bias-job-input '{\"EndpointInput\":{\"EndpointName\":\"<sagemaker-endpoint>\", ...}}'  # ← Bedrockにはこれが存在しない"
echo ""

echo "=== 実際に組む構成: EventBridge Scheduler → Lambda → Clarify Processing Job → CloudWatch ==="
echo "1. Lambda(${LAMBDA_NAME}): 02と同じ形でBedrockを呼び出し直近データをS3へキャプチャ"
echo "   → SageMaker Clarify Processing Job(03と同じ analysis_config)を起動"
echo "   → 出力された analysis.json の bias_metrics を読み、facet(age_band/gender)ごとの"
echo "     DPL/DPPL/DIをパースする"
echo "   → cloudwatch:PutMetricData で Namespace=AIPStudy/BedrockFairness,"
echo "     MetricName=bias_metric_DPPL, Dimensions=[Facet=age_band,PromptVariant=A] 等として発行"
echo ""

# EventBridge Schedulerでの定期実行設定(1時間ごと。SageMaker Model Monitor自体の
# 最短間隔も1時間なので、それに合わせている)
aws scheduler create-schedule \
  --name "$SCHEDULE_NAME" \
  --schedule-expression "rate(1 hour)" \
  --flexible-time-window '{"Mode": "OFF"}' \
  --target "{
    \"Arn\": \"arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${LAMBDA_NAME}\",
    \"RoleArn\": \"${ROLE_ARN}\"
  }"

echo "SCHEDULE_NAME=$SCHEDULE_NAME"
echo "→ 1時間ごとにClarifyバイアス分析→CloudWatchメトリクス発行のLambdaを起動する"
