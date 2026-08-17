# ストリーミング応答（ConverseStream API / WebSocket / SSE）

LLMの応答は生成に数秒〜数十秒かかることがあり、**生成し終わった文章を一括で返す**より**生成されたトークンから順次クライアントに届ける**方がユーザー体感（Time To First Byte）が大きく改善する。このノートは、Bedrock側の「どのAPIでストリーミングを受け取るか」と、それをクライアント（ブラウザ等）まで届ける際の「どの転送プロトコルを使うか」を分けて整理する。

## Bedrock側：Converse APIとストリーミング

| API | 挙動 | レスポンスの形 |
|-----|------|------------------|
| `Converse` | 生成が完了するまで待ち、完成した応答を1回で返す | 単一のJSONオブジェクト |
| `ConverseStream` | 生成されたトークン（チャンク）を都度イベントとして返す | **イベントストリーム**（複数のイベントが順次届く） |
| `InvokeModel` | Converse以前のモデル個別API。完成応答を1回で返す | 単一のJSONオブジェクト（モデルごとにレスポンス形式が異なる） |
| `InvokeModelWithResponseStream` | `InvokeModel`のストリーミング版 | イベントストリーム（モデルごとにチャンク形式が異なる） |

- `Converse`/`ConverseStream`はモデル横断で**リクエスト/レスポンス形式が統一**されている（`InvokeModel`系はモデルプロバイダごとに形式が異なり、ツール呼び出し等の書き方も個別対応が必要だった）。新規実装では`Converse`系を使うのが基本
- ストリーミングを使うかどうかは**呼び出すAPIオペレーションの選択**であって、エンドポイントやリージョンが変わるわけではない（Bedrock Runtimeエンドポイントは共通）

### ConverseStreamのイベント種別

`ConverseStream`のレスポンスは複数のイベントが順に流れてくる構造で、代表的なものは以下。

| イベント | タイミング | 内容 |
|----------|------------|------|
| `messageStart` | 応答生成の開始時 | ロール（assistant）などのメタ情報 |
| `contentBlockDelta` | トークン生成のたび | 実際に増分で届くテキスト・ツール入力の断片（**これの積み上げが応答本文になる**） |
| `contentBlockStop` | 1つのコンテンツブロック終了時 | ブロックの区切り |
| `messageStop` | 応答生成の終了時 | 終了理由（`stopReason`: `end_turn`、`tool_use`、`max_tokens`等） |
| `metadata` | 最後 | トークン使用量（usage）やレイテンシ等 |

```python
import boto3

client = boto3.client("bedrock-runtime")

response = client.converse_stream(
    modelId="anthropic.claude-3-5-sonnet-20241022-v2:0",
    messages=[{"role": "user", "content": [{"text": "AWSのストレージサービスを3つ挙げて"}]}],
)

for event in response["stream"]:
    if "contentBlockDelta" in event:
        print(event["contentBlockDelta"]["delta"]["text"], end="")
    elif "messageStop" in event:
        print("\n終了理由:", event["messageStop"]["stopReason"])
```

- `boto3`が返す`response["stream"]`はPythonのイテレータであり、内部的にはAWSの**event-stream形式**（バイナリフレーミング + SigV4署名付き）をSDKがパースして扱いやすい辞書に変換してくれている
- クライアント側（Lambda/バックエンド）は受け取ったチャンクを**そのままフロントエンドに中継**するか、いったん結合してから加工するかを設計判断する必要がある

## クライアントへの中継：WebSocket と SSE

Bedrockから受け取ったストリームをブラウザ等のフロントエンドまで届ける際、選択肢は主に2つ。**用途が異なるので「どちらが優れているか」ではなく「双方向が要るか」で選ぶ**。

