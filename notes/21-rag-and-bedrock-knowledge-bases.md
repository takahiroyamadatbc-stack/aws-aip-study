# RAG（Retrieval Augmented Generation）と Amazon Bedrock Knowledge Bases

## これは何か・なぜ必要か

FM（基盤モデル）は事前学習時点の知識しか持たず、以下の弱点がある。

- **知識のカットオフ**: 学習後に発生した情報や、学習データに含まれない社内固有の情報を知らない
- **ハルシネーション**: 知らないことでも自然な文章で答えてしまう
- **再学習コストの高さ**: 最新情報を反映するたびにFineTuning/事前学習をやり直すのは非現実的

RAGは、FMを再学習せずに、**推論時に外部知識ソースから関連情報を検索し、プロンプトに埋め込んでから生成させる**ことでこれらを解決するアーキテクチャパターン。FM自体の重みは変更しない点がFineTuningとの根本的な違い。

## 基本的な仕組み: Indexing → Retrieval → Generation

RAGは大きく3フェーズに分かれる。**Indexing（事前準備）は1回（または定期更新）**、**Retrieval → Generationは推論のたびに毎回**実行される、という非同期性がポイント。

### 1. Indexing（事前準備フェーズ）

```
生データ(PDF/HTML/DB等) → ロード → チャンク分割 → Embedding化 → ベクトルDBへ格納
```

- **ロード**: S3・Webクローラ・Confluence・SharePointなど様々なソースから元データを取得
- **チャンク分割（Chunking）**: 元データをFMのコンテキスト長やEmbeddingモデルの入力上限に収まる単位に分割する。分割サイズ・重なり幅（overlap）の設計が検索精度を大きく左右する
- **Embedding化**: チャンクをEmbeddingモデル（例: Amazon Titan Text Embeddings、Cohere Embed）に通し、意味を表す高次元ベクトルに変換する
- **ベクトルDBへ格納**: ベクトルと元テキスト・メタデータをベクトルストア（OpenSearch、pgvector、Pineconeなど）にインデックスする

### 2. Retrieval（検索フェーズ）

```
ユーザーの質問 → Embedding化 → ベクトル類似度検索 → 関連チャンクTop-K取得
```

- ユーザーの質問文を、Indexingと**同じEmbeddingモデル**でベクトル化する（モデルが違うとベクトル空間が一致せず検索が成立しない）
- ベクトルDBに対してコサイン類似度などで近傍探索（k近傍探索）を行い、関連度の高いチャンクを上位K件取得する
- 意味的類似検索（semantic search）だけでなく、キーワード検索（BM25等）と組み合わせる**ハイブリッド検索**や、取得結果を再スコアリングする**リランキング（rerank）**を挟むと精度が上がる

### 3. Generation（生成フェーズ）

```
(取得したチャンク + 元の質問) をプロンプトに合成 → FMに投入 → 回答生成
```

- 取得したチャンクを「コンテキスト」としてプロンプトに埋め込み、「このコンテキストの範囲内で回答せよ」という指示とともにFMに渡す（プロンプト拡張）
- FMは学習済みの知識ではなく、**渡されたコンテキストに基づいて**回答を生成するため、最新情報・社内固有情報への対応とハルシネーション抑制の両方が期待できる
- 出典（どのチャンク／ドキュメントを根拠にしたか）を合わせて返すCitation機能を持つ実装も多い

## AWSにおけるRAGの選択肢比較

