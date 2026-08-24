# 003 Bedrock × SageMaker Clarify × CloudWatch によるレコメンドの公平性継続監視

## 問題
<!-- 模擬試験 問46 -->
ある小売企業が、Amazon Bedrockを使用したジェネレーティブAI（GenAI）の商品レコメンデーションアプリケーションを運用している。このアプリケーションは、閲覧履歴とデモグラフィック情報に基づいて顧客に商品を提案する。企業は、2つのプロンプトアプローチ間でレコメンデーションにおけるバイアスを検出・測定するために、複数のデモグラフィックグループにわたる公平性評価を実装する必要がある。企業は継続的（定期的）に公平性メトリクスを収集・監視したいと考えている。デモグラフィックグループ間で15%を超える不一致が公平性メトリクスに表れた場合にアラートを受け取る必要がある。また、2つのプロンプトアプローチのパフォーマンスを比較する週次レポートを受け取る必要がある。
これらの要件をカスタム開発の労力を最小限に抑えて満たすソリューションはどれか。

- 正解: Amazon SageMaker Clarifyのバイアスドリフトモニタリング機能を設定し、キャプチャしたモデル入出力を分析してバイアスメトリクスを定期的にAmazon CloudWatchに発行する。SageMaker Clarifyが発行するバイアスメトリクスにCloudWatchアラームを設定し、週次レポート用のCloudWatchダッシュボードを構成する。
- 誤答（選んだ選択肢）: Amazon Bedrockモデル評価ジョブを作成して2つのプロンプトバリアント間の公平性を比較する。Amazon CloudWatchでモデル呼び出しログを有効にする。各デモグラフィックグループのディメンションを持つInvocationsIntervenedメトリクスにCloudWatchアラームを設定する。

## 選んだ答えと理由
Bedrockモデル評価ジョブの選択肢を選んで不正解。

「Bedrock Model Evaluationでモデル/プロンプトの回答品質は評価できるが、デモグラフィックグループ間の公平性・バイアスの継続監視まではできない」という所までは正しく切り分けられていたが、そこから先の「では何を使えば継続監視できるのか」でBedrockの文脈にSageMakerのサービスを組み合わせる発想が出てこなかった。BedrockとSageMakerを別世界のサービスとして捉えてしまい、「Bedrockアプリケーションで足りない機能をSageMaker側の機能で補う」という設計パターンが整理できていなかったのが根本原因。

## 誤答の型
知識不足（Bedrock Model Evaluationの守備範囲の誤解）に加えて、**実際に手を動かさないと確定しない実装レベルの疑問**が残る誤答。具体的には以下2点がLab化のポイント。

1. Bedrockの呼び出しをSageMaker Clarifyの入力（表形式データ）にどう変換してキャプチャするか
2. 「バイアスドリフトモニタリング（Monitoring Schedule）」を、SageMakerエンドポイントを持たないBedrockアプリケーションに対してどう構成するか

## 仮説
- BedrockのInvokeModel/Converse呼び出しには、SageMakerエンドポイントのData Captureに相当する「呼び出しを自動でS3にキャプチャする」ネイティブ機能が存在しない。そのため、プロンプト・応答・デモグラフィック属性をS3へ保存する処理は**アプリケーション側で明示的に実装する必要がある**
- SageMaker Clarifyのバイアス分析は、自然文のレコメンド結果をそのまま食べられない。facet（デモグラフィック属性）列とlabel（推薦結果）列を持つ**表形式データへの変換が前処理として必須**になる
- SageMaker Model MonitorのネイティブなMonitoring Schedule（`create-model-bias-job-definition` + `create-monitoring-schedule`）は、ジョブ定義に`EndpointName`を指定する設計で**SageMakerエンドポイントのData Captureと密結合**している。Bedrockの呼び出しはSageMakerエンドポイントを経由しないため、**このネイティブなMonitoring Scheduleをそのまま向けることはできない**と考えられる（[notes/22-bedrock-knowledge-bases-and-agents.md](../../notes/22-bedrock-knowledge-bases-and-agents.md)の「SageMaker Model MonitorはBedrock呼び出しに直接は適用できない」と同じ制約）
- したがって実務では、SageMaker Clarifyの**バイアス分析Processing Job**をEventBridge Scheduler等で定期実行し、結果をLambdaでパースしてCloudWatchへ`PutMetricData`する、という**自前のスケジューリング構成**が必要になる。問題文の正解解説「Monitoring Scheduleを設定してCloudWatchに発行」は、Bedrock文脈では実質この構成を指すと解釈するのが技術的に正確
- 週次レポートはAmazon QuickSightではなく**CloudWatchダッシュボード**（period=604800秒で集計）で構成できる（[notes/50-model-evaluation.md](../../notes/50-model-evaluation.md)で整理した通りQuickSightは必須ではない）

## 検証
実機デプロイは行わず、コードの意図と期待される挙動として整理する。

1. [01_setup_s3_and_role.sh](01_setup_s3_and_role.sh)
   バイアス分析の入出力を置くS3バケットと、SageMaker Clarify Processing/Monitoring Job用のIAMロールを作る。

2. [02_invoke_bedrock_and_capture.sh](02_invoke_bedrock_and_capture.sh)
   6件の合成顧客プロファイル（age_band/gender/browsing_category）に対し、プロンプトバリアントA（素朴な指示）とB（公平性を明示的に指示）でBedrock Claudeを呼び出す。応答をJSON構造化させて`premium_recommended`（0/1）を抽出し、facet列・label列を持つCSVとしてS3へキャプチャする。**ここがBedrockにData Captureが存在しないことの具体的な埋め合わせ実装**。

3. [03_create_bias_baseline.sh](03_create_bias_baseline.sh)
   バリアントAのキャプチャデータを基準として、SageMaker ClarifyのBiasConfig（facet=age_band/gender、label=premium_recommended）を定義し、ベースラインとなるバイアス分析ジョブの実行イメージを示す。

4. [04_create_monitoring_schedule.sh](04_create_monitoring_schedule.sh)
   ネイティブなMonitoring Scheduleが`EndpointName`を要求しBedrockには使えないことを明示した上で、代替として**EventBridge Scheduler → Lambda（Bedrock呼び出し＋Clarify Processing Job起動＋CloudWatch発行）**という自前のスケジューリング構成を組む。

5. [05_setup_cloudwatch_alarm_dashboard.sh](05_setup_cloudwatch_alarm_dashboard.sh)
   `bias_metric_DPPL`が0.15を超えたら発火するCloudWatchアラームと、プロンプトA/Bのバイアスメトリクスを週次集計で並べるCloudWatchダッシュボードを作る。

6. [06_delete_all.sh](06_delete_all.sh)
   検証後の片付け（S3・IAMロール・EventBridge Scheduler・CloudWatchアラーム/ダッシュボード）。

## 結論（1行）
Bedrockアプリケーションの継続的な公平性監視は、Bedrock自体にはData Captureもネイティブなドリフト監視機能もないため、アプリ側でBedrockの入出力を構造化データとしてS3にキャプチャし、SageMaker Clarifyのバイアス分析をEventBridge Scheduler等で定期実行してCloudWatchへメトリクス発行する「自前のスケジューリング構成」で実現する必要がある（ネイティブなMonitoring ScheduleはSageMakerエンドポイント専用でBedrockには直接使えない）。

## 片付け
実機デプロイを行っていないため対象リソースなし。実行した場合は
[06_delete_all.sh](06_delete_all.sh) を実行し、
`aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=aip-study` で残骸がないことを確認する。
