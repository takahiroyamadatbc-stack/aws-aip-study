# SageMaker AI: MLOps（Model Monitor・Pipelines）とアクセス管理

MLパイプライン全体の位置づけは[260-sagemaker-ml-pipeline-overview.md](260-sagemaker-ml-pipeline-overview.md)を参照。バイアス検出・説明可能性（SageMaker Clarify）は[265-sagemaker-clarify.md](265-sagemaker-clarify.md)を参照。

## MLOps: CI/CDに加えてCTが必要な理由

MLOpsは、①〜⑤のパイプラインを**一度きりで終わらせず、継続的に運用・改善し続けるための実践**。DevOpsのCI/CD（継続的インテグレーション/継続的デリバリー）に加えて、**CT（Continuous Training、継続的トレーニング）**が不可欠になる点がソフトウェア開発一般のDevOpsとの決定的な違い。

| 要素 | 内容 |
|------|------|
| CI（Continuous Integration） | 前処理・学習スクリプト等のコード変更を継続的に統合し、ユニットテスト・データ検証・モデル性能テストを自動実行する |
| CD（Continuous Delivery/Deployment） | テストを通過したモデル・パイプラインを本番環境へ継続的にデプロイする |
| CT（Continuous Training） | 本番環境の状況変化に応じて、**モデルを継続的に再学習し直す**。通常のソフトウェアのCI/CDにはない、ML特有の要素 |

### なぜCTが必要か: データドリフトとモデルドリフト

通常のソフトウェアは「コードを変更しなければ動作は変わらない」が、機械学習モデルは**コードを一切変更しなくても、本番環境の実データが変化すれば予測精度が劣化していく**。この劣化の主な原因が以下の2つ。

| 種類 | 何が変化するか | 具体例 |
|------|------------------|--------|
| **データドリフト（Data Drift）** | 本番環境に入ってくる**入力データの統計的分布**が、学習時の分布から乖離していく | ユーザー属性の変化、季節性、新しい商品カテゴリの追加、景気動向・トレンドの変化など |
| **モデルドリフト（Model Drift / Concept Drift）** | 入力（X）と出力（Y）の**関係性そのもの**が時間とともに変化する | 不正のパターンが変化する、消費者の嗜好が変わる、業務ルール・目的変数の定義が変わるなど |

- 両者の違いは「**何が変わるか**」の軸にある。データドリフトは入力の分布が変わる現象、モデルドリフト（コンセプトドリフト）は入力と出力の対応関係そのものが変わる現象。**入力分布は変わらなくても**、XからYへの写像が変わればモデルドリフトは発生しうる
- どちらも学習前のテスト（ユニットテスト・CI）だけでは検出できない。**本番運用中の継続的なモニタリング**でしか気づけないため、ドリフトを検知したら再学習・再デプロイまでを自動/半自動で回すCTのパイプラインが必要になる

### AWSでの実装

| サービス | 役割 |
|------|------|
| SageMaker Model Monitor | 本番稼働中のエンドポイントの入力データ分布・予測結果を継続的にキャプチャし、学習時のベースラインと統計的に比較してデータドリフトを検出。正解ラベルが後から得られる場合はモデル品質のドリフト、特徴量アトリビューションのドリフト、バイアスドリフトも監視できる |
| SageMaker Pipelines | 前処理→学習→評価→デプロイの一連のワークフローをコードとして定義し、CI/CD/CTのオーケストレーションを担う |
| Amazon EventBridge | Model Monitorがドリフトを検知したイベントをトリガーに、SageMaker Pipelinesの再学習ワークフローを自動起動する、といった連携に使う |
| SageMaker Projects / CodePipeline・CodeBuild | モデルコード・パイプラインコードのビルド・テスト・デプロイ（CI/CD部分）を自動化するMLOpsテンプレート |

**全体の循環**: CI（コード変更→自動テスト）→ CD（承認されたモデル/パイプラインの本番デプロイ）→ 本番運用中にModel Monitorがデータドリフト/モデルドリフトを検知 → CT（自動的に①〜③へ戻って再学習）→ 再度CI/CDへ、という循環がMLOpsの基本形。

## SageMaker Model Monitor