| 観点 | Amazon Q Business | Bedrock Knowledge Bases | 自己ホストRAG |
|------|-------------------|--------------------------|----------------|
| 位置づけ | フルマネージドの**エンドユーザー向けチャットアプリ** | 開発者がアプリに組み込む**RAGビルディングブロックAPI** | 自前で全パイプラインを構築 |
| 想定利用者 | 業務ユーザー（コード不要で使える） | アプリ開発者（API/SDK経由で呼ぶ） | インフラ・MLエンジニア |
| データ接続 | 50+のビルトインコネクタ（S3, SharePoint, Salesforce, Slack, Confluence等）を設定するだけ | データソースコネクタ（S3, Web Crawler, Confluence, Salesforce, SharePoint等）をKB側で設定 | 自前でETL/ローダーを実装 |
| Embedding/チャンク戦略 | 内部で自動処理（ユーザーは選べない） | Titan/Cohere等から選択可、チャンク戦略も複数選択可、Lambdaでカスタムチャンクも可 | 完全に自由（独自Embeddingモデルも可） |
| ベクトルストア | 非公開（内部管理） | OpenSearch Serverless / Aurora PostgreSQL(pgvector) / Pinecone / Redis Enterprise Cloud / MongoDB Atlas から選択 | 自由に選定・運用 |
| カスタマイズ性 | 低い（UI・権限設定が中心） | 中〜高（チャンク・検索方式・プロンプトテンプレートを制御可） | 最も高い（全レイヤーを制御） |
| 運用負荷 | ほぼゼロ（フルマネージド） | 低い（ベクトルDBの一部はサーバーレス選択可） | 高い（自前でスケーリング・監視） |
| アクセス制御 | ID連携（IAM Identity Center）でユーザー単位のACLをそのまま検索結果に反映（ドキュメントレベルのアクセス許可を尊重） | データソース単位、メタデータフィルタでの制御が中心 | 自前で実装が必要 |
| 主な用途 | 社内ナレッジ検索チャットボットをすぐ使いたい | 独自GenAIアプリ（Bedrock Agentsとも統合）にRAGを組み込みたい | 既存の社内ベクトル基盤がある／特殊なEmbeddingモデルを使いたい／ベンダーロックインを避けたい |

**選び方の基本方針**: 「すぐに使える社内検索チャット」ならAmazon Q Business、「自社アプリにRAG機能を組み込みたい・生成部分もアプリ側で制御したい」ならBedrock Knowledge Bases、「既存ベクトル基盤がある／特殊要件がある」なら自己ホスト、という順で検討する。

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

### メタデータフィルタリング

- 各チャンクにメタデータ（例: `department: sales`、`year: 2025`）を付与しておき、検索時に`retrievalConfiguration`でフィルタ条件を指定できる
- 「全文書を検索対象にしつつ、特定部署・特定期間の文書だけに絞りたい」というマルチテナント/アクセス制御的な要件で使う
- ただしAmazon Qのようなドキュメントレベル自動ACL反映とは異なり、**フィルタ条件はアプリ側が明示的に組み立てる**必要がある（KBが自動でユーザーの権限を判定してくれるわけではない）

### Guardrails・Citationとの統合

- `RetrieveAndGenerate`にBedrock Guardrailsを適用し、生成結果に有害コンテンツフィルタ・トピック制限をかけられる
- レスポンスには根拠となったチャンクの引用（citation: どのS3オブジェクトのどの部分か）が含まれ、ハルシネーション検証・出典表示に使える

### Bedrock Agentsとの関係

- Knowledge BasesはAgentの「アクショングループ」の1つとして紐付けられる。Agentが「この質問にはKB検索が必要」と判断した場合に自動でRetrieveを呼び出す構成が可能
- 単体のRAG（KB単体でRetrieveAndGenerate）と、Agent経由のRAG（Agentが動的にKB呼び出しを判断）は別物として区別して問われることがある

## 試験でのひっかけポイント整理

- 「S3にファイルを置けば自動的にKnowledge Basesの検索対象になる」→ 誤り。Ingestion Job（同期）を明示的に実行する必要がある
- 「Retrieve APIも回答文を生成してくれる」→ 誤り。生成まで行うのはRetrieveAndGenerate。Retrieveは検索結果（チャンク）を返すだけ
- 「Amazon Q BusinessもBedrock Knowledge Basesも同じレベルのカスタマイズ性を持つ」→ 誤り。Amazon Qはエンドユーザー向けフルマネージドアプリでカスタマイズ性は低く、Bedrock KBは開発者がアプリに組み込むビルディングブロックでカスタマイズ性が高い
- 「チャンク戦略はどれを選んでも精度に差は出ない」→ 誤り。ドキュメントの構造（表が多い、長文か短文か等）によって適したチャンク戦略は異なる
- 「Embeddingモデルはクエリ側とインデックス側で別々のものを使ってよい」→ 誤り。同一のEmbeddingモデルでベクトル空間を揃える必要がある
- 「RAGを使えばFineTuningは不要になる」→ 一概に誤り。RAGは知識注入（What）に強く、口調・出力フォーマットの一貫性（How）はFineTuningの方が向く場合がある。両者は目的が異なり併用もされる
