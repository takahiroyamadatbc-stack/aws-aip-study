# AIサービス横断のデプロイ戦略とトラフィック移行の仕組み

## これは何か

FM呼び出し（Bedrock）、カスタムモデル、プロンプト管理、RAG（Knowledge Bases）、エージェント（Bedrock Agents／Strands Agents SDK／AgentCore）、SageMakerなど、AIP-C01では対象ごとに「新旧バージョンをどう安全に切り替えるか」という設計パターンが問われる。目的（段階的なトラフィック移行、自動ロールバック）はどのサービスでも共通だが、**それを実現する機構がサービスによって「ネイティブに存在する」場合と「存在せず外付けが必要」な場合に分かれる**のが、この領域を整理しづらくしている最大の理由。

この違いを知らずに問題を解くと、「◯◯にカナリアデプロイをしたい」という要件に対して、**そのサービスには存在しない機能**（BedrockのモデルにLambdaのエイリアス相当の機構がある、BedrockモデルをSageMakerのバリアントとして扱える、等）を選んでしまう誤答を招く。本ノートは、各対象の「デプロイ単位」「バージョン・エイリアス相当の機構」「段階移行（カナリア）機構」「自動ロールバック機構」を横断的に整理する。

## 全体マップ

| 対象 | デプロイ単位 | バージョン・エイリアス相当の機構 | 段階移行機構はネイティブか |
|---|---|---|---|
| **Bedrock FM呼び出し**（`InvokeModel`） | modelId／プロビジョンドスループットARN | **なし**。Bedrock自体は版管理・トラフィック分割の概念を持たない | ✗ 外付け必須（後述） |
| **Bedrockカスタムモデル**（Fine-tuning／Custom Model Import） | Custom Model ARN（ジョブごとに新規リソース） | なし。新モデルは別リソースとして生成される | ✗（FM呼び出しと同様、外付け） |
| **Bedrock Prompt Management** | Prompt Version（`CreatePromptVersion`で発行する不変スナップショット） | **Prompt Alias**をバージョンに紐付け、向き先変更で切替 | △（Aliasの向き先切替はあるが、重み付けの段階移行機構ではない＝一括切替） |
| **Bedrock Knowledge Bases（RAG）** | Ingestion Job（データソース同期） | なし。バージョニング概念が薄い領域 | ✗（対象外の領域） |
| **Bedrock Agents／Flows** | Agent Version／Flow Version（`Prepare`／`CreateFlowVersion`で発行する不変スナップショット） | **Alias**がバージョンを指すポインタ。詳細は[22-bedrock-knowledge-bases-and-agents.md](22-bedrock-knowledge-bases-and-agents.md)参照 | △（Aliasの向き先切替はあるが、重み付けの段階移行機構ではない＝一括切替） |
| **Strands Agents SDK** | アプリコード側の管理。SDK自体はデプロイ機構を持たない | なし（ホスト先に依存） | ✗（ホスト先＝Lambda/ECS/AgentCore Runtime等の機構にそのまま乗る） |
| **AgentCore Runtime** | Runtimeのデプロイ単位 | Runtime version／endpoint | 要確認（AgentCore固有の管理面。詳細は[23-bedrock-agentcore.md](23-bedrock-agentcore.md)参照） |
| **AWS Step Functions**（GenAIオーケストレーション基盤として使う場合） | ステートマシンバージョン（発行時点のスナップショット） | **バージョン＋エイリアス＋RoutingConfiguration**。詳細は[41-step-functions-versioning-deployment.md](41-step-functions-versioning-deployment.md)参照 | ○ ネイティブ（ALL_AT_ONCE／LINEAR／CANARY＋CloudWatchアラームでの自動ロールバック） |
| **SageMakerエンドポイント** | Production Variant／Inference Component | Model Registryのモデルバージョン＋承認ステータス（詳細は[264-sagemaker-experiments-and-model-registry.md](264-sagemaker-experiments-and-model-registry.md)参照） | ○ ネイティブ（**Deployment Guardrails**、後述） |

