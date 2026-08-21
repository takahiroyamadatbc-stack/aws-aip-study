# Amazon Bedrock Knowledge Bases と Agents

RAGそのものの基本原理（Indexing/Retrieval/Generation）やAWS上の選択肢比較、提供元によらない高度なRAG技術は [21-rag-basics.md](21-rag-basics.md) を参照。このノートはBedrockでの実装詳細（Knowledge Bases、GraphRAG、Agents）を扱う。

## Bedrock Knowledge Bases 深掘り

### 全体アーキテクチャ

```
データソース(S3等) --(ingestion job)--> チャンク分割 --> Embeddingモデル --> ベクトルストア
                                                                                    ↑
ユーザークエリ --> RetrieveAndGenerate / Retrieve API --------------------------------┘
```

### データソースとIngestion（同期）の仕組み

- データソースはS3のほか、Webクローラ、Confluence、Salesforce、SharePointなどのコネクタに対応
- データソースの実データは**KB作成時にコピーされない**。同期（sync）操作を明示的に実行するまで反映されない
- **Ingestion Job**: データソースの同期を実行するジョブ。新規/変更/削除されたドキュメントを検出し、チャンク分割・Embedding化・ベクトルストアへの反映まで行う
- 同期は**フル同期**が基本（差分検出はKB側が自動でハッシュ比較して行うため、変更のないドキュメントは再Embedding化されない＝コスト最適化されている）
- 同期は自動スケジュールではなく、**API呼び出し（StartIngestionJob）またはコンソール操作で明示的にトリガー**する必要がある点に注意（S3にファイルを置いただけでは検索対象にならない）

```bash
# データソースの同期（Ingestion Job）を開始
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id <KB_ID> \
  --data-source-id <DATA_SOURCE_ID>

# 同期状況の確認
aws bedrock-agent get-ingestion-job \
  --knowledge-base-id <KB_ID> \
  --data-source-id <DATA_SOURCE_ID> \
  --ingestion-job-id <JOB_ID>
```

### データソース

| データソース | 概要 | 接続・認証 | 主な用途・特徴 |
|--------------|------|------------|------------------|
| Amazon S3 | バケット/プレフィックス配下のオブジェクトを取り込む、最も基本的なデータソース | IAMロール（KBの実行ロールにバケットへの読み取り権限を付与） | 既にS3にドキュメントを集約済みの場合の標準的な選択肢。他コネクタもS3経由での取り込みが内部的なベースになる |
| Confluence | Confluenceのスペース/ページを取り込む | OAuth2.0クライアント認証情報（Confluence側でアプリ登録） | 社内Wiki・ナレッジベースをそのままRAG対象にしたい場合 |
| SharePoint | SharePoint Online のサイト/ドキュメントライブラリを取り込む | Azure ADアプリ登録によるOAuth認証 | Microsoft 365中心の社内文書基盤をRAG対象にしたい場合 |
| Salesforce | Salesforceのオブジェクト（Knowledge記事等）を取り込む | OAuth（接続アプリ設定） | CRM/サポートナレッジ記事を検索対象にしたい場合 |
| Web Crawler | 指定したシードURLから配下のWebページをクロールして取り込む | 不要（公開Webページ）。クロール範囲はURLフィルタ（include/exclude）とクロール深度で制御 | 社外公開サイト・ヘルプセンター・ドキュメントサイトをそのまま取り込みたい場合。`robots.txt`の制約を尊重する点、クロール範囲を絞らないと想定外のページまで取り込む点に注意 |

### ドキュメントパース（Parsing）

チャンク分割の前段で、元ドキュメントからテキストを抽出する処理。**パーサーの選択はデータソースごと（正確にはドキュメントの種類ごと）に設定でき、チャンク戦略と同様に検索精度を左右する重要な設定**。

