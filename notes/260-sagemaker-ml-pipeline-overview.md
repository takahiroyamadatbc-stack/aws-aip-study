# Amazon SageMaker AI と機械学習パイプライン概要

SageMaker AI関連のノートは、MLパイプラインの段階ごとに260番台の複数ファイルへ分割している。このノートは全体像のハブページで、機能ごとの詳細は各リンク先を参照。

## 機能索引

このノートに登場するSageMaker関連の機能・サービスを、MLパイプラインのどの段階で使うかで一覧化する。詳細は各段階のノート、またはリンク先を参照。

| サービス・機能 | 役割 | 登場する段階 | 詳細ノート |
|---|---|---|---|
| **SageMaker Ground Truth** | データラベリング（アノテーション）。人手＋Active Learningによる自動ラベリング | ①データ収集 | [261](261-sagemaker-data-collection-and-preparation.md) |
| **SageMaker Ground Truth Plus** | ラベリングチーム運用までAWSが担うフルマネージド版Ground Truth | ①データ収集 | [261](261-sagemaker-data-collection-and-preparation.md) |
| **SageMaker Data Wrangler** | GUI/ノーコードでのデータ探索（EDA）・前処理の試行錯誤 | ②前処理と分析 | [261](261-sagemaker-data-collection-and-preparation.md) |
| **SageMaker Processing** | コードベースの前処理・後処理・評価ジョブをスケール実行 | ②前処理と分析／④モデル評価 | [261](261-sagemaker-data-collection-and-preparation.md) |
| **SageMaker Feature Store** | 特徴量の一元管理（Online Store＝低レイテンシ推論用、Offline Store＝学習・分析用） | ②前処理と分析 | [262](262-sagemaker-feature-store.md) |
| **SageMaker Clarify**（※1） | バイアス検出（pre-training／post-training）、SHAP値による説明可能性 | ②前処理と分析（pre-training bias）／④モデル評価（post-training bias、Explainability） | [265](265-sagemaker-clarify.md) |
| **SageMaker Automatic Model Tuning（HPO）** | ハイパーパラメータの自動探索（Grid/Random/Bayesian/Hyperband） | ③モデルトレーニング | [263](263-sagemaker-training-and-tuning.md) |
| **SageMaker Experiments** | トライアル（Run）ごとのハイパーパラメータ・メトリクス・成果物の記録・比較 | ③トレーニング／④評価 | [264](264-sagemaker-experiments-and-model-registry.md) |
| **SageMaker Model Registry** | モデルのバージョン管理・承認ステータス（Pending/Approved/Rejected）によるデプロイゲート | ④モデル評価〜⑤デプロイ | [264](264-sagemaker-experiments-and-model-registry.md) |
| **SageMaker Model Cards** | モデルの目的・評価結果・既知の制約のドキュメント化 | ④モデル評価 | [264](264-sagemaker-experiments-and-model-registry.md) |
| **SageMaker Endpoint** | リアルタイム推論のマネージドホスティング（常時起動） | ⑤デプロイと推論 | [266](266-sagemaker-deployment-and-inference.md) |
| **SageMaker Batch Transform** | バッチ推論（ジョブ実行中のみ課金） | ⑤デプロイと推論 | [266](266-sagemaker-deployment-and-inference.md) |
| **SageMaker Neo + AWS IoT Greengrass** | エッジデバイス向けのモデルコンパイル・配布 | ⑤デプロイと推論 | [266](266-sagemaker-deployment-and-inference.md) |
| **SageMaker Inference Recommender** | デプロイ前の負荷テストによるインスタンスタイプ選定 | ⑤デプロイと推論（デプロイ前） | [266](266-sagemaker-deployment-and-inference.md) |
| **AWS Compute Optimizer** | 稼働中リソース（SageMakerエンドポイント含む全AWSリソース）の継続的なrightsizing | ⑤デプロイと推論（デプロイ後） | [266](266-sagemaker-deployment-and-inference.md) |
| **SageMaker Model Monitor**（※1） | 本番稼働中のドリフト検知（Data Quality／Model Quality／Bias Drift／Feature Attribution Drift） | 運用（MLOpsのCT起点） | [267](267-sagemaker-mlops-monitoring-pipelines-and-governance.md) |
| **SageMaker Pipelines** | 前処理〜デプロイの一連のワークフローをDAGとしてコード定義・自動実行 | 運用（MLOpsのCI/CD/CTの中核） | [267](267-sagemaker-mlops-monitoring-pipelines-and-governance.md) |
| **SageMaker Projects** | CodePipeline/CodeBuild等と統合したCI/CDのMLOpsテンプレート | 運用（MLOps） | [267](267-sagemaker-mlops-monitoring-pipelines-and-governance.md) |
| **SageMaker Role Manager**（※1） | ペルソナ別の最小権限IAM実行ロールをウィザードで作成 | 運用（アクセス管理・ガバナンス） | [267](267-sagemaker-mlops-monitoring-pipelines-and-governance.md) |

（※1）2026年7月30日以降、新規顧客への提供を終了（既存顧客は継続利用可）。詳細は各ノート内の「提供状況の変更」を参照

## MLパイプラインの流れ

機械学習のワークフローは、以下の5段階を順に進む。

```
① データ収集 → ② データの前処理と分析 → ③ モデルトレーニング → ④ モデル評価 → ⑤ モデルのデプロイと推論
```

| # | 段階 | 概要 | 詳細ノート |
|---|------|------|------|
| ① | データ収集 | Ground Truthによるラベリング | [261-sagemaker-data-collection-and-preparation.md](261-sagemaker-data-collection-and-preparation.md) |
| ② | データの前処理と分析 | EDA、クレンジング、エンコーディング、特徴量エンジニアリング、Feature Store | [261](261-sagemaker-data-collection-and-preparation.md)／[262-sagemaker-feature-store.md](262-sagemaker-feature-store.md) |
| ③ | モデルトレーニング | ハイパーパラメータチューニング、正則化 | [263-sagemaker-training-and-tuning.md](263-sagemaker-training-and-tuning.md) |
| ④ | モデル評価 | Experiments、Clarify、Model Registry | [264-sagemaker-experiments-and-model-registry.md](264-sagemaker-experiments-and-model-registry.md)／[265-sagemaker-clarify.md](265-sagemaker-clarify.md) |
| ⑤ | モデルのデプロイと推論 | デプロイ先選択、リアルタイム/バッチ推論、エッジデプロイ | [266-sagemaker-deployment-and-inference.md](266-sagemaker-deployment-and-inference.md) |
| 運用 | MLOps（CI/CD/CT）、監視、アクセス管理 | Model Monitor、Pipelines、Role Manager | [267-sagemaker-mlops-monitoring-pipelines-and-governance.md](267-sagemaker-mlops-monitoring-pipelines-and-governance.md) |
