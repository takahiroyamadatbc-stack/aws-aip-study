# GenAI/Agentオーケストレーション5サービスの位置づけ比較

対象: **AWS Step Functions / Amazon Bedrock Flows / Amazon Bedrock Agents Multi-Agent Collaboration / Amazon SageMaker Pipelines / Amazon Bedrock AgentCore**

これらは文脈によって「複数のAI/Agentを連携させられる」ように見えるが、**何をオーケストレーションするサービスなのか・誰が次の処理を決めるのか**が全く異なる。「複数のAgentを動かしたい」→「じゃあMulti-Agent Collaboration」のような短絡を防ぐための整理ノート。各サービスの実装詳細（API・パラメータ）は下記の既存ノートに譲り、このノートは**比較と判断軸**に特化する。

- Bedrock Agents / Multi-Agent Collaboration / Flowsの実装詳細 → [22-bedrock-knowledge-bases-and-agents.md](22-bedrock-knowledge-bases-and-agents.md)
- AgentCoreの構成要素（Runtime/Gateway/Memory/Identity/Observability/Evaluations）の実装詳細 → [23-bedrock-agentcore.md](23-bedrock-agentcore.md)
- Strands Agents SDKのマルチエージェントパターン（Agents as Tools/Swarm/Graph/Workflow）とA2Aプロトコル → [24-strands-agents-sdk.md](24-strands-agents-sdk.md)
- SageMaker Pipelinesの各Step種別・MLライフサイクル全体 → [26-sagemaker-ai-ml-pipeline.md](26-sagemaker-ai-ml-pipeline.md)
- Step Functionsのサービス統合パターン（`.sync`/`.waitForTaskToken`） → [200-step-functions-service-integration-patterns.md](200-step-functions-service-integration-patterns.md)
- Step Functionsのバージョニング・デプロイ → [41-step-functions-versioning-deployment.md](41-step-functions-versioning-deployment.md)

## 0. 最重要の軸：「誰が次の処理を決めるのか」

5サービスを分ける唯一にして最大の軸は、**次に何をするかを人間が事前に決めるのか、LLM/Agentが実行時に決めるのか**。

```
【事前定義ワークフロー】人間が「A→B→条件分岐→C or D」を設計図として書く
  Step Functions          … AWSサービス呼び出し全般のステートマシン
  Bedrock Flows           … GenAI処理特化のノードグラフ
  SageMaker Pipelines     … MLライフサイクル特化のDAG

【実行時判断（Agentic）】LLMが「次に何をすべきか」を都度推論する
  Multi-Agent Collaboration … 複数Agent間のインテント分類・ルーティングをLLMが判断
  AgentCore                 … 自作Agent（ReActループ等）を本番で動かす基盤。判断ロジック自体はAgentのコード側にある
```

Step Functions/Flows/Pipelinesの「条件分岐」は、**あらかじめ人間が書いた条件式（閾値・ルール）を評価するだけ**であり、LLMが意味を理解して分岐先を決めているわけではない（Bedrock FlowsのConditionノードもJSONPath等の条件式評価であり、ノード自体がLLM推論をするわけではない。ただし前段にAgentノード/Prompt nodeを置いて、その出力をConditionノードで判定する組み合わせは可能）。一方Multi-Agent CollaborationのSupervisorやAgentCore上の自作Agentは、**自然言語の入力そのものを解釈して**次のアクション・呼び出し先Agentを決める。この「条件式の評価」と「自然言語の解釈」の違いが、事前定義ワークフローとAgentic workflowの本質的な差。

## 1. 「事前定義」3サービスの違い：何をオーケストレーションするか

Step Functions・Bedrock Flows・SageMaker Pipelinesはどれも「人間が設計したワークフロー」だが、**対象範囲**が異なる。

