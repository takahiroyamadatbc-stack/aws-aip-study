# Amazon Bedrock AgentCore

Bedrock Agentsの構成要素（基盤モデル・インストラクション・Action Group・KB紐づけ）は[22-bedrock-knowledge-bases-and-agents.md](22-bedrock-knowledge-bases-and-agents.md)を参照。エージェントのロジックをコードとして実装するOSSフレームワークについては[24-strands-agents-sdk.md](24-strands-agents-sdk.md)を参照。このノートはAgentCoreを扱う。

## Bedrock AgentsとAgentCoreは何が違うのか

両者は**置き換え関係ではなく別物**。試験でも混同を狙われやすいので、まずここを区別する。

| | Bedrock Agents | Bedrock AgentCore |
|---|-----------------|---------------------|
| 何を提供するか | Bedrock上で完結する「エージェントそのものの作り方」（FM選択・インストラクション・Action Group・KB紐づけ） | 自作したエージェントを**本番環境で動かすための運用基盤**（実行環境・記憶・認証・監視・ツール連携） |
| 対応フレームワーク | Bedrock Agents専用のオーケストレーション（ReActパターン） | **フレームワーク非依存**。LangGraph、CrewAI、Strands Agents、あるいはBedrock Agents自体で作ったエージェントもホスト可能 |
| 対応モデル | Bedrock上のFMが前提 | **モデル非依存**。Bedrock外のモデルを使うエージェントでもホストできる |
| 位置づけ | 「エージェントの頭脳（オーケストレーション）」を作る仕組み | 「エージェントの頭脳をどう動かし続けるか（デプロイ・スケール・記憶・認可・可観測性）」を提供する仕組み |

## AgentCoreを構成するサービス群

AgentCoreは単一サービスではなく、複数のマネージド機能の集合。

| コンポーネント | 役割 | 主な設定・特徴 |
|-----------------|------|------------------|
| AgentCore Runtime | エージェント/ツールのコードをホストするサーバーレス実行環境 | セッションごとにmicroVMで分離（他セッションとメモリ・ファイルシステムを共有しない）。長時間実行タスク（最大8時間）に対応。コンテナ化したエージェントコードをデプロイする |
| AgentCore Gateway | 既存のAPI（Lambda関数、OpenAPI、Smithyモデル）をエージェントから呼び出せる**MCP互換ツール**に変換して公開する | エージェント側は個々のAPI仕様を意識せず、Gateway経由でMCPツールとして呼び出すだけでよい。ツールをMCP対応に作り直す必要はない |
| AgentCore Memory | セッション内の会話文脈（短期記憶）と、セッションをまたいだユーザーの嗜好・要約（長期記憶）をマネージドに保持する | 短期記憶（Short-term）はそのセッションの会話履歴、長期記憶（Long-term）は要約・セマンティック情報・ユーザー設定などを戦略（Strategy）ごとに抽出・保存する |
| AgentCore Identity | エージェントが「誰の代わりに（on-behalf-of）」動作しているかを管理し、外部リソースへの認可を安全に扱う | Inbound Auth（誰がこのAgentを呼び出せるか）とOutbound Auth（Agentが外部API・SaaSに代理アクセスする際のOAuthトークン等の安全な保管・受け渡し）の両方をカバー。人間ユーザー自体の認証（IdP）そのものではない |
| AgentCore Observability | エージェントの実行トレース・ログ・メトリクスを収集する | OpenTelemetry準拠でトレースを送出し、CloudWatch GenAI Observabilityで可視化できる |
| AgentCore Browser Tool | エージェントがWebブラウザを安全なサンドボックス内で操作できるようにする組み込みツール | ライブビュー（VNC的な画面共有）で実行中の操作を人間が確認できる |
| AgentCore Code Interpreter | エージェントがコードを安全なサンドボックス内で実行できるようにする組み込みツール | 複数言語に対応し、Runtimeと同様にセッション分離される |
| AgentCore Evaluations | エージェントの応答品質・タスク遂行度（ゴール達成率、ツール選択の妥当性など）をセマンティックに継続評価する | 本番のライブトラフィックをサンプリングして継続的にスコア化する**オンライン評価**と、任意のデータセットに対する**オフライン評価**の両方に対応。組み込み評価子（`Builtin.GoalSuccessRate`＝ゴール達成率、`Builtin.ToolSelectionAccuracy`＝ツール選択精度など）でマルチステップのトレースを評価する。結果はAgentCore Observability/CloudWatchに統合される。Bedrock Model Evaluationとの違いは[50-model-evaluation.md](50-model-evaluation.md)参照 |

