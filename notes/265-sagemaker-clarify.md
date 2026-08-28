# SageMaker Clarify: バイアス検出と説明可能性

MLパイプライン全体の位置づけは[260-sagemaker-ml-pipeline-overview.md](260-sagemaker-ml-pipeline-overview.md)を参照。

**解決する課題**: モデルの精度指標（Accuracy/F1等）が良くても、「特定の属性グループに対してだけ不利な予測をしていないか」「なぜその予測に至ったのか」は、精度指標だけでは分からない。Clarifyは**バイアス検出**と**説明可能性（Explainability）**を定量的なメトリクスとして算出するサービス（Responsible AIにおける役割の全体像は[31-responsible-ai-core-dimensions.md](31-responsible-ai-core-dimensions.md)参照）。

## 実施タイミングは2段階

（②のEDA段階と④の評価段階の両方に登場する点が試験の狙われどころ）

| タイミング | 呼び方 | 何を見るか |
|------|------|------|
| ②データの前処理と分析（学習前） | Pre-training bias | 学習データ自体に、属性間の偏り（ラベル分布の偏り等）がないか |
| ④モデル評価（学習後） | Post-training bias | 学習済みモデルの**予測結果**に、属性間の偏りが出ていないか |

## 主なバイアスメトリクス

（すべて属性（例: 性別・年代）で分けた**facet**間の差を数値化する）

| 区分 | メトリクス | 何を測るか |
|------|------|------|
| Pre-training | Class Imbalance（CI） | facet間のサンプル数（構成比）の偏り |
| Pre-training | Difference in Proportions of Labels（DPL） | facet間で、正例ラベルの割合がどれだけ異なるか |
| Post-training | Difference in Positive Proportions in Predicted Labels（DPPL） | facet間で、モデルが**予測した**正例の割合がどれだけ異なるか（DPLの予測版） |
| Post-training | Disparate Impact（DI） | facet間の正例予測割合の**比率**（1から離れるほど偏りが大きい） |
| Post-training | Accuracy Difference / Recall Difference | facet間で、正解率・再現率にどれだけ差があるか |

- 個々のメトリクス名を丸暗記するより、「**入力データそのものの偏りを見るのがpre-training（DPL等）、モデルの予測結果の偏りを見るのがpost-training（DPPL/DI等）**」という区別がつけば試験上は十分なことが多い

## 説明可能性（Explainability）

- **SHAP値（SHapley Additive exPlanations）**を用いて、個々の予測に対する**特徴量ごとの寄与度**を算出する。ゲーム理論のShapley値がベースで、「その特徴量があることでモデルの予測がベースラインからどれだけ動いたか」を特徴量単位に分解する
- グローバル（モデル全体でどの特徴量が重要か）とローカル（個々の予測1件について、どの特徴量がどう効いたか）の両方の粒度で確認できる
- 与信審査・与信スコアリングのように「なぜこの予測になったか」の説明責任が求められるユースケースで重要になる

## 主なポイント

- SageMaker Studio上でレポート（Bias Report / Explainability Report）として可視化されるほか、SageMaker Processing Jobとしてパイプラインに組み込み、④の評価ステップで自動実行できる
- 本番運用中の継続監視（Bias Drift / Feature Attribution Drift）は**SageMaker Model Monitor**が担当領域で、ClarifyはそのMonitorが使うベースライン計算・監視ロジックの提供元という関係になる（詳細は[267-sagemaker-mlops-monitoring-pipelines-and-governance.md](267-sagemaker-mlops-monitoring-pipelines-and-governance.md)の「SageMaker Model Monitor」セクション参照）
- Bedrockベースのアプリケーションで「公平性の継続監視」が要件になった場合、Bedrock Model Evaluationだけでは満たせず、Clarifyのバイアスドリフト分析を組み合わせる設計になる。アプリ側でプロンプト・応答・デモグラフィック属性をS3へログ保存し、そのデータをClarifyのバイアスドリフト分析にかけ、結果をCloudWatchメトリクスとして発行する構成が典型（Model MonitorはSageMakerエンドポイントのData Captureに依存しBedrock呼び出しを自動キャプチャできないが、Clarifyの分析ジョブは任意のS3データに実行できるため成立する）。詳細な要件比較は[50-model-evaluation.md](50-model-evaluation.md)、AgentCore Evaluationsとの守備範囲の違いは同ファイルを参照

