# MCPサーバーのAWSホスティングと認証（Lambda関数URL / SigV4 / OAuth）

ローカルで動いているMCPサーバーを本番のAWS上に公開するとき、決めることは2つある。

1. **トランスポート**（JSON-RPCメッセージをどうやって運ぶか）
2. **エンドポイントの配置と認証**（AWSのどこに置き、誰にどう呼ばせるか）

選択肢がこの2軸を混ぜて書かれることが多く、それが設問の読みにくさの正体になる。まず前提用語を押さえてから、2軸を分けて整理する。

## 前提用語

### stdio（standard input/output｜標準入出力）

プログラムが最初から持っている入出力の口のこと。**標準入力(stdin)** ＝データが流れ込んでくる口、**標準出力(stdout)** ＝データを吐き出す口、**標準エラー出力(stderr)** ＝エラーを吐く口、の3本セット。`cat file.txt | grep foo` のようにパイプで繋げられるのはこの仕組みによる。

MCPにおけるstdioは、**クライアントがMCPサーバーを子プロセスとして起動し、親子プロセス間のパイプでstdin/stdoutを繋いでメッセージを流す**方式を指す。

- ネットワークを一切使わない → **同じマシン上でしか動かない**
- URLもポート番号も認証も不要（プロセスを起動できる時点で、すでにそのマシンの権限を持っているため）
- サーバーはクライアントが起動し、クライアントが終了すれば一緒に終了する

設問文の「開発者のローカルマシン上でMCPサーバーとして動作している」はこのstdio構成を指す。

### JSON-RPC（JSON Remote Procedure Call）

**RPC（リモートプロシージャコール）** ＝別の場所にある関数を、手元の関数を呼ぶのと同じ感覚で呼び出す仕組み。**JSON-RPC** はそのやり取りをJSONで表現する軽量な取り決め（現行はバージョン2.0）。

```jsonc
// リクエスト: method=呼びたい関数名、params=引数、id=応答との対応付け番号
{"jsonrpc":"2.0", "id":1, "method":"tools/call", "params":{"name":"search","arguments":{}}}

// 成功レスポンス
{"jsonrpc":"2.0", "id":1, "result":{"content":[]}}

// エラーレスポンス
{"jsonrpc":"2.0", "id":1, "error":{"code":-32601,"message":"Method not found"}}

// 通知(notification): id が無い＝返事を期待しない一方向メッセージ
{"jsonrpc":"2.0", "method":"notifications/progress", "params":{}}
```

**最重要の性質**: JSON-RPCは「**メッセージの中身の書式**」だけを定めており、「**それをどう運ぶか**」は一切定めていない。だからstdioのパイプでも、HTTPのボディでも、WebSocketでも運べる。

MCPはこの性質を利用して、**中身＝JSON-RPC 2.0に固定し、運び方（トランスポート）だけを複数用意する**設計になっている。「トランスポートを差し替えてもMCPサーバーの実装は変えなくてよい」が成り立つのはこのため。

RESTとの違いも押さえる。RESTは `GET /users/123` のように**URLのパスとHTTPメソッドで操作を表現**する。JSON-RPCは**エンドポイントが1本だけ**で、何をするかは `method` フィールドに書く。→ 後述のStreamable HTTPが `/mcp` という単一エンドポイントになるのはこの帰結。

### SSE（Server-Sent Events）

HTTPの上で、**サーバーからクライアントへ一方向にデータを流し続ける**標準機構。レスポンスの `Content-Type` を `text/event-stream` にして接続を開いたまま保持し、`data:` 行を随時送り込む。

```
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":0.5}}

data: {"jsonrpc":"2.0","id":1,"result":{}}

```

WebSocketと違って**双方向ではない**が、普通のHTTPレスポンスの延長なのでプロキシ・CDN・ロードバランサをそのまま通せる。LLMのトークン逐次出力や、ツール実行の進捗通知に使われる。

### Streamable HTTP

MCPの**リモート用の現行標準トランスポート**（2025-03-26仕様で導入）。単一のHTTPエンドポイント（慣例的に `/mcp`）に対して次のように使う。