| パーサー | 概要 | 得意なこと | 注意点 |
|----------|------|------------|--------|
| デフォルトパーサー | Bedrock標準のテキスト抽出。追加コストなし・高速 | プレーンテキスト中心のドキュメント（txt, md, html, csvや、レイアウトが単純なPDF） | 表・グラフ・画像など、レイアウトに意味があるコンテンツはうまく解釈できず情報が欠落しやすい |
| Foundation Model パーサー | マルチモーダル対応のFM（Claude等）にドキュメントを読み込ませ、意味を理解した上でテキスト化する | 複雑なレイアウトのPDF、表、グラフ、図表の説明生成など、デフォルトパーサーが苦手なコンテンツ | FM呼び出し分の**追加コストと処理時間**が発生する。使用するFMをKB作成時に指定する |
| Amazon Textract | OCR（光学文字認識）に特化した抽出サービスをパーサーとして利用 | スキャン画像・スキャンPDF、手書き文字、フォーム（キーバリュー）や表の高精度抽出 | 主に**画像/スキャン文書由来**のテキスト抽出に強みがあり、デジタル生成PDFの意味理解が目的のFMパーサーとは狙いが異なる |
| Bedrock Data Automation（BDA） | 文書・画像・音声・動画などマルチモーダルなデータから構造化インサイトを抽出するAWSサービスをパーサーとして利用 | カスタムブループリントで抽出したい項目・スキーマを定義するなど、より高度で構造化された情報抽出が必要な場合。文書以外のモダリティ（画像・音声・動画）も含む取り込みパイプラインに統一したい場合 | 4つの中で最も高機能だが設定・コスト面の考慮が必要。単純なテキスト抽出だけならオーバースペックになりやすい |

**選び方の目安**: テキスト主体ならデフォルトパーサー、表・グラフなどレイアウトの意味理解が必要ならFoundation Modelパーサー、スキャン文書・手書きならAmazon Textract、文書以外のモダリティも含めて構造化抽出したいならBedrock Data Automation。

### チャンク戦略（Chunking Strategy）

KB作成時にデータソースごとに選択する。試験では「どれを選ぶべきか」がよく問われる。

| 戦略 | 挙動 | 向いているケース |
|------|------|-------------------|
| Fixed-size chunking | 固定トークン数＋overlapで機械的に分割（デフォルト） | 汎用。まず迷ったらこれ |
| Default chunking | Fixed-sizeのAWS推奨デフォルト値版 | 特にチューニング不要な場合 |
| Hierarchical chunking | 親チャンク（大）と子チャンク（小）の階層構造を保持。検索は子チャンクの精度、生成は親チャンクの文脈量を両立 | 検索精度と文脈の広さを両立したい場合 |
| Semantic chunking | 文の意味的なまとまり（トピックの切れ目）で分割 | 構造化されていない長文ドキュメント |
| No chunking | 1ドキュメント＝1チャンクとして扱う | 事前に十分小さく整形済みのデータ |
| カスタムチャンク（Lambda） | Lambda関数で独自の分割ロジックを実装 | 表・コード・特殊フォーマットなど既存戦略で精度が出ない場合 |

### Retrieve API と RetrieveAndGenerate API

| | Retrieve | RetrieveAndGenerate |
|---|----------|----------------------|
| やること | ベクトル検索のみ実行し、関連チャンクを返す | 検索＋FMによる回答生成まで一括で行う |
| 生成（FM呼び出し）の制御 | 呼び出し側が持つ（独自プロンプトに組み込む等、柔軟） | KB側が内部でプロンプトテンプレート適用〜生成まで行う（簡単・お手軽） |
| 向いているケース | 検索結果を自作のプロンプトやAgentの一部に組み込みたい場合 | すぐにQ&A応答が欲しい場合 |
| セッション管理 | なし | `sessionId` を使ってマルチターン会話の文脈を保持できる |

```bash
# 検索だけ行う（Retrieve）
aws bedrock-agent-runtime retrieve \
  --knowledge-base-id <KB_ID> \
  --retrieval-query '{"text": "料金プランの違いは？"}'

# 検索＋生成まで一括（RetrieveAndGenerate）
aws bedrock-agent-runtime retrieve-and-generate \
  --input '{"text": "料金プランの違いは？"}' \
  --retrieve-and-generate-configuration '{
    "type": "KNOWLEDGE_BASE",
    "knowledgeBaseConfiguration": {
      "knowledgeBaseId": "<KB_ID>",
      "modelArn": "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0"
    }
  }'
```

### 検索方式の指定（セマンティック/ハイブリッド検索・リランキング）