**位置づけ**: 本番稼働中のSageMakerエンドポイントを対象に、入力データ・予測結果を継続的に監視し、学習時の状態からの乖離（ドリフト）を検出するサービス。CTの起点となる「異常検知」を担う。**SageMakerエンドポイントのData Captureに依存するため、Bedrockのマネージド基盤モデル呼び出し（SageMakerエンドポイントを経由しない呼び出し）には標準では統合されない**（Bedrock側の呼び出しログをModel Monitorが読み込める形式に変換する橋渡しが必要。Bedrockアプリでの継続的な公平性監視には、任意のS3データに実行できるSageMaker Clarifyを組み合わせる設計パターンが使われる。詳細は[265-sagemaker-clarify.md](265-sagemaker-clarify.md)、[50-model-evaluation.md](50-model-evaluation.md)を参照）。

**監視できる4種類のドリフト**

| 監視タイプ | 何を見るか | 必要なもの |
|------|------|------|
| Data Quality（データ品質） | 入力特徴量の統計的分布（欠損率、型、値域など）が学習時のベースラインからどれだけ乖離しているか＝**データドリフト**の検出 | 学習データ等から作成したベースライン統計量・制約（constraints） |
| Model Quality（モデル品質） | 推論結果と、後から取得した**正解ラベル（ground truth）**を突き合わせ、精度指標（Accuracy/F1/RMSE等）の劣化を監視＝**モデルドリフト**の検出に直結 | 推論後に別途収集する正解ラベル |
| Bias Drift（バイアスドリフト） | 本番運用中の予測結果における属性間の偏りの変化を監視（学習後バイアスの継続監視版） | SageMaker Clarifyとの統合 |
| Feature Attribution Drift（特徴量寄与度ドリフト） | SHAP値ベースの特徴量重要度の分布が、学習時と比べてどう変化したか | SageMaker Clarifyとの統合 |

**仕組み（基本フロー）**

1. **ベースライン作成**: 学習データ（または評価用データ）から統計量・制約を計算し、比較の基準として保存する
2. **Data Capture**: エンドポイント設定でリクエスト/レスポンスを継続的にS3へキャプチャするよう有効化する
3. **Monitoring Schedule**: 定期的（例: 1時間ごと）にキャプチャデータとベースラインを比較する監視ジョブを自動実行する
4. **違反検出と通知**: 統計的な乖離（violation）を検出するとCloudWatchメトリクスに反映され、アラーム経由でSNS通知やEventBridge連携によるパイプライン起動（CT）につなげられる

**主なポイント**

- Model Monitor自体は**検出のみ**を行うサービスで、検出後の**再学習・再デプロイのアクションは行わない**（EventBridge + SageMaker Pipelines等で自前に構成する必要がある）
- Model Quality監視には**正解ラベルの後日収集**が前提になる点に注意（Data Quality監視はラベル不要で、入力分布だけで検出できる）
- SageMaker Studio上でドリフトの推移や違反箇所を可視化でき、監視結果はCloudWatch経由で既存の運用監視基盤にも統合できる

**提供状況の変更（2026年7月30日〜新規顧客への提供終了）**