| HTTPメソッド | 用途 | レスポンス |
|---|---|---|
| **POST** | クライアント→サーバーへJSON-RPCメッセージを送る | **単発のJSON**（`application/json`）でも、**SSEストリーム**（`text/event-stream`）でもよい |
| **GET** | サーバー→クライアント方向の通知用SSEストリームを開く（任意） | SSEストリーム |
| **DELETE** | セッションの明示終了（任意） | — |

**"Streamable"（ストリーム可能）の意味**は「常にストリームする」ではなく「**必要なときだけストリームに昇格できる**」。短い応答は普通のJSONで即返し、時間がかかる処理や進捗通知が要るときだけ同じエンドポイントでSSEに切り替える。1本のエンドポイントで両対応できるのが旧方式との差。

セッション管理は `Mcp-Session-Id` ヘッダーで行うが、**ステートレスなサーバーはこれを発行しなくてよい**。その場合「POST 1回＝リクエスト/レスポンス1往復で完結」になり、実行環境が毎回使い捨てられるLambdaと噛み合う。設問が「呼び出し間で状態を保持しない」とわざわざ書くときは、この伏線であることが多い。

### OAuth（OAuth 2.0 / 2.1）

**「認可（authorization: 誰が何をしてよいか）」の標準プロトコル**。パスワードそのものを相手に渡さず、**アクセストークン**という期限付きの通行証を渡してAPIを呼ばせる仕組み。

| 役割 | 意味 | MCPでの対応 |
|---|---|---|
| リソースサーバー | 守られているAPI | MCPサーバー（Lambda） |
| 認可サーバー | トークンを発行する主体 | Amazon Cognito User Pool、Auth0、Okta |
| クライアント | APIを呼びたいアプリ | 社内アプリ、パートナーのシステム |
| リソースオーナー | データの持ち主（人間） | エンドユーザー（M2Mでは不在） |

トークンの取り方（**グラント**）が複数あり、どれを使うかで運用が大きく変わる。

- **`authorization_code`** … 人間がログイン画面で同意してトークンを得る。人間ユーザー向け
- **`client_credentials`** … 人間が介在せず、`client_id` と `client_secret` でアプリ自身がトークンを取る。**M2M（Machine to Machine、システム同士の通信）向け**

付随用語:

- **スコープ（scope）**: トークンに書かれる権限範囲（`mcp/tools.invoke` 等）。**自分で設計・定義する必要がある**
- **JWT（JSON Web Token）**: 署名付きJSONで表現したトークン形式。受け手は公開鍵で署名検証すれば、発行元に毎回問い合わせずに中身を信用できる
- **OIDC（OpenID Connect）**: OAuth 2.0の上に「**認証**（authentication: あなたは誰か）」を足した仕様。Cognito User Poolはこれに対応

混同注意: OAuthは厳密には「認可」の仕様であって「認証」の仕様ではない。試験の選択肢には「OAuth認証」と書かれることがあるが、認証まで含めるには本来OIDCが必要。試験では「OAuth＝トークンベースのアクセス制御」と読み替えてよい。

### SigV4（AWS Signature Version 4）

AWSのリクエスト署名方式。リクエストのHTTPメソッド・URL・ヘッダー・ボディのハッシュ・タイムスタンプを決まった順に並べて文字列を作り、**シークレットアクセスキーでHMAC-SHA256署名**して `Authorization` ヘッダーに載せる。受け側のAWSが同じ計算をして一致を確認する。

| | OAuthトークン | SigV4署名 |
|---|---|---|
| 性質 | **持っていれば通る**通行証 | **リクエストごとに計算する**署名 |
| 保護範囲 | 身元のみ | 身元 ＋ **内容の改ざん検知** |
| 有効期限 | 数分〜数時間（トークン自体の期限） | 署名は**既定5分**で失効（タイムスタンプ込みのため） |
| 盗まれたとき | 期限まで悪用可能 | 別のリクエストには流用できない |

## 軸1: MCP仕様上のトランスポート

| トランスポート | 内容 | 状況 |
|---|---|---|
| **stdio** | クライアントがサーバープロセスを起動し、標準入出力でJSON-RPCを往復 | ローカル専用 |
| **Streamable HTTP** | 単一エンドポイントにPOST、必要に応じてSSEへ昇格 | 2025-03-26仕様〜の**現行標準**（リモート用） |
| **HTTP + SSE（旧）** | `/sse` でストリームを開き `/messages` にPOSTする**2エンドポイント**構成 | 2024-11-05仕様。**非推奨**、後方互換のみ |
| **カスタムトランスポート** | JSON-RPC 2.0を運べれば任意の実装でよい、と仕様が許容 | Lambda Invoke API直接呼び出し等 |