## Bedrockの生FM呼び出しに段階移行機構がない、という重要ポイント

`InvokeModel`はmodelId（またはPTのARN）を指定して1回呼ぶだけのAPIで、SageMakerのProduction Variantの重み付けや、Lambdaのエイリアス加重ルーティングに相当する仕組みがBedrock自体には存在しない。Bedrock Agents／FlowsにはAlias機構があるが、これも**重み付けでの段階配分ではなく、Aliasの向き先を一括で切り替える**仕組みであり、Step FunctionsのRoutingConfigurationのような「10%だけ新バージョンに流す」という段階移行はできない。

このため、Bedrockモデル自体を段階的トラフィック移行させたい場合は、**呼び出し元（アプリ／オーケストレーション層）が「今何%を新旧モデルに振るか」という重みを自分で保持・更新する**外付け設計が必須になる。代表的な2パターンは以下。

### パターン1: AWS AppConfig（Feature Flag）

| 要素 | 役割 |
|---|---|
| Configuration Profile（Feature Flag種別） | `use_new_model`のようなフラグと、`target_model_id`等の付随属性を定義 |
| Environment | デプロイ先の単位。**Monitor（CloudWatchアラーム）**を紐付け可能 |
| Deployment Strategy | `GrowthType`（Linear／Exponential）、`GrowthFactor`、`DeploymentDurationInMinutes`、`FinalBakeTimeInMinutes`でロールアウト速度を定義。プリセットとして`AppConfig.Canary10Percent20Minutes`、`AppConfig.Linear50PercentEvery30Seconds`、`AppConfig.AllAtOnce`等がある |

- **配布方式はPull型**：アプリはAppConfig Agent／Lambda拡張機能／SDKの`GetLatestConfiguration`を定期ポーリングする。ロールアウト中はクライアントごとに一貫したハッシュで新旧どちらの値を返すか判定されるため、**アプリ側で%分割ロジックを自前実装しなくても、時間経過とともに新設定を受け取るクライアントの割合が自然に増えていく**
- **自動ロールバック**：Environmentに紐付けたCloudWatchアラームがロールアウト中（bake time中も含む）にALARM状態になると、AppConfigが自動的に直前のバージョンへロールバックする
- 向いているケース：「新モデルを使うかどうか」という**単純な二値フラグ**の安全な展開で十分な場合

### パターン2: Step Functions＋Lambda＋CloudWatch（自前オーケストレーション）

- EventBridgeのスケジュール／カスタムイベントでStep Functionsワークフローを起動
- ワークフローが重み設定（DynamoDB／Parameter Store等に保持）を段階的に書き換えつつ、都度Lambda経由でCloudWatchの推論メトリクス（レイテンシー、エラー率等）を評価
- Choice状態で「メトリクスが閾値内なら増加、下回ればロールバック」を条件分岐
- 向いているケース：**複数の推論メトリクスや過去のトラフィックパターンを組み合わせた複雑な判断**が要る場合（AppConfigの単純なアラームON/OFF判定では表現しきれない）

### 2パターンの使い分け

| | AppConfig Feature Flag | Step Functions＋Lambda＋CloudWatch |
|---|---|---|
| ロールアウト制御 | Deployment Strategyがマネージドで提供 | 自前でChoice状態と待機を組んで実装 |
| ロールバック判定 | Monitor（CloudWatchアラーム）を紐付けるだけ | Lambdaが能動的にメトリクスを取得・評価 |
| 判断ロジックの自由度 | 低い（基本はアラームのALARM/OK二値） | 高い（複数メトリクスの複雑な条件分岐が可能） |
| 実装の手間 | 小さい（マネージド機能の組み合わせ） | 大きい（ワークフロー・Lambda・状態管理を自前設計） |