```
Step Functions      : AWSの任意サービス（Lambda, ECS, Glue, SageMaker, Bedrock, DynamoDB...）を横断
Bedrock Flows        : GenAI処理のパーツ（Prompt/Agent/KB/Guardrail/Lambda）に特化
SageMaker Pipelines  : MLライフサイクルのStep（前処理/学習/評価/デプロイ）に特化
```

- **Step Functions**は「何でも呼べる」代わりに、GenAI固有の概念（プロンプト管理、Guardrail適用、Knowledge Base検索）を直接ノードとして持たない。呼び出すなら各サービスのAPIをLambda経由/直接統合で叩く形になる
- **Bedrock Flows**はGenAI特化のため、Prompt node・Agent node・Knowledge Base node・Conditionノード・Iteratorノード（ループ）・InlineCodeノードなどをGUI/APIで直感的に組める一方、Bedrock外のAWSサービス（Glueジョブの実行、Step Functions自体の起動等）を組み込みたい場合はLambda functionノード経由に頼ることになる
- **SageMaker Pipelines**はML特有の概念（Training Job、Model Registry登録、HPOチューニング）に特化したStepしか持たず、**Agentを複数動かすための汎用オーケストレーターではない**。Agentが登場するとしても「分類モデルの学習・評価・デプロイパイプライン」という、Agentのために使うツール（分類モデル）を作る用途に限られる

## 2. Step Functions

```text
A（前処理Lambda）
  ↓
B（DynamoDB書き込み）
  ↓
Condition（在庫あり？）
  ├─ Yes → C（発送処理）
  └─ No  → D（Bedrock Agent呼び出しでお詫び文生成）
  ↓
E（通知）
```

- **次の処理を決める主体**: 人間（ステートマシン定義=Amazon States Language(ASL)のJSON/YAML）
- **フローの定義**: 100%事前定義。条件分岐（Choice State）・並列実行（Parallel State）・動的並列（Map State）・ループ（Choice Stateでの再帰的な遷移）を全て人間が設計する
- **Agentとの関係**: Bedrock Agent/AgentCore Runtime/SageMakerエンドポイントを**1つのTask Stateとして呼び出せる**が、Step Functions自身はAgentの中身（推論ロジック）には関与しない。あくまで「決まった手順の中でAgentを1コマとして使う」位置づけ
- **強み**: `.waitForTaskToken`によるヒューマンインザループ（人間の承認待ち）、`.sync`による長時間ジョブの待機、Standard Workflowsでの90日間の実行履歴保持など、**業務プロセス全体の信頼性・監査性**を担保する機能が豊富（詳細は[200-step-functions-service-integration-patterns.md](200-step-functions-service-integration-patterns.md)）
- **典型シーン**: 「注文処理の中でGenAI要約を1ステップ挟む」「ドキュメント取り込み→Textract→Bedrock要約→人間承認→公開、という業務フロー全体を制御する」など、**GenAIが処理全体の一部でしかない**業務ワークフロー

## 3. Bedrock Flows

```text
Input
  ↓
Prompt node（質問を分類するプロンプト）
  ↓
Condition node（分類結果がFAQか専門知識か）
  ├─ FAQ    → Knowledge Base node（KB検索して直接回答）
  └─ 専門知識 → Agent node（専門Bedrock Agentを呼び出し）
  ↓
Output
```