つまり「Streamable HTTP以外」は **stdio / 旧SSE / 独自実装** の3つしかなく、**リモート公開に使える標準は実質Streamable HTTP一択**。「MCPプロトコルではなく標準HTTPリクエストを使うよう設定する」という選択肢は、そもそもMCPをやめる提案なので即座に失格。

## 軸2: AWS上のどこに置くか

| 公開経路 | トランスポート | 認証 | 追加インフラ | 呼び出し側の前提 |
|---|---|---|---|---|
| **Lambda関数URL** | カスタムStreamable HTTP | **IAM（SigV4）** | **なし** | AWSアカウント＋SigV4署名できること |
| API Gateway (HTTP/REST API) + Lambda | 標準Streamable HTTP | OAuth（Cognito等のJWT） | API GW + IdP | ただのHTTPクライアントでOK |
| AgentCore Gateway | 標準Streamable HTTP | OAuth（Inbound Auth） | Gateway | 同上 |
| Lambda Invoke API 直接 | **独自（HTTPですらない）** | IAM | なし | **AWS SDK必須** |
| AgentCore Runtime に直接デプロイ | Streamable HTTP（`/mcp` 自動提供） | IAM(SigV4) or OAuth | Runtime | ステートフルMCPが要るとき |
| ALB / ECS Fargate / App Runner / EC2 で自前ホスト | Streamable HTTP | 自前 or OIDC | 多い | 常駐が必要なとき |
| CloudFront + Lambda関数URL (OAC) | カスタムStreamable HTTP | IAM + WAF | CloudFront | WAF／カスタムドメインが要るとき |

上位4つは AWS Labs の `run-mcp-servers-with-aws-lambda` ライブラリがサポートする4方式に対応する。同ライブラリは stdio ベースのMCPサーバーをそのままLambda関数内で実行し、各呼び出しでサーバープロセスの起動・初期化・リクエスト転送・レスポンス返却・プロセス終了のライフサイクルを管理する。

### なぜ「カスタム」Streamable HTTPなのか

Lambda関数URL経由の方式が「**カスタム**Streamable HTTPトランスポート」と表現される理由:

- プロトコルとしては**素のStreamable HTTPのまま**。`/mcp` にJSON-RPCをPOSTするだけ
- ただし関数URLがIAM認証なので、**全リクエストにSigV4署名ヘッダーを付ける必要がある**
- 一般的なMCPクライアントのHTTPトランスポート実装（`fetch` や `httpx` をそのまま使う）には署名機構がない
- → 「送信直前にSigV4署名を挟む」層だけを自作する。**カスタムなのは署名レイヤーだけで、プロトコルは標準のまま**

対してLambda Invoke API直接呼び出しは、**トランスポートそのものが非HTTP**になりMCP標準から外れる。両方「IAM認証」なのに評価が分かれるのはここ。

```python
# Lambda関数URL (AWS_IAM) を SigV4署名で叩く最小例
import boto3, requests
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

REGION = "ap-northeast-1"
URL = "https://xxxxxxxx.lambda-url.ap-northeast-1.on.aws/mcp"
body = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

# パートナー側は自社アカウントから AssumeRole して得た一時認証情報を使う
creds = boto3.Session().get_credentials().get_frozen_credentials()

req = AWSRequest(method="POST", url=URL, data=body, headers={
    "Content-Type": "application/json",
    # Streamable HTTP の要件: JSON と SSE の両方を受け入れる旨を宣言する
    "Accept": "application/json, text/event-stream",
})
SigV4Auth(creds, "lambda", REGION).add_auth(req)   # 署名対象サービス名は "lambda"

resp = requests.post(URL, data=body, headers=dict(req.headers))
```

## Lambda関数URL

### 基本

