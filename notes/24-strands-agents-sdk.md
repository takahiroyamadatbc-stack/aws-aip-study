# Strands Agents SDK

AgentCore（エージェントの本番運用基盤）は[23-bedrock-agentcore.md](23-bedrock-agentcore.md)を参照。このノートはAWSがOSSとして公開している**エージェント構築用SDK**であるStrands Agentsを扱う。AgentCoreがホストするフレームワークの1つという位置づけ。

## Strands Agentsとは何か

- AWSがOSS（Apache 2.0）で公開している、Pythonでエージェントを構築するための軽量SDK
- コンセプトは**「モデル駆動（model-driven）」**：LangGraphのようにグラフ・状態遷移を明示的に定義するのではなく、「モデル・ツール・プロンプト」の3要素を渡すだけで、**次に何をすべきかの判断（ツールを呼ぶか／このまま回答するか）をモデル自身の推論ループに委ねる**、最小限の構成が基本
- Bedrock専用ではなく**モデル非依存（model-agnostic）**。Bedrock上のFMだけでなく、Anthropic API直接呼び出し、OpenAI、Ollama（ローカルモデル）など複数のモデルプロバイダに対応する
- 内部の実行ループはReActパターンに近い（推論→ツール呼び出し→観測→再推論を繰り返す）が、Bedrock Agentsのようにコンソールで構成要素（Action Group等）を定義する形ではなく、**Pythonコードとしてエージェントを記述する**点が大きな違い

## 最小構成の例

```python
from strands import Agent, tool

@tool
def get_order_status(order_id: str) -> str:
    """注文IDから配送状況を取得する"""
    return f"注文{order_id}は配送中です"

agent = Agent(
    model="anthropic.claude-3-5-sonnet-20241022-v2:0",  # Bedrock経由のモデルID
    tools=[get_order_status],
    system_prompt="あなたはカスタマーサポート担当です。注文状況の確認はget_order_statusツールを使ってください。",
)

response = agent("注文12345の配送状況を教えて")
```

- `@tool`デコレータを付けたPython関数がそのままエージェントの使えるツールになる（Bedrock Agentsのように別途OpenAPIスキーマやFunction定義をJSONで書く必要がない）
- 関数のdocstringと型ヒントがツールの説明としてモデルに渡され、「どのツールを使うべきか」の判断材料になる（Bedrock AgentsのAction Group `description`と同じ役割）

## Bedrock Agents / AgentCoreとの関係整理

| | Bedrock Agents | Strands Agents SDK | AgentCore |
|---|-----------------|----------------------|-----------|
| 何であるか | Bedrockコンソール/APIでエージェントを**構成する**マネージドサービス | Pythonでエージェントを**コードとして実装する**OSSフレームワーク | 実装したエージェントを**本番運用する**ためのインフラ（Runtime/Gateway/Memory/Identity等） |
| ツール定義方法 | OpenAPIスキーマ or Function定義（JSON） | `@tool`デコレータ付きPython関数 | （SDK/フレームワークに依存。AgentCore自体はGatewayでLambda等をMCPツール化） |
| モデル | Bedrock上のFMが前提 | モデル非依存（Bedrock/Anthropic API/OpenAI/Ollama等） | モデル非依存 |
| 実行先 | Bedrockのマネージド実行環境（サーバーレス、非公開） | どこでも実行可能（ローカル、Lambda、ECS、**AgentCore Runtime**など） | Strands含む任意のフレームワークで書かれたエージェントをホスト可能 |

**試験で問われやすい構図**: 「Strands Agents SDKでエージェントのロジックを書き、AgentCore Runtimeにデプロイして本番運用し、AgentCore Memory/Identity/Gatewayで記憶・認可・外部ツール連携を持たせる」という**組み合わせ**が典型パターン。3つは競合ではなく別レイヤーの技術。

## マルチエージェント構成のパターン

Strands Agentsは単一エージェントだけでなく、複数エージェントを組み合わせる構成もサポートする。

| パターン | 概要 | 向いているケース |
|----------|------|-------------------|
| Agents as Tools | 別のAgentをそのまま`@tool`として親Agentに渡し、親が必要に応じて子Agentを呼び出す | 専門特化した子Agent（例: 予約担当、返金担当）をオーケストレーターがルーティングする構成 |
| Swarm | 複数のAgentが対等な立場で協調し、タスクを分担・引き継ぎしながら進める | 明確な階層がなく、Agent同士が動的に連携すべきタスク |
| Graph | Agent/処理ステップをノードとした有向グラフで、実行順序・分岐を明示的に定義する | 実行フローを厳密に制御したい場合（LangGraphに近い発想） |
| Workflow | あらかじめ定義した手順（ステップ列）に沿ってAgentを順次実行する | 定型的な多段処理（データ取得→要約→レビュー等） |

## デプロイ

Strands Agents自体はフレームワークなので、実行環境は選ばない。AgentCore Runtimeへのデプロイも`bedrock-agentcore-starter-toolkit`から行える。

```bash
# Strandsで書いたエージェントをAgentCore Runtimeへデプロイ
agentcore configure --entrypoint agent.py
agentcore launch
```

## 試験でのひっかけポイント整理

- 「Strands Agents SDKはBedrock専用でBedrock上のFMしか使えない」→ 誤り。モデル非依存で、Anthropic API直接・OpenAI・ローカルモデル（Ollama）なども利用できる
- 「Strands AgentsとBedrock Agentsは同じものの別名にすぎない」→ 誤り。Bedrock Agentsはマネージドサービスとして**コンソール/APIで構成する**もの、Strands Agentsは**Pythonコードとして実装する**OSSフレームワークで、作り方のレイヤーが異なる
- 「Strands Agentsで作ったエージェントはAgentCore Runtime以外では動かせない」→ 誤り。ローカル・Lambda・ECS等どこでも実行可能で、AgentCore Runtimeはデプロイ先の選択肢の1つに過ぎない
- 「Strandsのツールは必ずOpenAPIスキーマで定義する必要がある」→ 誤り。`@tool`デコレータを付けたPython関数をそのままツールとして渡せる
- 「マルチエージェント構成はGraphパターンしかサポートしない」→ 誤り。Agents as Tools、Swarm、Graph、Workflowなど複数のパターンをサポートする