| | WebSocket | SSE（Server-Sent Events） |
|---|-----------|------------------------------|
| 通信方向 | **双方向**（全二重）。クライアント→サーバーもサーバー→クライアントも自由に送れる | **単方向**（サーバー→クライアントのみ）。クライアントからの追加送信は別途HTTPリクエストが必要 |
| プロトコル | 独自プロトコル（`ws://` / `wss://`）。HTTPでハンドシェイクした後、専用のフレーム形式に切り替わる（Upgrade） | 通常のHTTP/HTTPS上で完結（`Content-Type: text/event-stream`のレスポンスを流し続けるだけ） |
| 接続の持続 | 明示的にクローズするまで持続するコネクション | HTTPのコネクションを流用（切断時はクライアント側`EventSource`が自動再接続する仕組みを標準で持つ） |
| クライアント実装 | `WebSocket`オブジェクトを自前でハンドリング（再接続・再送はアプリ側で実装） | ブラウザ標準の`EventSource` APIが再接続・イベントIDによる再開に対応済み（実装がシンプル） |
| LLMの応答ストリーミングとの相性 | オーバースペックになりがち（応答はサーバー→クライアントの一方向で十分なことが多い） | **素直に合う**（サーバーから増分テキストを送り続けるだけのユースケース） |
| 向いているケース | チャットの相互送信、共同編集、リアルタイム通知の双方向やり取りなど、クライアントからも頻繁に送る必要がある場合 | LLMの応答をトークン単位で流し込むだけ、進捗通知など、サーバー→クライアントの一方向配信で十分な場合 |

```
# SSEのレスポンス例（プレーンテキストのイベントストリーム）
HTTP/1.1 200 OK
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive

data: {"delta": "AWS"}

data: {"delta": "の"}

data: {"delta": "ストレージ"}

data: [DONE]
```

## AWS上での構成パターン（エンドポイントの違い）

Bedrockのストリーミング応答をブラウザまで中継するAWSサービスの組み合わせ。

| 構成 | エンドポイント形式 | 特徴 |
|------|----------------------|------|
| API Gateway **WebSocket API** + Lambda | `wss://` | 双方向が必要な場合の定番。接続ごとに`connectionId`が発行され、Lambdaから`PostToConnection`で任意タイミングにpushできる。**接続の管理（$connect/$disconnect）を自前でハンドリングする必要がある** |
| **Lambda関数URL**（レスポンスストリーミング, `InvokeMode: RESPONSE_STREAM`） + SSE | `https://` | Lambda単体でSSE形式のチャンク応答をストリーミング可能。API Gatewayを挟まずシンプルに構成できる（ただしAPI Gateway REST/HTTP APIは現状レスポンスストリーミングに非対応な点に注意） |
| ALB（Application Load Balancer） + ECS/EC2 | `https://` | 長時間コネクション・chunked transferを扱いやすく、SSE配信のバックエンドとしてもよく使われる |

- API Gateway **REST API**はレスポンスの一括バッファリングが前提で、SSEのような長時間ストリーミング配信には不向き（タイムアウトも短い）。ストリーミングを扱うなら**WebSocket API**か、**Lambda関数URLのレスポンスストリーミング**を検討する、という整理を押さえておく

## 試験でのひっかけポイント整理

- 「ConverseStreamはConverseと別のエンドポイント・別のリージョン設定が必要」→ 誤り。同じBedrock RuntimeエンドポイントでAPIオペレーション（`Converse` vs `ConverseStream`）を切り替えるだけ
- 「WebSocketの方がSSEより高機能だから常にWebSocketを使うべき」→ 誤り。LLMの応答配信のようにサーバー→クライアントの一方向で十分なら、実装が単純で標準の自動再接続も備えるSSEの方が適切なことが多い。双方向のやり取りが必須な場合にWebSocketを選ぶ
- 「SSEは専用プロトコル・専用ポートが必要」→ 誤り。SSEは通常のHTTP/HTTPS上の`text/event-stream`レスポンスであり、追加のプロトコルやポートは不要
- 「API Gateway REST APIでもストリーミング配信に何の問題もなく使える」→ 誤り。REST APIはレスポンスバッファリングが前提でストリーミングに不向き。WebSocket APIやLambda関数URLのレスポンスストリーミングを使う
- 「ConverseStreamのレスポンスは1つのJSONオブジェクトとして届く」→ 誤り。`messageStart`/`contentBlockDelta`/`messageStop`等、複数のイベントが順次届くイベントストリームであり、本文は`contentBlockDelta`の積み上げで組み立てる
