# SageMaker AI: モデル評価 ― Experiments とModel Registry

MLパイプライン全体の位置づけは[260-sagemaker-ml-pipeline-overview.md](260-sagemaker-ml-pipeline-overview.md)を参照。バイアス検出・説明可能性（SageMaker Clarify）は[265-sagemaker-clarify.md](265-sagemaker-clarify.md)を参照。

## モデル評価の概要

- **指標**: 分類はAccuracy/Precision/Recall/F1/AUC-ROC/混同行列、回帰はRMSE/MAE/R²。指標選定はクラス不均衡の有無等、②のEDAで把握した内容に依存する
- **汎化性能の検証**: train/validation/testの分割、交差検証（Cross Validation）で過学習・未学習を確認する点はローカルと同様

AWS特有の評価関連サービスは以下。

| サービス | 役割 |
|------|------|
| SageMaker Experiments | 複数のトレーニングジョブ（トライアル）の指標・パラメータを記録し、実験間で比較・追跡する |
| SageMaker Clarify | **学習後バイアス（post-training bias）**の検出と、SHAP値による**説明可能性（特徴量重要度）**の算出（詳細は[265-sagemaker-clarify.md](265-sagemaker-clarify.md)） |
| SageMaker Model Registry | 評価済みモデルのバージョン管理・承認ワークフロー（承認されたモデルのみ⑤のデプロイに進める、といったゲート運用に使う） |
| SageMaker Model Cards | 評価結果・意図した用途・既知の制約等をドキュメント化する成果物 |

## SageMaker Experiments

**解決する課題**: ハイパーパラメータ・前処理・アルゴリズムを変えながら何度も試行を繰り返すと、「どの設定がどの結果を出したか」を手元のメモやファイル名運用で管理するのは破綻しやすい。Experimentsは、この**試行錯誤（実験）の記録・比較・再現性確保**を目的とした実験管理機能。

**構成要素**

| 概念 | 内容 |
|------|------|
| Experiment | 検証したいテーマ・プロジェクト単位の最上位グループ（例:「不正検知モデルv2の検証」） |
| Run | Experiment配下の個々の試行。1回のトレーニングジョブ・Processingジョブ等に対応し、その回のハイパーパラメータ・メトリクス・入出力アーティファクトを保持する（旧SDKでの Trial／Trial Component に相当する概念が現行では Run に統合されている） |

**主なポイント**

- **自動トラッキング**: SageMaker Training Jobs・Processing Jobs・Pipelines・Automatic Model Tuning（HPO）の各ジョブと統合されており、明示的な記録コードを書かなくてもハイパーパラメータ・評価メトリクス・生成物（モデル、データセット）を自動収集できる（Python SDKで独自の`log_metric`等を使った手動記録も可能）
- **比較・可視化**: SageMaker Studio内のExperiments UIで複数Runを一覧・並べて比較でき、メトリクスの推移グラフやパラメータごとの性能差を確認できる
- **HPOとの連携**: Automatic Model Tuningジョブが生成する多数のトライアルも、それぞれ1つのRunとして自動的にExperiment配下に記録される
- **系譜追跡（Lineage）**: どのデータセット・前処理コード・アルゴリズムから、どのモデルが生成されたかを追跡できる（モデルの再現性・監査対応の観点でも有用）

## SageMaker Model Registry

**解決する課題**: 学習・評価を繰り返すと多数のモデルバージョンが生成されるが、これを個別管理すると「今どのバージョンが本番稼働中か」「どのバージョンがレビュー・承認済みか」が分からなくなる。Model Registryは、モデルを**カタログとしてバージョン管理し、本番デプロイ前の承認ゲートを設ける**ための仕組み。

**構成要素**

| 概念 | 内容 |
|------|------|
| Model Package Group | 同一のユースケースに対する複数バージョンのモデルをまとめる論理グループ（例:「不正検知モデル」というグループの中にv1, v2, v3...が並ぶ） |
| Model Package（Model Version） | Model Package Group配下の個々のバージョン。モデルアーティファクト（S3上のモデルファイル）、推論コンテナイメージ、評価メトリクス、**承認ステータス**などを保持する |

**承認ステータス（Approval Status）**

| ステータス | 意味 |
|------|------|
| PendingManualApproval | デフォルト状態。レビュー・承認待ちで、まだデプロイ可能とは見なされない |
| Approved | 承認済み。⑤のデプロイに進めてよいモデル |
| Rejected | 却下済み。デプロイ対象から外れる |

**主なポイント**

- **Pipelinesとの統合**: SageMaker PipelinesのRegisterModel Stepから、パイプライン実行で生成されたモデルを自動的にModel Registryへ登録できる（詳細は[267-sagemaker-mlops-monitoring-pipelines-and-governance.md](267-sagemaker-mlops-monitoring-pipelines-and-governance.md)）
- **CI/CDのゲートとして機能**: ステータスがApprovedに変わったことをEventBridgeで検知し、本番デプロイのパイプラインを自動起動する、といったガバナンス上のゲート（人間のレビュー承認、またはCondition Stepによる自動条件判定のいずれとも組み合わせられる）として使うのが典型パターン
- **モデル系譜との連携**: どの学習ジョブ・データセット・コードから生成されたモデルかをLineage情報と紐付けて追跡できる
- **アカウント間共有**: Model Packageは別のAWSアカウントと共有可能で、開発アカウントで学習・登録したモデルを本番アカウントでデプロイする、といったマルチアカウント構成のMLOpsで使われる

デプロイ時のバージョン切り替え・トラフィックシフト戦略は[201-ai-service-deployment-strategies.md](201-ai-service-deployment-strategies.md)を参照。

## 試験でのひっかけポイント整理

- 「SageMaker Model Registryはモデルの精度を自動で改善してくれる」→ 誤り。Model Registryはバージョン管理・承認ワークフローの仕組みであり、精度改善（再学習・チューニング）そのものは行わない
- 「SageMaker Experimentsはモデルの精度を自動で向上させる機能である」→ 誤り。Experimentsは試行（ハイパーパラメータ・メトリクス・アーティファクト）の記録・比較・追跡を行う実験管理機能であり、チューニング自体（探索）を行うのはAutomatic Model Tuningの役割
- 「SageMaker Model Registryに登録されたモデルは自動的に本番デプロイされる」→ 誤り。登録直後はデフォルトでPendingManualApproval（承認待ち）状態であり、Approvedへのステータス変更（人間のレビューまたは自動条件判定）を経て初めてデプロイのゲートを通過する