各手法の一般的な概念・解決する課題は[21-rag-basics.md](21-rag-basics.md)の「Retrieval（検索フェーズ）」を参照。ここではBedrock Knowledge Basesでの指定方法のみ整理する。

| 手法 | Bedrock Knowledge Basesでの指定 |
|------|------------------------------------|
| セマンティック検索 | デフォルトの検索方式（`SEMANTIC`）。追加設定不要 |
| ハイブリッド検索 | `retrievalConfiguration`の`overrideSearchType`に`HYBRID`を指定（対応するベクトルストア、例: OpenSearch Serverlessが必要） |
| リランキング | `rerankingConfiguration`でリランクモデル（Amazon Rerank / Cohere Rerank等）を指定 |

メタデータフィルタリングの指定方法は次節を参照。

### メタデータフィルタリング

- 各チャンクにメタデータ（例: `department: sales`、`year: 2025`）を付与しておき、検索時に`retrievalConfiguration`でフィルタ条件を指定できる
- 「全文書を検索対象にしつつ、特定部署・特定期間の文書だけに絞りたい」というマルチテナント/アクセス制御的な要件で使う
- ただしAmazon Qのようなドキュメントレベル自動ACL反映とは異なり、**フィルタ条件はアプリ側が明示的に組み立てる**必要がある（KBが自動でユーザーの権限を判定してくれるわけではない）
- S3データソースの場合、メタデータは各オブジェクトと同じプレフィックスに置く`<object-key>.metadata.json`で付与する（例: `report.pdf` に対して `report.pdf.metadata.json`）

```json
{
  "metadataAttributes": {
    "contentType": { "value": { "type": "STRING", "stringValue": "transcript" } },
    "publishedDate": { "value": { "type": "STRING", "stringValue": "2025-01-15" } }
  }
}
```

```bash
# Retrieve時にcontentTypeで絞り込む例（RetrievalFilter）
aws bedrock-agent-runtime retrieve \
  --knowledge-base-id <KB_ID> \
  --retrieval-query '{"text": "速報の内容は？"}' \
  --retrieval-configuration '{
    "vectorSearchConfiguration": {
      "filter": { "equals": { "key": "contentType", "value": "transcript" } }
    }
  }'
```

#### 他サービスでの同種の実装との比較

「検索範囲を絞りたい」という要件に対して、KBのメタデータフィルタ以外にもOpenSearch・Q Businessが選択肢として並ぶことがある。試験では「既存アーキテクチャへの変更を最小限にする」等の制約が決め手になるため、機能の有無だけでなく実装の重さまで比較する必要がある。

| 観点 | Bedrock KB（メタデータフィルタ） | Amazon OpenSearch Service（生のベクトル検索） | Amazon Q Business |
|------|-----------------------------------|--------------------------------------------------|---------------------|
| メタデータの持たせ方 | S3データソースなら `<object-key>.metadata.json`（上記参照） | インデックスのマッピングでフィールド定義し、bulk API等でベクトルと一緒に格納 | コネクタの属性マッピング設定でDocument Attributesとして定義 |
| フィルタの適用方法 | `Retrieve`/`RetrieveAndGenerate`の`retrievalConfiguration`（RetrievalFilter）に`equals`/`in`/`greaterThan`/`andAll`等を指定 | k-NNクエリに`bool`の`filter`句を組み合わせるOpenSearch DSLをアプリ側で構築（[29-opensearch-service.md](29-opensearch-service.md)参照） | `Chat`/`ChatSync` APIの`attributeFilter`パラメータ、またはUI上のフィルタ設定 |
| 既存アーキテクチャへの影響 | **なし。** KB・データソース・ベクトルストアはそのまま。メタデータJSONを追加して再Ingestionするだけ | **大。** マネージドなKB経由の検索から、生のOpenSearchクエリを書く独自実装への置き換えが必要（KBが内部でOpenSearch Serverlessをベクトルストアに使っていても、それを直接叩く実装に変えるのは別物） | **大。** 開発者向けAPI統合（Bedrock）から、フルマネージドのエンドユーザー向けチャットアプリへの移行そのもの |
| アクセス制御との関係 | フィルタ条件は**アプリ側が明示的に組み立てる**（自動ACL反映ではない） | FGACで別レイヤーの制御は可能だが、検索クエリのフィルタとは別物 | IAM Identity Center連携でドキュメントレベルのACLが**自動で**検索結果に反映される |