## 可視化層の選択肢: Amazon Managed Grafana

**これは何か**: OSS（オープンソース）の可視化・ダッシュボードツールである**Grafana**のフルマネージド版。自前でGrafanaサーバーを構築・パッチ適用・スケーリングする運用負荷なしに、使い慣れたGrafana UIとダッシュボード資産（既存のGrafanaダッシュボード定義やプラグインエコシステム）をそのまま使える。

**特徴**

- **マルチデータソース対応**が最大の特徴。CloudWatch、Prometheus、Amazon Timestream、OpenSearch Service、Athena、X-Rayなど、**複数の異なるデータソースを横断して1つのダッシュボードに統合**できる（QuickSightやCloudWatch単体はこの横断統合が主目的ではない）
- SAML/IAM Identity Centerと連携したユーザー・チーム単位のアクセス制御（Workspace単位で管理）
- 秒〜分単位の更新間隔でのリアルタイム性の高い可視化に強く、**SRE/MLOpsエンジニアなど技術者がシステムメトリクスを監視する運用ダッシュボード**用途が主戦場
- 後述のSageMaker AI監視ソリューション群では、「SageMaker Resource Observability with Grafana」（GPU/CPU/メモリ使用率＋コストの可視化）と「LLM Quality Observability with Grafana」（安全性・関連性・トーン等のLLM品質観測）の2ソリューションで採用されている

**Amazon Managed Grafana / Amazon QuickSight / Amazon CloudWatchの比較**

| 観点 | Amazon Managed Grafana | Amazon QuickSight | Amazon CloudWatch |
|---|---|---|---|
| 位置づけ | OSS Grafanaのフルマネージド版。技術者向けの運用・オブザーバビリティダッシュボード | フルマネージドのBI（ビジネスインテリジェンス）・データ可視化サービス | AWSネイティブの運用監視基盤（メトリクス・ログ・アラーム） |
| 得意なデータソース | **複数データソースを横断統合**（CloudWatch、Prometheus、Timestream、OpenSearch、Athena、X-Ray等） | S3/Athena経由のデータレイク、RDS、Redshift等の**構造化データ** | AWSサービスのネイティブメトリクス、カスタムメトリクス、ログ |
| 得意な用途 | GPU/CPU使用率・レイテンシ・スループット等、**システムメトリクスのリアルタイム運用監視** | 経営層・ビジネスユーザー向けの**ガバナンスダッシュボード**、トレンド分析、定期レポート | **しきい値監視・アラーム発行**、AWSリソースの標準監視、シンプルなダッシュボード |
| リアルタイム性 | 高い（秒〜分単位） | 中〜低い（SPICEでのキャッシュ・バッチ更新が中心） | 高い（1分/5分間隔が基本） |
| 主な利用者 | SRE、MLOpsエンジニア、インフラ担当者 | 経営層、ビジネスユーザー、データアナリスト | 開発者、運用担当者 |
| SageMaker監視ソリューションでの役割 | リソース観測（GPU/CPU/コスト）、LLM品質観測 | バイアス・データドリフト等のガバナンスダッシュボード | 全ソリューション共通の基盤（メトリクス発行・アラーム）。ほぼ全ての構成で土台として使われる |

**使い分けの基本方針**: Amazon CloudWatchはどの監視ソリューションでも共通の土台（メトリクス・アラームの発行先）として使われる。その上に可視化層を足すかどうか・何を足すかは要件次第で、「複数データソースを跨いだ技術者向けリアルタイム運用ダッシュボードが欲しい」ならAmazon Managed Grafana、「経営層向けのガバナンス・トレンドレポートが欲しい」ならAmazon QuickSight、「アラームと簡易ダッシュボードだけで十分」ならCloudWatch単体、という3択で考える。**3つは競合ではなく、CloudWatchが基盤、Grafana/QuickSightはその上に載せる可視化層の選択肢**という関係。