- 関数に固定のHTTPSエンドポイント `https://<url-id>.lambda-url.<region>.on.aws/` を付与する機能
- **API GatewayもALBも不要**。Lambda単体でHTTPを受けられる
- 1関数につき1つ。`$LATEST` または**エイリアス**に紐づけられる（特定のバージョン番号には直接付けられない）
- 認証タイプは **`AWS_IAM`** か **`NONE`** の2択のみ（この粗さが長所でも短所でもある）
- イベントのペイロード形式は **API Gateway HTTP API の payload format v2.0 と同一**（`requestContext.http.method` 等）。そのためAPI GWからの移行時にハンドラ改修が小さい

### IAM認証まわり

| 項目 | 内容 |
|---|---|
| アクション | `lambda:InvokeFunctionUrl`。**2025年10月以降に作成した関数URLでは `lambda:InvokeFunction` も併せて必要** |
| 同一アカウント | 呼び出し元のアイデンティティベースポリシーだけでOK |
| クロスアカウント | **リソースベースポリシー側でも両アクションの許可が必要** |
| 署名 | SigV4。サービス名 `lambda`、リージョンは関数のリージョン |
| 絞り込み | `aws:PrincipalOrgID` / `aws:SourceIp` / `aws:SourceVpce` 等の条件キーが使える |

```bash
# 関数URL作成（IAM認証・レスポンスストリーミング有効）
aws lambda create-function-url-config \
  --function-name aip-xxx-mcp-server \
  --auth-type AWS_IAM \
  --invoke-mode RESPONSE_STREAM

# パートナーのロールにクロスアカウントで許可（両アクションぶん必要）
for ACTION in lambda:InvokeFunctionUrl lambda:InvokeFunction; do
  aws lambda add-permission \
    --function-name aip-xxx-mcp-server \
    --statement-id "partner-a-${ACTION##*:}" \
    --action "$ACTION" \
    --principal arn:aws:iam::222222222222:role/PartnerAMcpClient \
    --function-url-auth-type AWS_IAM
done
```

「2025年10月以降は2アクション必要」は、それ以前の関数URLが `InvokeFunctionUrl` だけで通っていた名残で、**既存と新規で必要権限が違う**という移行期特有のひっかけ。

### API Gateway HTTP API との比較

| 観点 | Lambda関数URL | API Gateway HTTP API |
|---|---|---|
| 追加料金 | **なし**（Lambda実行料のみ） | 約 $1.00/百万リクエスト |
| タイムアウト | **関数のタイムアウトまで（最大15分）** | **最大30秒**（REST APIは既定29秒、緩和申請で延長可） |
| 認証 | IAM（SigV4）or なし | IAM / Lambda Authorizer / **JWT(OIDC)** |
| レスポンスストリーミング(SSE) | `InvokeMode=RESPONSE_STREAM` で対応 | **非対応** |
| WAF | **直接アタッチ不可**（CloudFront前段が必要） | アタッチ可 |
| カスタムドメイン | **不可**（CloudFront経由が必要） | 可 |
| レート制限・使用量プラン | なし（同時実行数で間接制御） | あり |
| リクエストサイズ | 6MB | 10MB |
| アクセスログ | なし（自分で出力） | あり |
| ルーティング | 単一関数のみ | 複数ルート→複数バックエンド |

MCP用途で効く差は2つ。

1. **タイムアウト15分 vs 30秒**: MCPツールが長時間処理（大きなクエリ、外部API連鎖）をする場合、API Gateway HTTP APIの30秒は現実的な制約になる
2. **レスポンスストリーミング**: Streamable HTTPがSSEでストリーム返却する場合、関数URLは `InvokeMode=RESPONSE_STREAM` が必要。Node.jsは `awslambda.streamifyResponse` でネイティブ対応、**Python等はLambda Web Adapterを挟む**構成になる。ステートレス・単発レスポンスで済むなら既定の `BUFFERED` のままでも動く

### 関数URLが向かないケース

- WAF・カスタムドメイン・きめ細かいレート制限が要件 → CloudFront併用かAPI Gateway
- 呼び出し側がAWSアカウントを持たない → SigV4が署名できないのでOAuth構成へ
- 複数バックエンドを1つのAPIにまとめたい → API Gateway
- APIキー配布・使用量プランによる課金計測が要る → API Gateway

## IAM(SigV4) vs Cognito(OAuth) の運用コスト

