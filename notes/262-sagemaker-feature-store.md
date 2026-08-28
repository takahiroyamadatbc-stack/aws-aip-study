# SageMaker Feature Store

MLパイプライン全体の位置づけは[260-sagemaker-ml-pipeline-overview.md](260-sagemaker-ml-pipeline-overview.md)を参照。特徴量エンジニアリングの一般的な手法（生成・選択・次元削減）は[261-sagemaker-data-collection-and-preparation.md](261-sagemaker-data-collection-and-preparation.md)を参照。

**解決する課題**: 特徴量エンジニアリングのロジックをチーム・モデルごとに個別実装すると、①同じ特徴量を何度も作り直す無駄、②学習時（バッチ）と推論時（リアルタイム）で計算方法が微妙にズレる**training-serving skew**、が発生する。Feature Storeはこれらを解消するための、特徴量を一元管理する**リポジトリ（中央集権的なストア）**。

## コアとなる概念

| 概念 | 内容 |
|------|------|
| Feature Group | 特徴量のスキーマ（列定義）とデータ本体をまとめた管理単位。DBのテーブルに相当 |
| Record Identifier | Feature Group内でレコードを一意に識別するキー（例: `customer_id`） |
| Event Time | その特徴量の値がいつ時点のものかを示すタイムスタンプ列。**Point-in-Time（時点指定）での正しい特徴量取得**に必須 |
| Feature Definitions | 各列の名前・型（String/Fractional/Integral）の定義 |

## Online Store と Offline Store

| 観点 | Online Store | Offline Store |
|------|---------------|----------------|
| 用途 | リアルタイム推論時に、最新の特徴量を**低レイテンシ（ミリ秒単位）**で1レコード取得 | 学習・バッチ推論・分析向けに、**大量の履歴データ**をまとめて取得 |
| 保持データ | 各Record Identifierごとの**最新値のみ** | 過去分も含めた**全履歴**（追記型） |
| バックエンド | 低レイテンシKVS相当のマネージドストレージ | S3 + AWS Glue Data Catalog（Athenaで直接クエリ可能） |
| アクセス方法 | `GetRecord`等のAPI呼び出し | Athena/SQLクエリ、SageMaker Processing/Training Jobからの読み込み |
| 有効化 | 個別に有効化可能（コスト最適化のため不要なら無効化できる） | 個別に有効化可能（両方同時に有効化するのが一般的） |

## 主なポイント

- **Ingestion（取り込み）**: Data Wranglerの変換フローから直接エクスポート、またはSDK（`PutRecord`）・SageMaker Processing/Pipelinesのジョブからバッチ/ストリーミングで取り込める。Online/Offline両方を有効化しておけば、1回のIngestionで両ストアに自動反映される
- **Point-in-Time結合（時点整合性）**: Event Timeを使うことで、「学習データのラベル発生時点でその特徴量が実際にどんな値だったか」を正しく再現できる（未来の情報が混入するリーク＝**target leakage**の防止に直結）
- **再利用性**: 一度Feature Groupとして登録した特徴量は、他のモデル・他のチームのパイプラインからも検索・参照できる（Feature Store内の検索機能でカタログ的に使える）
- **学習と推論の整合性**: 同じFeature Group（同じ計算ロジックで作られた特徴量）をOffline Store経由で学習、Online Store経由で推論時に参照することで、training-serving skewを構造的に防止する

Data Wranglerで作った変換フローはそのままFeature Storeへのエクスポート、またはSageMaker Processing Jobでのスケーラブルな実行（scikit-learnコンテナ/Sparkコンテナ）につなげられる。

## 試験でのひっかけポイント整理

- 「Feature StoreのOnline StoreとOffline Storeはどちらも同じ用途」→ 誤り。Online Storeは推論時の低レイテンシ参照、Offline Storeは学習・バッチ処理向けの履歴データ蓄積、と役割が異なる