**見落としやすい前提**: RAGは「Indexing（事前準備・都度ではない）→ Retrieval（推論のたびに毎回）」という非同期の2段構成（[21-rag-basics.md](21-rag-basics.md)）。S3はIngestion時にドキュメントを取り込む**データソース**であり、検索（Retrieve）のたびにS3へ読みに行くわけではない。実際に検索対象になるのはKB作成時に指定したベクトルストア（OpenSearch Serverless等）であり、S3自体の読み取り速度は検索レイテンシの原因にならない。応答が遅い原因を問う設問で「S3は遅そうだから」という直感だけで選択肢を判断しない。

### Guardrails・Citationとの統合

- `RetrieveAndGenerate`にBedrock Guardrailsを適用し、生成結果に有害コンテンツフィルタ・トピック制限をかけられる
- レスポンスには根拠となったチャンクの引用（citation: どのS3オブジェクトのどの部分か）が含まれ、ハルシネーション検証・出典表示に使える

### Bedrock Agentsとの関係

- Knowledge Basesは、Agentに紐づけられる知識ソースの1つとして扱われる。Agentが「この質問にはKB検索が必要」と判断した場合に自動でRetrieveを呼び出す構成が可能
- 単体のRAG（KB単体でRetrieveAndGenerate）と、Agent経由のRAG（Agentが動的にKB呼び出しを判断）は別物として区別して問われることがある
- Agentそのものの構成要素（基盤モデル・インストラクション・Action Group・KBの紐づけ）は後述の「Bedrock Agents」を参照
- 作成したAgentを本番環境で運用するための実行基盤（デプロイ・記憶・認可・可観測性）については[23-bedrock-agentcore.md](23-bedrock-agentcore.md)を参照

## GraphRAG（Amazon Neptune）

GraphRAGそのものの概念（解決したい課題・向いているケース・通常のベクトルRAGとの違い）は[21-rag-basics.md](21-rag-basics.md)を参照。ここではAWSでの実装を扱う。

| 項目 | 内容 |
|------|------|
| 使うAWSサービス | Amazon Neptune Analytics（グラフ分析エンジン） |
| Bedrock Knowledge Basesとの統合 | ベクトルストアの選択肢としてNeptune Analyticsを指定すると、Ingestion時にチャンクからエンティティ・関係を自動抽出してグラフを構築し、ベクトルインデックスと併用する構成が組める |
| 検索時の挙動 | ベクトル類似検索でエントリーポイントとなるノード（関連度の高いエンティティ）を特定し、そこからグラフを探索して関連するエンティティ・関係もあわせてコンテキストに追加する |

## Bedrock Agents

Bedrock Agentsは、FMに「外部アクションの実行」と「知識検索」を組み合わせた**自律的なタスク遂行**をさせるための仕組み。RAG（Knowledge Bases）は「情報を検索して回答する」機能に閉じるのに対し、Agentは検索に加えてAPI呼び出し（社内システムの更新など）まで含めた一連のタスクを、ユーザーの1つの発話から**自分で計画・実行**できる点が違い。構成要素は大きく4つ。

| 構成要素 | 役割 | 設定内容の要点 |
|----------|------|------------------|
| 基盤モデルの選択 | Agentの「頭脳」。次に何をすべきか（Action Groupを呼ぶか／KB検索するか／このまま回答するか）を判断するオーケストレーションを担う | どのFM（推論プロファイル含む）を使うか選択する。複雑な判断・多段のツール選択が必要ならClaude Sonnet系などの高性能モデル、単純な処理でレイテンシ・コストを優先するならHaiku系などの軽量モデルを選ぶ。**Agentのオーケストレーション用モデルと、紐づけたKB単体のRetrieveAndGenerateで使うモデルは別々に設定できる**（独立した設定値） |
| インストラクションの記述 | Agentの役割・振る舞い・判断基準を定義するシステムプロンプト相当のテキスト | ①Agentのペルソナ・対応範囲、②いつAction GroupやKnowledge Baseを使うべきかの判断基準、③出力フォーマット・トーン、④やってはいけないこと、を明確に書く。曖昧な指示はオーケストレーション精度の低下（誤ったアクション選択・KB未使用など）に直結する |
| Action Groupの定義 | Agentが実行できる外部アクション（API呼び出し）の集合 | アクションとパラメータを**OpenAPIスキーマ**または**Function定義（シンプルな関数リスト）**のどちらかで定義し、実行主体としてLambda関数を紐づける（もしくはLambdaを介さず呼び出しパラメータをそのままアプリ側に返す「Return control」も選択可）。Agentは各アクションの`description`を読んで「今回のタスクにはどのアクションが必要か」を判断するため、descriptionの書き方が精度を左右する |
| Knowledge Baseの紐づけ | Agentが参照できる社内知識（RAG）を追加する | 既存のBedrock Knowledge Baseを1つ以上紐づけられる。紐づけ時に指定する`description`（このKBが何の情報を持つか）をAgentが読んで「このタスクにはこのKBを使うべきか」を判断する。複数のKBを紐づけて用途別に使い分けさせることも可能 |