### 「IAM認証＝IAMユーザーを人数分作ること」ではない

M2M（人間が介在しないシステム間通信）でIAM認証を組むときの定石は次のとおりで、**IAMユーザーもアクセスキーも作らない**。

1. パートナーごとに**IAMロールを1つ作る**（信頼ポリシーに相手のAWSアカウントIDと `ExternalId` を記載）
2. そのロールに `lambda:InvokeFunctionUrl` / `lambda:InvokeFunction` を**関数ARN限定で**付与
3. パートナーは自分のアカウントから `sts:AssumeRole` → **一時認証情報**を取得 → SigV4署名して呼ぶ

長期アクセスキーの発行はむしろアンチパターン。作るのは「パートナー社数ぶんのロール（数個）」だけで、認証情報はSTSが発行する一時クレデンシャル＝**自動失効するのでローテーション運用が不要**。

「IAMユーザー管理が大変」という感覚が正しくなるのは、**人間のエンドユーザーが多数いてサインアップ・パスワードリセット・MFA・ソーシャルログインが必要なとき**。そのケースではIAMユーザーを人数分作るのは論外で、Cognito（またはIAM Identity Center）が正解になる。感覚そのものは正しいが、適用場面が違う。

### 実際に「作るもの・運用するもの」

| 観点 | Lambda関数URL + IAM(SigV4) | API GW + Cognito(OAuth) |
|---|---|---|
| 作るAWSリソース | Lambda、IAMロール／ポリシー | Lambda、API GW（ステージ・ルート・オーソライザ）、Cognito User Pool（ドメイン・リソースサーバー・カスタムスコープ・app client） |
| パートナー追加時の作業 | ロールを1つ作り、信頼ポリシーに相手アカウントを記載 | app client作成 → **client_secretを安全に配布** → スコープ割当 |
| 認証情報のライフサイクル | STS一時認証情報。**自動失効、ローテーション不要** | client_secretの保管・ローテーション運用が発生 |
| 権限の粒度 | IAMポリシー＋条件キーが最初から使える | OAuthスコープを**自分で設計して**ルートに割り当てる |
| 監査 | CloudTrailに**呼び出しプリンシパル単位で自動記録** | CognitoのログとAPI GWアクセスログを自分で突き合わせ |
| 料金 | 関数URL自体は**追加料金なし** | HTTP API 約 $1.00/百万リクエスト ＋ **Cognito M2M課金**（2024年5月導入。app clientごとの月額＋トークンリクエスト課金）※金額は要確認 |
| 典型的な失敗 | 署名ズレ（端末時刻のずれ、リージョン間違い）で403 | トークン期限切れ、JWKSキャッシュ、スコープ設定漏れ |

**M2Mに限れば、管理対象の数でも料金でもCognitoの方が重い。** Cognitoが軽く感じるのは「人間ユーザーのサインアップ・パスワードリセット・MFA・ソーシャルログインを自前実装しなくてよい」という、M2Mでは発生していない価値の部分。

### 判断の分水嶺（一行ルール）

> **呼び出し側がAWSアカウントを持っているか。**
>
> - 持っている（社内アプリ、AWSを使っているパートナー）→ **IAM/SigV4が圧倒的に楽**。認証情報の配布問題が丸ごと消える
> - 持っていない／AWSに依存させたくない（他クラウド、SaaS、ブラウザ、汎用MCPクライアント）→ **OAuth（Cognito等）が必須**

「最小の運用オーバーヘッド」を最優先する設問は、**パートナーもAWSを使っている前提**を暗黙に置いてIAMを選ばせる。実務では「パートナーがAWSユーザーとは限らない」ので要確認事項になる。

### IAMとCognitoは排他ではない

- **Cognito User Pool** ＝ OIDC/OAuthのIdP。JWTを発行する → API GWのJWTオーソライザで検証
- **Cognito Identity Pool** ＝ 認証済みユーザーに**一時的なIAM認証情報を発行**する部品

したがって「人間ユーザーをCognitoでログインさせ、Identity Poolで一時クレデンシャルを得て、SigV4でLambda関数URLを叩く」という**両方使う構成**も成立する。「CognitoかIAMか」ではなく「**誰が呼ぶか**」で決まる。