- **次の処理を決める主体**: 人間（Flow定義＝ノードグラフ）。ただし各ノードの中身（Prompt nodeやAgent node）はLLM/Agentが担当するため、「ノード間の遷移は事前定義、ノード内部の処理はLLMが担当」という**ハイブリッド**になる
- **フローの定義**: GUI（コンソール）またはAPI（`CreateFlow`）でノードとエッジ（`FlowConnection`）を定義。ノード種別はAgent/Condition/Collector/InlineCode/Input/Iterator/KnowledgeBase/LambdaFunction/Prompt/Output等
- **ループ**: Iteratorノードで配列の各要素に対して後続ノードを繰り返し適用できる（例: 複数ドキュメントを1件ずつ要約）
- **Agentとの関係**: Agent nodeは**既存のBedrock Agent（Multi-Agent CollaborationのSupervisorも含む）をFlow内の1ノードとして呼び出す**。つまりFlowsとAgentは競合ではなく、「Flowの1コマとしてAgentを使う」入れ子構造が典型
- **バージョン・エイリアス**: Agentsと同じくDRAFT→`CreateFlowVersion`（不変スナップショット）→エイリアス経由の呼び出し、という運用（詳細は[22-bedrock-knowledge-bases-and-agents.md](22-bedrock-knowledge-bases-and-agents.md)）
- **典型シーン**: 「入力をまず軽量モデルで分類し、種類に応じて異なるプロンプト/Agent/KBに振り分ける」ような、**GenAI処理だけで完結する軽量なノーコード/ローコードワークフロー**

## 4. Multi-Agent Collaboration（Bedrock Agents）

```text
Supervisor Agent（agentCollaboration = SUPERVISOR）
  ├── Collaborator Agent A（HR）
  ├── Collaborator Agent B（IT）
  └── Collaborator Agent C（Finance）
```

- **次の処理を決める主体**: **LLM（Supervisorの推論）**。ユーザー入力を受け取ったSupervisorが、各Collaboratorの登録時説明文をもとに**自然言語のインテント分類**を行い、動的にルーティングする。「どの部門のAgentに振るか」を人間が事前にif文で書くわけではない
- **フローの定義**: 事前に定義するのは「どのCollaboratorが存在し、それぞれ何を担当するか（description）」までで、**実行時にどのCollaboratorへ・何回・どの順で**振り分けるかはSupervisorのLLM推論に委ねられる
- **Agent同士の連携**: Collaboratorはそれ自体が独立したBedrock Agent（専用Alias）。新しい部門を追加する際はCollaboratorを1つ追加するだけでよく、既存の設定に影響しない拡張性がある。並行処理・スケーリングはBedrockのマネージド機構が自動で行う
- **AgentCoreとの違い（最重要）**: Multi-Agent Collaborationは**Bedrock ConsoleでSupervisor/Collaboratorという役割をAPIレベルで直接設定できる、Bedrock Agents専用のマネージド機能**。一方AgentCoreは「Supervisor」という概念をサービス自体は持たない。**AgentCore自身がSupervisorになるわけではなく、AgentCore上に自分でSupervisor/Orchestrator Agentのコード（Strands/LangGraph等で実装）をデプロイして初めてマルチエージェント構成が実現する**（詳細は次章）
- **典型シーン**: 「Bedrock Agentsの枠組みの中だけで完結する」マルチエージェント構成。Bedrock外のフレームワーク（LangGraph等）で書いたAgentをCollaboratorにすることはできない

## 5. AgentCoreは「何をオーケストレーションするサービス」なのか

AgentCoreを単なる「Agentを動かすサービス」と捉えると誤る。正しくは**「（自分で組んだ）Agentアプリケーションを本番環境で運用するための基盤」**であり、オーケストレーションロジックそのもの（次に何をすべきかの判断）は**Agentのコード側（Strands/LangGraph/CrewAI等）が持つ**。AgentCoreはそのAgentコードを、企業規模で安全に動かし続けるための土台を提供する。

### なぜ各コンポーネントが必要になるのか（100人〜1000人が使う社内Agentを想定）