### オーケストレーションの流れ（ReActパターン）

Agentは以下のループ（ReAct: Reasoning + Acting）を、最終回答が出せると判断するまで繰り返す。

```
ユーザー入力
  → (インストラクション + 利用可能なAction Group/KBのdescriptionを踏まえて)
     Agentが「次に何をすべきか」を推論
  → 必要ならAction Group呼び出し（Lambda実行）またはKnowledge Base検索（Retrieve）を実行
  → 実行結果を踏まえて再度「次に何をすべきか」を推論（複数回繰り返すこともある）
  → 十分な情報が揃ったら最終回答を生成
```

### 作成・変更の反映（Prepare / Alias）

- Agentの設定（インストラクション・Action Group・KB紐づけ）を変更しただけでは本番トラフィックに反映されない。**Prepare操作**でDRAFTバージョンをテスト可能な状態にビルドする必要がある
- 本番運用では、DRAFTを直接使わず**Alias**（特定バージョンへのポインタ）を発行し、Aliasに対してリクエストを送るのが基本パターン（新バージョンの検証→切り替えを安全に行うため）

```bash
# Agent作成
aws bedrock-agent create-agent \
  --agent-name my-support-agent \
  --foundation-model anthropic.claude-3-5-sonnet-20241022-v2:0 \
  --instruction "あなたはカスタマーサポート担当です。注文状況の確認はorder-lookupアクションを使い、製品仕様の質問はKnowledge Baseを検索してから回答してください。" \
  --agent-resource-role-arn <AGENT_ROLE_ARN>

# Action Groupの追加（Lambda + Function定義の例）
aws bedrock-agent create-agent-action-group \
  --agent-id <AGENT_ID> \
  --agent-version DRAFT \
  --action-group-name order-lookup \
  --action-group-executor '{"lambda": "<LAMBDA_ARN>"}' \
  --function-schema '{"functions": [{"name": "get_order_status", "description": "注文IDから配送状況を取得する", "parameters": {"order_id": {"type": "string", "required": true}}}]}'

# Knowledge Baseの紐づけ
aws bedrock-agent associate-agent-knowledge-base \
  --agent-id <AGENT_ID> \
  --agent-version DRAFT \
  --knowledge-base-id <KB_ID> \
  --description "製品マニュアル・FAQを検索する"

# DRAFTの変更をビルド
aws bedrock-agent prepare-agent --agent-id <AGENT_ID>
```

### マルチエージェントコラボレーション（Supervisor / Collaborator）

単一のAgentにインストラクション・Action Group・KBを詰め込むのではなく、**役割ごとに独立した複数のAgentを協調させる**ための機能。チームリーダー（スーパーバイザー）が各専門メンバー（コラボレーター）に仕事を振り分けるイメージ。

| 役割 | 実体 | 役割の内容 |
|------|------|------------|
| スーパーバイザーエージェント | 通常のBedrock Agentの一種（`agentCollaboration`を有効化したもの） | ユーザー入力を受け取り、各コラボレーターの役割・責任（登録時の説明文）をもとに**自然言語のインテント分類**を行い、適切なコラボレーターにタスクをルーティングする。必要に応じて複数コラボレーターの結果を統合して最終回答を生成する |
| コラボレーターエージェント | それ自体が独立したBedrock Agent（専用のAlias） | 特定ドメインに特化。独自のインストラクション・Action Group・Knowledge Base・Guardrailsを個別に持てる。スーパーバイザーから受け取ったサブタスクを処理し、結果を返す |