## デプロイの流れ（イメージ）

AgentCore Runtimeへのデプロイは、エージェントコードをコンテナ化してデプロイする流れが基本。`bedrock-agentcore-starter-toolkit`（CLI）を使うと、コンテナ化〜ECRへのpush〜Runtime登録までを簡略化できる。

```bash
# starter toolkitでエージェントの実行設定を作成（Dockerfile自動生成等）
agentcore configure --entrypoint agent.py

# ビルド〜ECR push〜AgentCore Runtimeへのデプロイ
agentcore launch
```

```bash
# 素のAWS CLIでRuntimeを直接作成する場合のイメージ
aws bedrock-agentcore-control create-agent-runtime \
  --agent-runtime-name my-agent \
  --agent-runtime-artifact '{"containerConfiguration": {"containerUri": "<ECR_IMAGE_URI>"}}' \
  --role-arn <AGENTCORE_RUNTIME_ROLE_ARN>
```

Gateway経由でLambda関数をMCPツールとして公開する場合は、Gatewayを作成した上でLambdaを「ターゲット」として紐づける。

```bash
# Gateway作成
aws bedrock-agentcore-control create-gateway \
  --name my-gateway \
  --protocol-type MCP \
  --role-arn <GATEWAY_ROLE_ARN>

# 既存Lambda関数をGatewayのターゲット（MCPツール）として追加
aws bedrock-agentcore-control create-gateway-target \
  --gateway-identifier <GATEWAY_ID> \
  --name order-lookup-tool \
  --target-configuration '{"mcp": {"lambda": {"lambdaArn": "<LAMBDA_ARN>"}}}'
```

## 試験でのひっかけポイント整理

- 「AgentCoreはBedrock Agentsの後継サービスで、Bedrock Agentsは非推奨になった」→ 誤り。両者は併存しており、目的が異なる（Bedrock Agents＝Bedrock内で完結するエージェントの作り方、AgentCore＝任意のフレームワークで作ったエージェントの本番運用基盤）
- 「AgentCoreはBedrockのFMを使うエージェントしかホストできない」→ 誤り。フレームワーク非依存・モデル非依存で、Bedrock外のモデルを使うエージェントもホストできる
- 「AgentCore Memoryはセッションをまたいだ長期記憶しか扱わない」→ 誤り。セッション内の短期記憶とセッション横断の長期記憶の両方を管理する
- 「AgentCore Gatewayを使うには、呼び出したいAPI側を事前にMCP対応で作り直す必要がある」→ 誤り。既存のLambda/OpenAPI/SmithyをGatewayがMCP互換ツールに変換して公開してくれる
- 「AgentCore Identityは人間ユーザー向けの認証基盤（IdP）である」→ 誤り。エージェントが人間に代わって外部リソースにアクセスする際の認可（Inbound/Outbound Auth）を扱うものであり、人間ユーザーの認証そのものではない
- 「エージェントのゴール達成率やツール選択精度は、Bedrock Model Evaluation（`CreateEvaluationJob` API）で継続評価できる」→ 誤り。同APIの`applicationType`は`ModelEvaluation`／`RagEvaluation`の2値のみで、マルチステップのエージェントトレースを評価対象とする種別は存在しない。エージェント特化の継続的な品質評価はAgentCore Evaluationsの役割（詳細は[50-model-evaluation.md](50-model-evaluation.md)参照）