| コンポーネント | 100〜1000人規模で何が起きるか（無いと困ること） |
|---|---|
| **Runtime** | 全員が同じプロセスで動くと、他人の会話文脈やコード実行結果が混ざる事故が起きうる。RuntimeはセッションごとにmicroVMで完全分離するため、Aさんの問い合わせでBさんの情報が漏れることがない。また「複雑な社内調査タスク」のような数十分〜数時間かかる処理も、Lambdaの実行時間上限を気にせず動かせる（最大8時間） |
| **Memory** | 1000人が「先週聞いたことの続き」を毎回一から説明させられたら使われなくなる。長期記憶（Long-term）がユーザーごとの過去のやりとり・嗜好を要約して保持し、短期記憶（Short-term）がその場のセッション内の文脈を保持する。これを自前実装すると、DynamoDB設計＋要約バッチ＋TTL管理を全部自分で作る羽目になる |
| **Gateway** | 社内に注文照会・人事システム・経費精算など数十〜数百のAPIがあるとき、1つずつMCP対応に作り直すのは非現実的。GatewayがLambda/OpenAPI/SmithyをMCP互換ツールに自動変換して公開するため、Agent側は個々のAPI仕様を意識せず一律にMCPツールとして呼べる |
| **Identity** | HR部門のAgentが人事DBに、Finance部門のAgentが会計システムにアクセスするとき、「今動いているのは誰の代わりか」を安全に扱わないと権限が混線する。Inbound Auth（誰がAgentを呼べるか）とOutbound Auth（Agentが外部SaaS/APIに代理アクセスする際のOAuthトークンの安全な保管・受け渡し）を両方管理する |
| **Observability** | 1000人規模になると、「どのAgentのレイテンシが悪化しているか」「特定のツール呼び出しでエラー率が上がっていないか」を人手で追うのは不可能。OpenTelemetry準拠のトレースをCloudWatch GenAI Observabilityに送り、可観測性を担保する |
| **Evaluations** | 本番トラフィックが増えると、個別のユーザーからの苦情でしか品質劣化に気づけなくなる。オンライン評価でライブトラフィックをサンプリングし、ゴール達成率・ツール選択精度を継続的にスコア化する |

### 構成例

```text
【例1: 単一Agentの社内問い合わせ】
ユーザー
  ↓
AgentCore Runtime（セッションごとにmicroVM分離）
  ↓
Agent（Strandsで実装したReActループ）
  ├── Bedrock（Claude等のFM呼び出し）
  ├── AgentCore Memory（過去のやりとりを踏まえた回答）
  ├── AgentCore Gateway → 社内API（人事・経費システム等）
  └── Bedrock Knowledge Base（社内規程の検索）

【例2: 自作Supervisorによるマルチエージェント構成】
ユーザー
  ↓
AgentCore Runtime
  ↓
Supervisor Agent（Strands "Agents as Tools"パターンで自作）
  ├── HR Agent   （同一Runtime内、Pythonの@toolとして呼び出し）
  ├── IT Agent   （同一Runtime内）
  └── Finance Agent（同一Runtime内）
   各AgentはAgentCore Memory/Gateway/Identityを個別または共通で利用

【例3: 組織をまたぐAgent連携（A2A）】
自社AgentCore Runtime上のAgent
  ↓（A2Aプロトコル、Agent Cardで相手のスキルを確認）
取引先の別インフラ上のAgent（AgentCoreである必要はない）
```

### AgentCoreでのAgent同士の連携パターン

同じ「複数Agentを連携させる」でも実現方法が複数あり、選択の決め手は**同一プロセス内か、Runtime/組織をまたぐか**。

