# 004 マルチエージェントオーケストレーション（Strands Agents SDK vs Step Functions自前実装）

## 問題
<!-- 模擬試験 問67 -->
コンテンツメディア企業が、調査エージェント・要約エージェント・レポート作成エージェントの3専門エージェントで構成される週次レポート自動生成のマルチエージェントシステムを構築しようとしている。各エージェントの中間成果物を次のエージェントへ引き渡し、最終的に1つのレポートに集約する必要がある。エージェントの推論ループ・ツール呼び出し・エージェント間のコンテキスト引き渡しを自前実装せず、フレームワーク組み込み機能で賄いカスタムオーケストレーションコードを最小化したい。

- A（正解）: Strands Agents SDKを採用し、SDKのWorkflowパターンで3エージェントをパイプライン状に結線する。前のエージェントの出力が自動的に次のエージェントのコンテキストとして引き渡される。
- B: AWS Step FunctionsのParallel/Mapステートで3つのLambda関数（それぞれBedrockを呼ぶ）を結線し、ステートマシンの入出力変換で結果を受け渡す。
- C: 3つのLambda関数をAmazon SQSキューで直列に結線し、状態管理・コンテキスト引き継ぎ・リトライロジックを各Lambda内に実装する。
- D: 各エージェントをAmazon ECSコンテナとしてデプロイし、Amazon SQSで疎結合に接続。ルーティング・コンテキスト管理・エラー処理を各コンテナ内に独自実装する。

## 選んだ答えと理由
Bを選択し、不正解（正解はA）。

AとBのどちらでも要件は実装できると理解した上で、「Strands Agents SDK側の方がまだ枯れていないSDKだから、結局Pythonコードを書く量はStep Functions側と大差ないか、むしろ長くなるのでは」と直感で予測してしまい、AWSネイティブなStep Functionsの方が実装が軽そうという印象でBを選んだ。

## 誤答の型
サービスの守備範囲の誤解

Step Functionsが「ステート間のデータ受け渡し・リトライ」という**オーケストレーションの制御**を提供する一方、モデル主導の**推論ループ（ツールを呼ぶか判断→呼び出し→結果解釈→次の判断）**は一切肩代わりしないという守備範囲を過小評価していた。逆にStrands Agents SDKがエージェントループ・ツール呼び出し・コンテキスト受け渡しをWorkflowパターン内部で肩代わりする範囲を過小評価し、両者のコード量の差を逆に予測してしまった。

## 仮説
- Strands Agents SDKのWorkflowパターンを使うと、開発者が書くのはタスク定義（何を・どの順で・どういう依存関係で）だけで済み、推論ループやツール呼び出しのコードは書かなくてよいはず
- Step Functions + Lambda自前実装では、ステートマシン定義（ASL/CDK）に加えて、各Lambda内部に「Bedrock Converse呼び出し＋tool_use判定＋ツール実行＋結果を積み戻すループ」を個別実装する必要があり、特にツールを使うエージェント（調査エージェント）で顕著にコード量が増えるはず
- 結果として、同じ要件を満たすコードの総量はStrands Agents SDK版の方が明確に少なくなるはず

## 検証
実機デプロイは行わず、両方式のコードを実際に書いて行数・実装しなければならない要素を比較した（標準ルール。Bedrockモデル呼び出しに料金が発生するため、標準では実行しない）。

1. [strands/agents.py](strands/agents.py) + [strands/run.py](strands/run.py)
   `strands_tools`の`workflow`ツールを持つオーケストレータエージェントを1つ定義し、`workflow(action="create", tasks=[...])`で3タスク（research → summarize → report、`dependencies`で依存関係を宣言）を登録するだけ。推論ループ・ツール呼び出し・前段結果のコンテキスト引き渡しはすべて`workflow`ツール内部が処理する。

2. [stepfunctions/stack.py](stepfunctions/stack.py)（CDK）
   `LambdaInvoke`タスク3つを`.next()`で直列に結線し、`output_path="$.Payload"`で前段の戻り値をそのまま次段の入力にする。Step Functionsが自動化するのはこの「JSONの受け渡し」だけ。

3. [stepfunctions/src/research_handler.py](stepfunctions/src/research_handler.py)
   調査エージェント役のLambda。`bedrock.converse()`の`stopReason`が`tool_use`である限りループし、ツール実行結果を`messages`へ積み戻して再度モデルを呼ぶ、という推論ループを手動実装している（最大5往復）。この部分がStrands Agents SDK版には存在しない。

4. [stepfunctions/src/summarize_handler.py](stepfunctions/src/summarize_handler.py) / [stepfunctions/src/report_handler.py](stepfunctions/src/report_handler.py)
   ツール呼び出しがない分シンプルだが、それでも「前段のどのキーを読み、どう整形してプロンプトに埋め込むか」は個別実装が必要。

コード行数の実測（コメント・docstring込み）:

| 実装 | ファイル | 行数 |
|------|---------|------|
| Strands Agents SDK | agents.py + run.py | 83行 |
| Step Functions + Lambda | stack.py + Lambda×3 | 227行 |

要素別の比較:

| 実装しなければならない要素 | Strands Agents SDK | Step Functions + Lambda |
|---|---|---|
| エージェント間のオーケストレーション定義 | `workflow`ツールへのタスク定義（宣言的） | CDKでのステートマシン定義（`.next()`チェーン） |
| 前段結果 → 次段コンテキストの引き渡し | フレームワークが自動 | `output_path`でJSONは渡るが、プロンプトへの埋め込みは手動 |
| モデル呼び出し | フレームワークが内包 | 各Lambdaで`bedrock.converse()`を個別に呼ぶ |
| ツール呼び出し判定・実行・結果の積み戻しループ | フレームワークが内包（`tools=[...]`を渡すだけ） | 各Lambdaで手動ループ実装（research_handler.pyが該当） |
| リトライ・タイムアウト | フレームワーク側 or 別途Retry定義が必要 | Step Functionsの組み込み機能で宣言的に設定可能（今回は未使用） |

## 結論（1行）
Strands Agents SDKのWorkflowパターンはエージェントの推論ループ・ツール呼び出し・コンテキスト受け渡しをSDK内部で肩代わりするため、同じ3エージェントパイプラインを実装した場合のコード量はStep Functions+Lambda自前実装（今回の実測で約2.7倍）より明確に少ない。Step Functionsが自動化するのは「ステート間のJSON受け渡し」だけで、モデル主導の推論ループは守備範囲外。

## 片付け
実機デプロイを行っていないため対象リソースなし。`stepfunctions/`をデプロイした場合は当該ディレクトリで`cdk destroy`を実行し、`aws cloudformation list-stacks`で`aip-004-multi-agent-orchestration`が残っていないことを確認する。