### MCP標準の観点（AWSの運用コスト軸とは別）

MCPの認可仕様（2025-06-18版）は**OAuth 2.1ベース**で、MCPサーバーをOAuthのリソースサーバーとみなし、`WWW-Authenticate` ヘッダーとProtected Resource Metadata（RFC 9728）で認可サーバーを発見させる、と定めている。つまり**「MCP標準に準拠した認可」は本来OAuth側**であり、SigV4/IAMはAWS独自の代替手段。

AWS運用コスト軸ではIAMが勝つが、**汎用MCPクライアント（Claude Desktop等）との相互運用性ではOAuthが有利**。試験の「正解」は「AWS内で完結する前提での運用コスト最小」であって「MCP的に最も正統」ではない、という二層構造を押さえておくと、似た設問で軸を見失わない。

## 試験でのひっかけポイント整理

- 「Lambda Invoke APIを使うカスタムトランスポートなら追加インフラ不要で運用オーバーヘッドが最小」→ 誤り。**トランスポートが非HTTP**になりMCP標準から外れる。呼び出し側にAWS SDKを強制するためサードパーティ統合が複雑化し、カスタム実装の保守コストも乗る
- 「API Gateway + APIキーで厳格な認証・認可を実現できる」→ 誤り。APIキーは**呼び出し元の身元を検証しない**（単にアクセスを制限するだけ）ため「厳格な認証・認可制御」を満たさない
- 「MCPサーバーへのアクセスを標準HTTPリクエストに置き換えればよい」→ 誤り。MCPの標準的なツール呼び出し・リソースアクセスの仕組みが失われ、MCPクライアントとの互換性がなくなる
- 「API Gateway HTTP API + CognitoのOAuthが最小の運用オーバーヘッド」→ 誤り。認証の厳格さは満たすが**API GatewayとCognitoの2サービスが増える**。M2Mではスコープ設計・client_secret配布・トークン管理が乗り、Lambda関数URL + IAMより明確に重い
- 「Lambda関数URLをIAM認証にするには `lambda:InvokeFunctionUrl` だけ付与すればよい」→ **2025年10月以降に作成した関数URLでは誤り**。`lambda:InvokeFunction` も必要。クロスアカウントではリソースベースポリシー側にも両方必要
- 「Lambda関数URLはAPI Gatewayと同じくWAFをアタッチできる」→ 誤り。直接アタッチできず、WAFが要件ならCloudFrontを前段に置く
- 「Lambda関数URLでもAPI Gateway HTTP APIでもタイムアウトは同じ」→ 誤り。関数URLは関数のタイムアウト（最大15分）まで使えるが、HTTP APIは最大30秒
- 「IAM認証を選ぶとユーザーを人数分作る必要があり運用が重い」→ M2Mでは誤り。ロール＋AssumeRoleで済み、一時認証情報は自動失効するためローテーション運用が不要

### キーフレーズの読み方

| 設問の文言 | 読み取るべきこと |
|---|---|
| 「最小の運用オーバーヘッド」＋AWS内で完結 | **Lambda関数URL + IAM(SigV4)** |
| 「厳格な認証・認可」 | APIキーは即除外。SigV4かOAuthの二択 |
| 「サードパーティパートナー」 | **AWSアカウントを持つ前提か**を他の文言から読む。AWSへの言及がなければOAuth寄り |
| 「ステートレス」「呼び出し間で状態を保持しない」 | Lambda等の使い捨て実行環境でOKというヒント。ステートフルならAgentCore Runtime |
| 「MCPサーバーとして公開」 | トランスポートはStreamable HTTPを維持すること（独自HTTP APIへの置き換えは失格） |

## 関連ノート

- [23-bedrock-agentcore.md](23-bedrock-agentcore.md) … AgentCore Gateway（既存Lambda/OpenAPI/SmithyをMCP互換ツールに変換して公開）、AgentCore Identity（Inbound/Outbound Auth）
- [04-agent-orchestration-services-comparison.md](04-agent-orchestration-services-comparison.md) … MCPとA2Aの役割の違い、AgentCore Runtime自体をステートフルMCPサーバーとして動かす選択肢
- [25-streaming-responses.md](25-streaming-responses.md) … SSEによるストリーミング応答の扱い