| パターン | 実体 | 向いているケース |
|---|---|---|
| Agents as Tools | 子AgentをそのままPythonの`@tool`として親Agentに渡す（Strandsの機能。同一Runtime・同一プロセス内） | 階層的なSupervisor構成をシンプルに実装したい場合。ネットワークホップがなく低レイテンシ |
| A2A（Agent-to-Agent） | Googleが提唱しLinux Foundation配下で管理されるオープンプロトコル。各Agentが**Agent Card**（スキル・エンドポイント・認証方式のメタデータ）を公開し、それを見て呼び出す。AgentCore Runtimeは2025年11月にA2Aサーバー機能をネイティブサポート | **別のAgentCore Runtime・別フレームワーク・別組織**にデプロイされたAgent同士を疎結合に連携させたい場合（Strandsの Graph/Swarm/Workflow パターンをRuntime間に拡張できる） |
| MCP / Agent-as-MCP | AgentCore Runtime自体がステートフルなMCPサーバーとして動作できる（2026年3月時点でRuntimeがelicitation/sampling/progress通知等の高度なMCP機能をサポート）。AgentCore Gatewayはこれら複数のMCPサーバー（Agent含む）・ツールを集約するブローカーとして機能する | 「Agentをツールとして」外部のオーケストレーター（別のAgentや、Flows/Step Functions等）から一律にMCPツールとして呼び出せるようにしたい場合 |
| 複数Agentを別々のRuntimeに配置 | 部門ごとに独立したAgentCore Runtimeとしてデプロイし、A2A/MCPで疎結合に連携 | デプロイ・スケーリング・権限（Identity）を部門ごとに完全分離したい場合。1つのRuntime障害が他部門に波及しない |

**まとめ**: 密結合・低レイテンシで済むなら同一Runtime内のAgents as Tools、疎結合・Runtime/組織をまたぐならA2AまたはMCP、というのが選び方の軸。詳細な実装パターン（Swarm/Graph/Workflow）は[24-strands-agents-sdk.md](24-strands-agents-sdk.md)を参照。