- AWS公式ドキュメントの告知により、SageMaker Model Monitorは**2026年7月30日以降、新規顧客が新たに利用開始することができなくなる**（[Model Monitor availability change](https://docs.aws.amazon.com/sagemaker/latest/dg/model-monitor-availability-change.html)）。**既存に利用していた顧客は従来通り利用を継続できる**点はClarifyと同様（同時に対象となる他機能は[265-sagemaker-clarify.md](265-sagemaker-clarify.md)の「提供状況の変更」セクション参照）
- AWSが提示する代替手段: **オープンソースのSageMaker AI監視ソリューション**（`aws-samples`組織でAWSが公開、SageMaker AI MLflow Apps + Evidently AIベース）＋**Amazon QuickSight**（ガバナンスダッシュボード）＋**Amazon CloudWatch**の組み合わせ
  - Data Quality監視: Evidently AIの`DataDriftPreset`（PSI・KS統計量）で代替
  - Model Quality監視: Evidently AIの`ClassificationPreset`で代替（正解ラベルとの突き合わせが前提な点は変わらない）
  - Bias Drift / Feature Attribution Drift監視: セグメント（属性）ごとの指標をEvidently AIで算出し、MLflow・QuickSightに記録する構成に置き換え
  - いずれもAWSの管理下ではなく**ユーザー自身のAWSアカウント内で動くオープンソースの参照実装**を採用・カスタマイズする形になり、Model Monitorのようなマネージドの「機能を有効化するだけ」という位置づけから変わる点に注意
- 出題時期・情報鮮度に注意: この提供終了情報はAIP-C01試験問題自体には（作問時期次第では）反映されていない可能性が高い。「Model Monitor/Clarifyを使う」という設問・解説が今後も出うるが、**実務でこれから新規に採用する前提の設計をする際は、上記の提供終了時期を踏まえてAWSの最新ドキュメントを確認する**のが実務上の前提になる

## SageMaker Pipelines

**位置づけ**: ①データ収集後の前処理〜⑤デプロイまでの一連の処理を、**コードで定義されたワークフロー（DAG: 有向非巡回グラフ）**として組み、繰り返し実行・自動実行できるようにするMLワークフロー専用のオーケストレーションサービス。CI/CD/CTを実際に「動かす仕組み」の中核を担う。他のオーケストレーションサービス（Step Functions/Bedrock Flows/Multi-Agent Collaboration/AgentCore）との位置づけ比較は[04-agent-orchestration-services-comparison.md](04-agent-orchestration-services-comparison.md)を参照。

**構成要素（Step）**

| Step種別 | 役割 |
|------|------|
| Processing Step | データの前処理・後処理・モデル評価などのSageMaker Processing Jobを実行 |
| Training Step | モデルの学習（Training Job）を実行 |
| Tuning Step | Automatic Model Tuning（HPO）ジョブを実行 |
| Transform Step | バッチ推論（Batch Transform）を実行 |
| RegisterModel Step | 評価済みモデルをSageMaker Model Registryに登録 |
| Condition Step | 評価指標が閾値を超えた場合のみ後続Stepに進む、といった**条件分岐**を組み込む |
| Callback Step / Lambda Step | パイプライン外部のシステム・承認フロー・Lambda関数と連携する |
| Fail Step | 条件を満たさない場合にパイプラインを明示的に失敗させる |

**主なポイント**

- **パラメータ化**: インスタンスタイプ、入力データのS3パス、ハイパーパラメータ等を実行時パラメータとして定義でき、同じPipeline定義を使い回して条件を変えて再実行できる
- **キャッシング**: 入力・設定が前回実行と同一のStepは再実行せずキャッシュ結果を再利用し、コスト・実行時間を削減できる
- **Experiments/Lineageとの統合**: Pipelineの各実行は自動的にSageMaker Experimentsの1つの試行として記録され、生成されたモデル・データの系譜（どのコード・データから作られたか）も自動追跡される（詳細は[264-sagemaker-experiments-and-model-registry.md](264-sagemaker-experiments-and-model-registry.md)）
- **条件付きゲート**: Condition Stepで「評価指標が基準を満たした場合のみModel Registryに登録する」といった、精度が悪いモデルを本番に進ませないゲートを構成できる
- **トリガー**: 手動実行のほか、Amazon EventBridgeと組み合わせてスケジュール実行や、S3への新規データ到着・Model Monitorのドリフト検知イベントをきっかけにした自動実行（＝CTの実体）を組める
- **CI/CDとの統合**: SageMaker Projects（CodePipeline/CodeCommit/CodeBuildと統合されたMLOpsテンプレート）と組み合わせることで、コードのpushをトリガーにPipelineの実行・承認・本番デプロイまでを一気通貫で自動化できる

**役割分担の整理**: Pipelinesは**ワークフローの定義・実行そのもの**、Experimentsは**実行結果（メトリクス等）の記録・比較**、Model Registryは**モデルの承認・バージョン管理**を担う。三者は競合せず、Pipelines実行の中でExperimentsへの記録とModel Registryへの登録が行われる、という関係。

## SageMaker Studioのアクセス管理: SageMaker Role Manager

**解決する課題**: SageMaker Studio（Domain）を使い始める際、データサイエンティストやMLOpsエンジニアなど、利用者ごとに「何ができて何ができないか」を細かく制御するIAMロールを1から設計するには、IAMポリシーの専門知識と、SageMakerが要求するAPI権限の網羅的な把握が必要になる。**SageMaker Role Manager**は、この**IAM実行ロール（Execution Role）作成の敷居を下げ、最小権限（least privilege）の原則に沿ったロールをウィザード形式で素早く作れるようにする**機能。IAMそのものを置き換えるサービスではなく、あくまでIAMロール作成を支援するSageMaker Studio上のツールという位置づけ。

**基本的な使い方（ウィザードの流れ）**

1. **ペルソナ（役割）を選択**する。SageMakerがあらかじめ用意している定義済みペルソナには以下のようなものがある

| ペルソナ | 想定する利用者 | 付与される権限の傾向 |
|------|------|------|
| Data Scientist | ノートブックでの分析・トレーニングジョブの実行が中心の利用者 | トレーニング/前処理ジョブの実行、S3上の学習データへのアクセス等、モデル開発に必要な範囲 |
| MLOps Engineer | パイプライン・CI/CDの構築・運用を行う利用者 | SageMaker Pipelines、Model Registry、CodePipeline等、運用オーケストレーションに必要な範囲 |
| Compute Cluster Administrator | トレーニング用クラスタ（HyperPod等）の管理者 | クラスタのプロビジョニング・管理に必要な範囲 |

2. **ネットワークアクセス（VPCのみに制限するか等）**、**S3バケットへのアクセス範囲（特定バケットのみに限定する等）**、**追加で必要なAWSサービスへのアクセス（Ground Truth、Feature Store等）**をウィザードの質問に答える形で選択する
3. Role Managerが、選択内容に応じた**IAMポリシー（カスタマー管理ポリシー）を自動生成**し、IAMロールとして作成する
4. 作成したロールは、SageMaker Domain全体の**デフォルト実行ロール**として、またはUser Profile（ユーザーごと）に個別の実行ロールとして割り当てられる

**主なポイント**

- **最小権限をデフォルトで実現しやすくする**のが最大の狙い。ゼロからポリシーを書くと「とりあえず`AmazonSageMakerFullAccess`を付与してしまう」ような過剰権限になりがちな問題を、ペルソナ単位の絞り込みで緩和する
- 生成されたポリシーは**IAMコンソール上で通常のカスタマー管理ポリシーとして確認・編集可能**（Role Managerで作った後も、通常のIAM運用でメンテナンスできる）
- **既存ロールへのアタッチ**（既にあるIAMロールにSageMakerに必要な権限を追加する）と、**新規ロールの作成**の両方のフローに対応
- あくまで**IAM実行ロールという「ヒト（または実行主体）に何を許可するか」を扱う機能**であり、モデルの学習後バイアス検出やプライバシー保護とは領域が異なる（同じガバナンス文脈でも[31-responsible-ai-core-dimensions.md](31-responsible-ai-core-dimensions.md)で扱う説明可能性・公平性とは別軸の「アクセス制御」の話）

## 試験でのひっかけポイント整理

- 「MLOpsはDevOpsのCI/CDをそのまま適用すればよい」→ 誤り。コードが変わらなくても本番データの変化でモデル精度が劣化しうるため、ML特有の要素としてCT（継続的トレーニング）が必要になる
- 「データドリフトとモデルドリフト（コンセプトドリフト）は同じ意味である」→ 誤り。データドリフトは入力データの分布が変化する現象、モデルドリフトは入力と出力の関係性そのものが変化する現象で、変化する対象が異なる
- 「SageMaker Model Monitorはコードの品質をテストするCIツールである」→ 誤り。Model Monitorは本番稼働中のエンドポイントのデータ分布・予測品質を監視し、ドリフトを検出するための運用時ツール
- 「SageMaker PipelinesとSageMaker Experimentsは同じ機能である」→ 誤り。Pipelinesはワークフロー（Step群）の定義・実行そのものを担い、Experimentsはその実行結果（メトリクス・パラメータ）の記録・比較を担う。役割が異なるが、Pipelinesの実行はExperimentsに自動記録される形で連携する
- 「SageMaker Model Monitorはドリフトを検知したら自動的にモデルを再学習してくれる」→ 誤り。Model Monitorはドリフトの検出のみを行い、検知後の再学習・再デプロイはEventBridge等と連携して別途構成する必要がある
- 「Model Quality監視には正解ラベルは不要である」→ 誤り。Model Quality（モデル品質）の監視は、推論結果と後から取得した正解ラベルを突き合わせて精度指標を計算するため、ground truthラベルの収集が前提。ラベル不要で検出できるのはData Quality（データドリフト）監視の方