- コラボレーターは既存の（単体でも動く）Bedrock Agentをそのまま登録できる。**新しい部門・機能を追加する際はコラボレーターを1つ追加するだけで済み**、既存のコラボレーターやスーパーバイザーの設定に影響しない＝拡張性が高い
- ルーティングは**手動のハンドオフ処理を実装する必要はない**。スーパーバイザーが自然言語で意図を判定して自動的に振り分ける
- スーパーバイザー配下の並行処理・スケーリングはBedrockのマネージド機構が自動で行うため、数千件規模の同時インタラクションにも別途スケーリング設計は不要
- 複数の独立したスーパーバイザーを並列運用する構成は**非推奨**。ユーザーの入力が複数部門にまたがる場合にどのスーパーバイザーへ振り分けるかという上位のルーティング問題が未解決のまま残り、外部ロジックでの統合はレイテンシ増加・応答の一貫性低下を招く。**単一のスーパーバイザーが全体を統括する階層モデル**が基本

**コラボレーションモード（`agentCollaboration`パラメータ）**

| モード | 挙動 |
|--------|------|
| `DISABLED` | マルチエージェント機能を使わない通常のAgent（デフォルト） |
| `SUPERVISOR` | スーパーバイザー自身も推論ループを持ち、コラボレーターの結果を踏まえて追加の判断・統合処理を行うフルオーケストレーション |
| `SUPERVISOR_ROUTER` | ルーティングに特化した軽量モード。該当するコラボレーターへほぼそのまま振り分け、追加の推論処理を最小限にすることでレイテンシを抑える |

```bash
# スーパーバイザーエージェントを作成（マルチエージェントコラボレーションを有効化）
aws bedrock-agent create-agent \
  --agent-name patient-care-supervisor \
  --foundation-model anthropic.claude-3-5-sonnet-20241022-v2:0 \
  --agent-collaboration SUPERVISOR \
  --instruction "患者からの問い合わせ内容に応じて、臨床・保険確認・予約・保険請求の担当コラボレーターに振り分けてください。" \
  --agent-resource-role-arn <AGENT_ROLE_ARN>

# 既存のコラボレーターエージェント（Alias単位）をスーパーバイザーに関連付け
aws bedrock-agent associate-agent-collaborator \
  --agent-id <SUPERVISOR_AGENT_ID> \
  --agent-version DRAFT \
  --agent-descriptor '{"aliasArn": "<COLLABORATOR_AGENT_ALIAS_ARN>"}' \
  --collaborator-name clinical-inquiry-agent \
  --collaboration-instruction "臨床的な問い合わせ（症状、診療内容の確認等）を担当します" \
  --relay-conversation-history TO_COLLABORATOR
```

## Bedrock Prompt Management と Flows

Agentsがモデル自身に「次に何をすべきか」を判断させる自律的な仕組みなのに対し、Prompt ManagementとFlowsは**プロンプト・処理ステップの流れを人間があらかじめ設計する**、よりロコード寄りのオーケストレーション機能。

### Prompt Management

- プロンプトテンプレート（変数を埋め込んだ文言＋使用するモデル＋推論パラメータ）を、Bedrock側のリソースとしてバージョン管理する機能（`CreatePrompt` / `CreatePromptVersion` / `GetPrompt` 等のAPI）
- 1つのプロンプトに対して複数の**バリアント**（モデル・テンプレート文言・推論パラメータが異なる組み合わせ）を持たせられる。A/Bで試したい複数のプロンプト案を、同じプロンプトリソースの中で管理する用途に使える

### Flows

- プロンプトノード・条件分岐ノード（Condition）・Knowledge Baseノード・Lambda関数ノード・S3等のストレージノードなどを、有向グラフとしてビジュアルに繋いでワークフローを構築するオーケストレーション機能
- **Prompt node**は、Prompt Managementで管理しているプロンプト（バリアント含む）をFlowの1ノードとして呼び出せるノード種別
- Prompt nodeには、`Converse`/`InvokeModel`呼び出しに`guardrailConfig`を渡すのと同様に、**ノード単位でGuardrailを関連付けられる**。これにより、Flow内の特定ノードの入出力にだけGuardrailの評価（コンテンツフィルタ・拒否トピック・PII検出等）を適用する構成が組める