## 提供状況の変更（2026年7月30日〜新規顧客への提供終了）

- AWS公式ドキュメントの告知により、SageMaker Clarifyは**2026年7月30日以降、新規顧客が新たに利用開始することができなくなる**（[Clarify availability change](https://docs.aws.amazon.com/sagemaker/latest/dg/clarify-availability-change.html)）。**既存に利用していた顧客は従来通り利用を継続できる**（サービス終了と新規提供終了は別物）。AWSはセキュリティ・可用性面の改善投資は継続するが、新機能追加は行わない方針
- 同時に対象となっているSageMaker AI機能は、Clarifyの他にMechanical Turk、Ground Truth、Augmented AI（A2I）、Studio Lab、**Model Monitor**、Debugger、Role Manager、Geospatial、Profilerの合計10機能（Ground Truth Plusは2026年6月30日に既にサポート終了済み）
- この設問自体は現行のAWS試験問題としてSageMaker Clarifyのバイアスドリフトモニタリングを正解として扱っており、当面の試験知識としては「Bedrockで足りない継続的な公平性監視は、SageMaker Clarifyで補う」という理解で問題ない
- AWSが提示する代替手段
  - **バイアス検出**: pre-training/post-trainingのバイアスメトリクス（DPL、DI等）は公開された標準的な計算式であるため、pandas/scikit-learnで自前実装する
  - **説明可能性（SHAP値）**: Clarify自体がSHAPライブラリを内部で使っているため、SHAPライブラリを直接利用すれば同等の結果が得られる
  - **継続的なバイアス・特徴量寄与度ドリフト監視**: AWSがGitHub（`aws-samples`組織）で公開しているオープンソースの監視ソリューション（SageMaker AI MLflow Apps + Evidently AI）が土台で、Amazon CloudWatchでのメトリクス・アラート発行と組み合わせるのが基本形。**Amazon QuickSightは必須ではない**——AWSが公開する7つの参照実装のうちQuickSightのガバナンスダッシュボードを使うのは「Real-Time Inference Monitoring with QuickSight Dashboards」の1つだけで、他はSNSのみの軽量通知（ダッシュボードなし）やAmazon Managed Grafanaを使う構成もある。「経営層向けの継続的なガバナンスダッシュボードが要件に含まれるか」で選ぶ、CloudWatch以外の可視化層の選択肢の一つという位置づけ（QuickSightだけで完結させない構成も十分成立する）
  - **基盤モデル（LLM）評価（FMEval機能）**: `fmeval`ライブラリを直接利用するか、**Amazon Bedrock Evaluations**（マネージドサービス）に置き換える。ランタイムの有害コンテンツ検知は**Amazon Bedrock Guardrails**が担う。ただしBedrock EvaluationsはあくまでFM評価用であり、表形式データ（tabular/古典的ML）のバイアス検出・説明可能性の代替にはならない点に注意
- 実務上は、上記のAWSが提示する代替手段（**SageMaker AI基盤上で動くオープンソースの監視ソリューション**＝SageMaker AI MLflow Apps + Evidently AI、**Amazon CloudWatch**によるメトリクス・アラート発行、の組み合わせ）への段階的な移行を見据える必要がある。正確には**「SageMaker AI基盤上でEvidently AI等のOSSツールを組み合わせて自前実装する」**という中身まで押さえておくと、実務・試験の両方で誤解しにくい（単なる「オープンソースサービス」ではなく、AWSマネージドサービス群＋OSSライブラリの組み合わせという構成）

## 試験でのひっかけポイント整理

- 「SageMaker Clarifyのバイアス検出はモデル学習後にしか使えない」→ 誤り。Clarifyは学習前（pre-training bias、EDA段階でのクラス不均衡等の検出）と学習後（post-training bias）の両方をカバーする
