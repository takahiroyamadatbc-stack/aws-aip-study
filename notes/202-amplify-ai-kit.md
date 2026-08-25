# AWS Amplify AI Kit

## これは何か

**AWS Amplify AI Kit**は、AWS Amplify Gen 2（TypeScriptベースのコードファーストなフルスタック開発フレームワーク）の一部として提供される、**生成AI機能をフルスタックアプリに組み込むための機能群**。バックエンド（Amazon Bedrockの基盤モデル呼び出し、認証・認可、データ永続化）とフロントエンド（React等のUIコンポーネント・フック）の両方を、Amplifyの宣言的なバックエンド定義（TypeScriptコード）から一気通貫でプロビジョニングできる点が特徴。

Amplifyはもともと「認証（Cognito）・データ（AppSync/GraphQL＋DynamoDB）・ストレージ（S3）を数行の設定でフルスタックアプリに追加できる」ツールだったが、AI Kitはこれと同じ開発体験を**生成AI機能**（Bedrockモデルとの会話・構造化データ生成）にも拡張したもの、と捉えると理解しやすい。

## バックエンドでの定義: 2種類のAI Route

Amplify Dataのスキーマファイル（`amplify/data/resource.ts`）の中で、通常のデータモデル定義と同じ書き方でAI機能を宣言する。

| Route | 定義方法 | 役割 |
|---|---|---|
| **Conversation route** | `a.conversation()` | Bedrockモデルとの**マルチターンの会話**を扱う。会話履歴（メッセージのやり取り）の永続化・管理までAmplify側が自動的に面倒を見る |
| **Generation route** | `a.generation()` | プロンプトと**構造化された出力スキーマ**（`a.schema()`で定義するJSON形状）を指定し、Bedrockモデルに1回のリクエストで構造化データを生成させる。会話履歴は持たない単発の生成用途 |

- どちらのRouteも、裏側で呼び出すBedrockのモデルID（例: Anthropic Claudeの各モデル）をバックエンド定義側で指定する
- モデル呼び出しに必要なBedrockへのIAM権限（`bedrock:InvokeModel`等）は、Amplifyがバックエンドのデプロイ時に**自動的にプロビジョニング**する。開発者がIAMポリシーを手書きする必要がない

### Conversation routeの会話履歴管理

- 会話（Conversation）とその中のメッセージ（Message）は、Amplify Dataの管理するDynamoDBテーブルに自動的に永続化される
- 開発者が独自にDynamoDBテーブルを設計してメッセージ履歴を保存するコードを書く必要がない（Bedrock Agents／Knowledge Basesのセッション管理とは異なり、Amplify側のデータレイヤーがこれを担う）

## フロントエンドでの利用: React Hooks / UIコンポーネント

Amplify UI（Reactコンポーネントライブラリ）にAI Kit専用のフック・コンポーネントが用意されており、バックエンドで定義したRouteをフロントエンドから型安全に呼び出せる。

| 要素 | 役割 |
|---|---|
| `useAIConversation` フック | Conversation routeに対応。メッセージの送受信、会話履歴の取得、ストリーミング応答の受信をReactの状態として扱える |
| `useAIGeneration` フック | Generation routeに対応。構造化データ生成の呼び出しと結果取得をReactの状態として扱える |
| `<AIConversation>` UIコンポーネント | チャットUI（メッセージリスト・入力欄・送信ボタン等）をあらかじめ組み立てた状態で提供する、いわゆる「ドロップイン」コンポーネント |

- レスポンスは**ストリーミング**に対応しており、Bedrockからのトークン逐次生成をフロントエンドにリアルタイムで反映できる
- 認証はAmplify Auth（Cognito）と統合されているため、「ログイン済みユーザーだけが会話できる」「ユーザーごとに会話履歴を分離する」といった制御が、Amplifyの標準的な認可ルール（owner-based authorization等）でそのまま実現できる

## 他のBedrock関連サービスとの役割の違い

AIP-C01では「生成AIをアプリに組み込む」機能が複数登場するため、AI Kitがどの層を担うかを他と混同しないことが重要。

| サービス／機能 | 位置づけ |
|---|---|
| **Amplify AI Kit** | **フルスタックアプリ開発者向け**の統合機能。バックエンド定義（TypeScript）からBedrock呼び出し・認証・データ永続化・フロントエンドUIまでを一気通貫で構築する。Amplifyというフレームワークに閉じた機能 |
| **Bedrock Knowledge Bases** | RAG（検索拡張生成）のビルディングブロックAPI。ベクトル検索と生成を組み合わせるが、フロントエンドUIやアプリ全体の認証・データ層は提供しない |
| **Bedrock Agents／Flows** | タスク実行・オーケストレーションのためのAPI。同様にアプリ全体のスタック（認証・UI等）は担わない |
| **Amazon Q Developer** | IDE統合の**コーディング支援**アシスタント。AI Kitのように「自分のアプリにAI機能を組み込む」ためのものではなく、開発者自身の開発作業を支援する別カテゴリの製品 |

AI Kitは「Bedrockモデル呼び出し」という点ではKnowledge Bases／Agentsと重なるように見えるが、**Amplifyというフルスタックフレームワークの中でフロントエンドまで含めて完結させる**という立ち位置が独自であり、RAGの高度な検索チューニングやマルチステップのエージェント的タスク実行を高度に制御したい場合はKnowledge Bases／Agentsの方が適する場面もある、という使い分けになる。

## 試験でのひっかけポイント整理

- 「Amplify AI KitはBedrockの新しいモデルの一種である」→ 誤り。AI Kitはあくまで**Amplifyフレームワーク側の開発機能**で、内部的にBedrockの既存モデルを呼び出す仕組み。モデル自体を提供するものではない
- 「Conversation routeを使うには、開発者が自分でDynamoDBテーブルを設計して会話履歴を保存する必要がある」→ 誤り。会話・メッセージの永続化はAmplify Dataが自動的に管理する
- 「AI Kitで呼び出すBedrockモデルへのIAM権限は、開発者が手動でポリシーを作成してアタッチする必要がある」→ 誤り。バックエンド定義（`a.conversation()`／`a.generation()`）のデプロイ時にAmplifyが自動的にプロビジョニングする
- 「マルチターンの会話が必要な場合もGeneration routeを使う」→ 誤り。会話履歴を伴うやり取りにはConversation route（`a.conversation()`）を使う。Generation route（`a.generation()`）は履歴を持たない単発の構造化データ生成用途