Sources: [Amazon Bedrock AgentCore Runtime now supports stateful MCP server features](https://aws.amazon.com/about-aws/whats-new/2026/03/amazon-bedrock-agentcore-runtime-stateful-mcp) / [Cross-Runtime Agent Fabric: A2A, MCP, and AgentCore Gateway](https://hidekazu-konishi.com/entry/agent_interoperability_architecture_a2a_mcp_on_aws.html)

## 6. AgentCoreとSageMakerの関係

「AgentCoreはSageMakerで学習したモデルを使うためのものか？」という疑問は、**「モデルを作る」と「Agentを実行・運用する」を混同している**ために生じる。両者は依存関係のないレイヤー。

```text
SageMaker
  → MLモデルの学習・評価・デプロイ（独自の分類/回帰/レコメンドモデル等）

Bedrock
  → 基盤モデル（Claude等）・生成AI機能へのアクセス

AgentCore
  → Agentアプリケーション（LLMの推論ループ＋ツール呼び出し）の本番実行・運用基盤
```

- **SageMakerで学習したモデルをAgentから利用することは可能か**: 可能。SageMaker Endpointにデプロイした独自モデル（例: 需要予測モデル、独自の分類器）を、AgentCore Gateway経由でLambda等をラップして**1つのツール**としてAgentに呼ばせる構成が組める。Agentからは「ツールの1つ」として見え、SageMakerかBedrockかを意識する必要はない
- **BedrockのFMとの関係**: AgentCore上のAgentは、頭脳（推論）としてBedrockのFM（Claude等）を使うのが典型だが、**AgentCoreはモデル非依存**なので、SageMaker Endpointでホストした自前LLM、あるいはBedrock外のAPI（OpenAI等）を頭脳にすることもできる
- **結論**: 「SageMaker＝モデルを作る」「Bedrock＝基盤モデルを使う」「AgentCore＝Agentを動かし続ける」の3層整理は妥当。SageMakerで学習したモデルは、Bedrockの基盤モデルと同様に**AgentCore上のAgentが呼び出す「ツール」または「頭脳」の選択肢の1つ**という位置づけになる

## 7. SageMaker Pipelines

```text
データ準備
  ↓
前処理（Processing Step）
  ↓
学習（Training Step）
  ↓
評価（Processing Step）
  ↓
Condition Step（精度が閾値超え？）
  ├─ OK → RegisterModel Step（Model Registryに登録）
  └─ NG → Fail Step（パイプライン失敗、または再学習ジョブへ）
```

- **次の処理を決める主体**: 人間（Pipeline定義＝Step群とその接続、Condition Stepの閾値も人間が設定）
- **オーケストレーション対象**: **MLモデルのライフサイクル（前処理〜学習〜評価〜デプロイ）に特化**。Step種別（Processing/Training/Tuning/Transform/RegisterModel/Condition/Callback/Fail）の詳細は[26-sagemaker-ai-ml-pipeline.md](26-sagemaker-ai-ml-pipeline.md)
- **Agentとの関係**: **Agentそのものを複数動かす用途には使わない**。「Agentが呼び出す分類モデルを学習・評価・デプロイする」パイプライン、あるいはAgentCore/Bedrockの本番運用中にModel Monitorのドリフト検知をトリガーに再学習を回す（CT）パイプラインとして、Agentシステムの**裏側**で使われる
- **典型シーン**: 「社内問い合わせの初期分類器（どの部門宛かを判定するモデル）を継続的に再学習・再デプロイする」といった、GenAI/Agentシステムを支える**MLOpsの中核**

## 8. 5サービス比較表

| サービス | 主目的 | オーケストレーション対象 | 次の処理を決める主体 | フローの定義 | Agentとの関係 | 典型用途 |
|---|---|---|---|---|---|---|
| **Step Functions** | AWSサービス横断の業務ワークフロー制御 | 任意のAWSサービス・API呼び出し | 人間（ASLのState定義） | 事前定義（Choice/Parallel/Map State） | AgentやAgentCoreを1つのTask Stateとして呼び出す（Agentの中身には関与しない） | 業務プロセス全体（承認フロー、長時間ジョブ、GenAIはその一部） |
| **Bedrock Flows** | GenAI処理のノードベースワークフロー | Prompt/Agent/KB/Guardrail/Lambda等GenAI関連パーツ | 人間（ノードグラフ定義）。ノード内部の処理はLLM/Agentが担当 | 事前定義（ノード＋エッジ、Conditionノードで分岐、Iteratorノードでループ） | 既存のBedrock Agentを1ノードとして呼び出す（入れ子構造） | 軽量なGenAI処理の組み立て（分類→振り分け等） |
| **Multi-Agent Collaboration** | Bedrock Agents同士の協調 | 複数のBedrock Agent（Supervisor/Collaborator） | **LLM**（Supervisorの自然言語インテント分類） | 実行時判断（Collaboratorの存在とdescriptionのみ事前定義） | Agentそのものがオーケストレーション対象（Bedrock Agents専用） | Bedrock Agentsの枠内で完結する部門別マルチエージェント |
| **SageMaker Pipelines** | MLモデルのライフサイクル管理 | 前処理・学習・評価・デプロイのStep | 人間（DAG定義、Condition Stepの閾値） | 事前定義（DAG） | Agentが使うツール（分類モデル等）を作る裏方。Agent自体のオーケストレーションはしない | MLOpsのCI/CD/CT |
| **AgentCore** | Agentアプリケーションの本番運用基盤 | 自作Agent（コード）の実行環境・記憶・認可・監視 | **LLM/Agentのコード**（AgentCore自体はSupervisorにならない） | 実行時判断（判断ロジックはAgentコード側が持つ） | フレームワーク非依存で任意のAgent（Strands/LangGraph/Bedrock Agents等）をホスト | Agentを企業規模（多数ユーザー・長時間タスク）で安全に運用 |

## 9. 同一ユースケースでの比較：「社内問い合わせAI」

同じ要件でも、サービスが変われば担う役割がまったく違う。

```text
【Step Functions】GenAIは全体の一部。業務プロセスとして厳密に制御したい場合
問い合わせ受付 → 分類(Lambda) → KB検索(Lambda) → Bedrock Agent呼び出し → 
  Choice(要人間承認?) → [承認待ち .waitForTaskToken] → 回答送信

【Bedrock Flows】GenAI処理だけで完結する軽量な振り分け
Input → Prompt node(質問分類) → Condition
  ├─ FAQ    → Knowledge Base node → Output
  └─ 専門的  → Agent node(専門Agent呼び出し) → Output

【Multi-Agent Collaboration】Bedrock Agentsの枠内でLLMが動的に部門振り分け
Supervisor Agent
  ├── HR Agent（人事制度・休暇）
  ├── IT Agent（PC・アカウント）
  └── Finance Agent（経費精算）
※ どの部門宛かはSupervisorのLLMが自然言語から判断（人間がルーティング表を書かない）

【SageMaker Pipelines】Agentそのものは登場しない。裏方のMLOps
問い合わせ本文 → (前処理) → 部門分類モデルの学習/評価/デプロイパイプライン
※ この分類モデルを「Step Functionsの分類Lambda」や「AgentCore上のAgent」がツールとして呼ぶ

【AgentCore】自作Supervisorを本番運用基盤の上で動かす
AgentCore Runtime
  ↓
Supervisor Agent（Strandsで自作、Agents as Toolsパターン）
  ├── HR Agent
  ├── IT Agent
  └── Finance Agent
  （各Agentが AgentCore Memory / Gateway（社内API） / Bedrock Knowledge Base を利用）
※ Multi-Agent Collaborationと構造は似て見えるが、「Supervisorの実体を自分で書く」「Bedrock Agents縛りがない（LangGraph等でも可）」「Memory/Gateway/Identity/Observabilityが本番運用機能として一体化している」点が違う
```

## 10. 判断フローチャート

```text
Q1. MLモデル（分類・回帰・独自モデル）の学習・評価・デプロイが目的か？
      Yes → SageMaker Pipelines
      No  → Q2へ

Q2. 複数のAWSサービスにまたがる業務プロセス全体（承認待ち・長時間ジョブ含む）を制御したいか？
      Yes → Step Functions（GenAI呼び出しは1タスクとして組み込む）
      No  → Q3へ

Q3. 生成AI処理をノードベースの軽量ワークフローとして組み立てたいか？（複雑な自律判断は不要）
      Yes → Bedrock Flows
      No  → Q4へ

Q4. Bedrock Agentsの枠内で完結する、部門別・役割別の複数Agent協調がしたいか？
      Yes → Multi-Agent Collaboration
      No  → Q5へ

Q5. 自分でAgentのロジック（Strands/LangGraph等）を書き、それを企業規模で
    本番運用（多数ユーザー・長時間タスク・記憶・認可・監視）したいか？
      Yes → AgentCore
```

### 単純化しすぎないための組み合わせパターン

実務では単独ではなく組み合わせが基本形になる。

```text
① Step Functions → AgentCore → 複数Agent
   業務プロセス全体（承認・監査ログ・他システム連携）はStep Functionsが統括しつつ、
   GenAIの自律判断が必要な1ステップだけAgentCore上のAgentに委譲する

② Bedrock Flows → Agent（Agent node）→ AgentCore
   Flowsで軽量な入力振り分けを行い、複雑なタスクだけAgentCore上のAgentに渡す
   （Flowsの1ノードとして呼び出すAgentがAgentCoreにデプロイされている、という二層構成）

③ SageMaker Pipelines → (Model Registry) → AgentCore Gateway → Agent
   SageMaker Pipelinesが学習・デプロイした独自モデルのエンドポイントを、
   AgentCore Gatewayがツール化し、AgentCore上のAgentがそれを呼び出す

④ AgentCore（Supervisor自作）→ A2A → 他社/他部門のAgentCore Runtime
   自組織のSupervisor AgentがA2Aプロトコル経由で、別インフラ上のAgentと連携する
```

いずれの組み合わせも「事前定義ワークフロー（Step Functions/Flows/Pipelines）が外側の骨格を作り、内側の自律判断が必要な部分だけAgentic（Multi-Agent CollaborationまたはAgentCore上の自作Agent）に任せる」という**入れ子構造**が基本パターンになる。

## 11. 一言で覚えるなら

```text
Step Functions
→ AWS全体のワークフロー
  ただし、GenAI固有の概念（Prompt/KB/Guardrail）は持たず、Agent呼び出しは1つのTaskとして
  外側から扱うだけ。Agentの中身（推論ロジック）には一切関与しない。

Bedrock Flows
→ GenAI処理のワークフロー
  ただし、ノード間の遷移は人間が事前定義するConditionノードの条件式評価であり、
  ノードグラフ自体がLLMのように意味を理解して分岐するわけではない。

Multi-Agent Collaboration
→ Agent同士の協調
  ただし、Bedrock Agents専用のマネージド機能。Bedrock外のフレームワークで書いたAgentは
  Collaboratorにできない。AgentCoreとは別物で、AgentCore自体がSupervisorになるわけではない。

SageMaker Pipelines
→ MLライフサイクルのワークフロー
  ただし、Agentを複数動かす汎用オーケストレーターではない。Agentが使うツール（モデル）を
  作る・再学習するための裏方であり、Agent自体のオーケストレーションはしない。

AgentCore
→ Agentの本番運用基盤
  ただし、AgentCore自体は「次に何をすべきか」を判断しない。判断ロジック（オーケストレーション）
  はStrands/LangGraph等で書いたAgentのコード側にあり、AgentCoreはそれを安全に動かし続ける
  ためのRuntime/Memory/Gateway/Identity/Observabilityを提供するだけ。
```

## 試験でのひっかけポイント整理

- 「複数のAI/Agentを動かせるサービスはどれも同じ役割」→ 誤り。次の処理を決める主体（人間の事前定義 vs LLMの実行時判断）とオーケストレーション対象（AWS全体/GenAIパーツ/MLライフサイクル/Bedrock Agent同士/自作Agentコード）がサービスごとに異なる
- 「Step Functionsの条件分岐やBedrock FlowsのConditionノードは、LLMが意味を理解して分岐先を決めている」→ 誤り。どちらも人間があらかじめ書いた条件式（閾値・ルール）を評価するだけで、LLM推論が介在するのはノード/タスクの中身のみ
- 「Multi-Agent CollaborationとAgentCoreは競合するマルチエージェント機能」→ 誤り。Multi-Agent CollaborationはBedrock Agents専用のマネージド機能、AgentCoreは任意のフレームワークで自作したAgent（Supervisor含む）を本番運用するための基盤で、レイヤーが異なる。AgentCore自身がSupervisorとして動くわけではない
- 「SageMaker Pipelinesは複数のAgentを連携させる汎用オーケストレーターとしても使える」→ 誤り。SageMaker Pipelinesの対象はMLモデルの前処理〜デプロイに限定され、Agent自体のオーケストレーションには使わない
- 「AgentCoreはSageMakerで学習したモデルを使うための専用サービスである」→ 誤り。AgentCoreはモデル非依存・フレームワーク非依存の実行基盤であり、SageMakerで学習した独自モデルもBedrockの基盤モデルも、AgentCore上のAgentから見れば等しく「ツール/頭脳の選択肢」の1つに過ぎない
- 「AgentCoreで複数Agentを連携させるには必ずA2Aプロトコルを使う必要がある」→ 誤り。同一Runtime内で完結するなら（Strandsの）Agents as Toolsパターンで十分。A2Aは別Runtime・別フレームワーク・別組織など疎結合な連携が必要な場合の選択肢
- 「Bedrock FlowsのAgent nodeは、Agentのロジックそのものをノードとして再実装する機能である」→ 誤り。Agent nodeは既存のBedrock Agent（Alias）を1ノードとして呼び出すだけで、AgentのロジックはFlows側に持ち込まれない
- 「AgentCore MemoryもMulti-Agent CollaborationのSupervisorも、会話の長期記憶を同じように扱える」→ 誤り。Multi-Agent Collaborationの主眼はルーティング（インテント分類とタスク委譲）であり、セッション横断の長期記憶管理はAgentCore Memoryの役割。両者は別軸の機能