## SageMaker Deployment Guardrails（参考: SageMakerエンドポイントの場合）

SageMakerのリアルタイムエンドポイントには、`UpdateEndpoint`の`DeploymentConfig`パラメータで指定する**Deployment Guardrails**というネイティブの安全弁機構がある。Bedrockと違い、SageMakerエンドポイントは元々この機構を持っている点が対照的。

| 要素 | 内容 |
|---|---|
| **トラフィックシフト方式** | All At Once（即時全量切替）／Canary（一部%に振ってbake time待機後、残り全量へ）／Linear（等分ステップで段階的に増加） |
| **自動ロールバック** | `AutoRollbackConfiguration`にCloudWatchアラームを指定。bake time中にALARM状態になれば自動的に旧バージョンへ戻す |
| **Rolling deployment** | Inference Component方式（マルチモデルエンドポイント）でのインスタンス単位の段階入替 |

Production Variantへの常時の重み付け（`InitialVariantWeight`によるA/Bテスト・Shadow Testing）とは別枠の機能で、Deployment Guardrailsは「新バージョンへの**移行**を安全に行う」ためのもの、という役割分担になる。

## ケーススタディ: Bedrockモデルのカナリアデプロイ設問

「複数のBedrockモデル間でリアルタイム推論メトリクス・過去のトラフィックパターン・サービスの正常性に基づいた自動化された段階的トラフィック移行を実現したい」という要件が出た場合の判断フロー。

1. **BedrockモデルにSageMakerのエンドポイントバリアントやDeployment Guardrailsを適用しようとする選択肢は誤り**（サービスの適用範囲外。SageMakerエンドポイント専用の機構）
2. **API Gatewayの加重ルーティングだけで完結する選択肢も誤り**（Bedrockのmodel呼び出しには紐づかず、「外部ロジック」の実装を別途要するため要件の「自動化」を満たさない）
3. Bedrock自体にAlias／重み付け機構がないことを前提に、**外付けオーケストレーションが必要**と判断する
4. 要件が「複数の推論メトリクス」「過去のトラフィックパターン」まで含む複雑な判断であれば、AppConfigの単純な二値アラーム判定では力不足なので**Step Functions＋Lambda＋CloudWatch**を選ぶ（プロビジョンドスループットは、この判断とは別軸で「新旧モデルを安定した推論容量でホストするための前提条件」として使われているだけで、正誤の決め手ではない）
5. 要件が「単純なON/OFFフラグの安全な展開」で足りるなら、**AWS AppConfIG Feature Flag**の方がマネージドで手間が少なく適合する

## 試験でのひっかけポイント整理

- 「BedrockモデルをSageMakerのエンドポイントバリアント／Deployment Guardrailsで管理する」→ 誤り。両者は別サービスで、SageMakerの機構はSageMakerエンドポイント専用
- 「Bedrock Agents／FlowsのAliasを使えば、Bedrockのモデル呼び出し全般を段階的トラフィック移行できる」→ 誤り。AliasはAgent／Flowという成果物の版管理機構であり、生のFM呼び出し（`InvokeModel`）には適用されない。またAliasの切替自体も重み付けの段階移行ではなく一括切替
- 「AppConfigはBedrock専用のデプロイ機能」→ 誤り。AppConfigはAWS全般で使える汎用のフィーチャーフラグ／設定配信サービスであり、Bedrockのモデル切替はその応用例の1つに過ぎない
- 「Step FunctionsとAppConfigはどちらでも同じことができるので、どちらを選んでも正解になる」→ 要注意。判断ロジックの複雑さ（単純な二値フラグか、複数メトリクスを組み合わせた条件分岐か）で使い分けが問われる
- 「プロビジョンドスループットの記述があるから、これはトラフィック分割の仕組みを提供している」→ 誤り。PTは推論容量を確保するための契約であり、トラフィック分割ロジックとは無関係
