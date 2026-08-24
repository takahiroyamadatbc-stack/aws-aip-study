#!/bin/bash
# 04で発行されるカスタムメトリクスに対して、
# 「デモグラフィックグループ間で15%を超える不一致」を検知するアラームと、
# 「2つのプロンプトアプローチを比較する週次レポート」用のダッシュボードを作る。
#
# 週次レポートはQuickSightではなくCloudWatchダッシュボードで構成する
# (notes/50-model-evaluation.mdの整理どおり、QuickSightは必須ではない)。
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="AIPStudy/BedrockFairness"
DASHBOARD_NAME="aip-003-bedrock-fairness-weekly"

echo "=== CloudWatchアラーム: DPPL(facet間の予測正例割合の差)が0.15を超えたら通知 ==="
aws cloudwatch put-metric-alarm \
  --region "$REGION" \
  --alarm-name "aip-003-fairness-dppl-threshold" \
  --namespace "$NAMESPACE" \
  --metric-name "bias_metric_DPPL" \
  --dimensions Name=Facet,Value=age_band Name=PromptVariant,Value=A \
  --statistic Maximum \
  --period 3600 \
  --evaluation-periods 1 \
  --threshold 0.15 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --tags Key=Project,Value=aip-study

echo "=== CloudWatchダッシュボード: プロンプトA/Bのバイアスメトリクス週次比較 ==="
DASHBOARD_BODY=$(cat <<EOF
{
  "widgets": [
    {
      "type": "metric",
      "x": 0, "y": 0, "width": 12, "height": 6,
      "properties": {
        "title": "DPPL (age_band facet) - Variant A vs B",
        "metrics": [
          ["$NAMESPACE", "bias_metric_DPPL", "Facet", "age_band", "PromptVariant", "A"],
          ["$NAMESPACE", "bias_metric_DPPL", "Facet", "age_band", "PromptVariant", "B"]
        ],
        "period": 604800,
        "stat": "Average",
        "region": "$REGION",
        "view": "timeSeries"
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 0, "width": 12, "height": 6,
      "properties": {
        "title": "DPPL (gender facet) - Variant A vs B",
        "metrics": [
          ["$NAMESPACE", "bias_metric_DPPL", "Facet", "gender", "PromptVariant", "A"],
          ["$NAMESPACE", "bias_metric_DPPL", "Facet", "gender", "PromptVariant", "B"]
        ],
        "period": 604800,
        "stat": "Average",
        "region": "$REGION",
        "view": "timeSeries"
      }
    }
  ]
}
EOF
)

aws cloudwatch put-dashboard \
  --region "$REGION" \
  --dashboard-name "$DASHBOARD_NAME" \
  --dashboard-body "$DASHBOARD_BODY"

echo "DASHBOARD_NAME=$DASHBOARD_NAME"
echo "→ period=604800(7日)でウィジェットを集計させることで週次比較レポートに相当する見え方にしている"