### Guardrailsの介入とCloudWatch連携

- Bedrock Guardrailsは呼び出しごとに、介入回数やポリシー種別ごとのブロック数などをCloudWatchメトリクスとして送信する
- そのメトリクスに対してCloudWatch Alarmを設定し、しきい値超過時にSNS通知等へつなげられる（GuardrailsのモニタリングとアラートはFlows特有の機能ではなく、Guardrails単体の標準機能）

**誤解しやすい点**: Guardrailsが評価するのは「その1回の入出力テキストが有害か／PIIを含むか／拒否トピックに触れているか」であり、**属性グループ（性別・年齢・出身地域等）ごとに出力を分類・比較する機能はGuardrails自体には存在しない**。「属性グループ間でスコアやブロック率にどれだけ差があるか」を見たい場合、呼び出し側が属性グループの情報を保持し、ログやカスタムメトリクスのディメンションとして別途付与する実装が必要になる。

### SageMaker Model MonitorはBedrock呼び出しに直接は適用できない

[26-sagemaker-ai-ml-pipeline.md](26-sagemaker-ai-ml-pipeline.md)のSageMaker Model Monitorは、**SageMakerエンドポイントにデプロイしたモデル**の入出力を対象にした監視サービスであり、Bedrockのマネージド基盤モデル呼び出し（SageMakerエンドポイントを経由しない呼び出し）には標準では統合されない。Bedrockの呼び出しログをSageMaker Model Monitorが読み込める形式に変換する橋渡しが必要になる。

## 試験でのひっかけポイント整理

- 「S3にファイルを置けば自動的にKnowledge Basesの検索対象になる」→ 誤り。Ingestion Job（同期）を明示的に実行する必要がある
- 「Retrieve APIも回答文を生成してくれる」→ 誤り。生成まで行うのはRetrieveAndGenerate。Retrieveは検索結果（チャンク）を返すだけ
- 「AgentにKnowledge Baseを紐づけられるのは1つだけ」→ 誤り。複数のKBを紐づけ、それぞれのdescriptionをAgentが読んで用途別に使い分けられる
- 「Action GroupはOpenAPIスキーマでしか定義できない」→ 誤り。シンプルなFunction定義（関数リスト形式）でも定義できる
- 「Agentの設定を変更すると即座に本番トラフィックへ反映される」→ 誤り。DRAFTの変更はPrepare操作でビルドし直す必要があり、本番運用は特定バージョンを指すAliasに対して行うのが基本
- 「Agentが使うオーケストレーション用のFMと、紐づけたKB単体のRetrieveAndGenerateで使うFMは常に同じものになる」→ 誤り。両者は独立して設定できる別々のモデル選択
- 「Bedrock Guardrailsは属性グループ間の出力の偏り（公平性メトリクス）を自動的に計算・比較してくれる」→ 誤り。Guardrailsが評価するのは1回の入出力テキスト単位の有害性・PII・拒否トピック等であり、複数呼び出しを属性グループ別に集計・比較する機能はネイティブには持たない
- 「SageMaker Model MonitorはBedrockのモデル呼び出しにもそのまま適用できる」→ 誤り。Model MonitorはSageMakerエンドポイントを対象にした監視サービスで、Bedrockのマネージド呼び出しには標準で統合されない
- 「マルチエージェント構成は、単一Agent内に複数のAction Groupを設定すれば実現できる」→ 誤り。Action Groupはあくまで1つのAgentが呼び出すAPI/Lambda機能の集合であり、ドメインごとに独立した推論能力を持つコラボレーターAgentとは別物
- 「部門ごとに個別のスーパーバイザーエージェントを立てるのが正しいマルチエージェント設計」→ 誤り。複数部門にまたがる問い合わせをどのスーパーバイザーに振るかという上位のルーティング問題が残り、手動ハンドオフや外部統合ロジックが必要になりレイテンシ・一貫性が悪化する。**単一のスーパーバイザーが複数のコラボレーターを統括する階層モデル**が正しい構成
