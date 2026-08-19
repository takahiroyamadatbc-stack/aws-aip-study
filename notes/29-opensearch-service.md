# Amazon OpenSearch Service（検索・分析エンジン）

Amazon Kendra（27-fully-managed-ai-services.md参照）との役割分担、Bedrock Knowledge Basesのベクトルストア選択肢の一つ（21-rag-basics.md、22-bedrock-knowledge-bases-and-agents.md参照）としての位置づけの2点で頻出するサービス。このノートではOpenSearch Service自体が何であるか、提供形態（Provisioned/Serverless）、AI関連の主用途であるベクトル検索を中心に整理する。

## これは何か

**Amazon OpenSearch Service**は、OSSの検索・分析エンジンOpenSearchをベースにしたフルマネージドサービス。利用者はクラスタ（またはServerlessのコレクション）を作成するだけで、インデックスの作成・検索・集計・可視化までを実行できる。裏側で動くエンジンは大きく3つの顔を持つ。

- **ログ・メトリクス分析**: 旧ELK（Elasticsearch/Logstash/Kibana）スタック相当の用途。大量のログ・時系列データを取り込み、ダッシュボードで可視化する
- **フルテキスト検索（キーワード検索エンジン）**: 検索語と文書中の単語の一致度・出現頻度に基づくスコアリング（BM25等）で関連文書をランキングする
- **ベクトル検索（k-NN）**: 高次元ベクトルの近似最近傍探索により、RAGのベクトルストアとして機能する

AIP-C01の出題では3つ目の**ベクトル検索＝RAGのベクトルストア**としての位置づけが中心だが、前提知識として残り2つの用途も押さえておく。

## OpenSearchが生まれた経緯（Elasticsearchとの関係）

- OpenSearchは、OSSのElasticsearch/KibanaをApache 2.0ライセンスの最終版からフォークして始まったプロジェクト。2021年にElastic社がElasticsearch/Kibanaのライセンスを（オープンソース標準の）Apache 2.0から独自ライセンス（SSPL→Elastic License）へ変更したことを受け、AWSが主導して立ち上げた
- Amazon OpenSearch Serviceの旧称は**Amazon Elasticsearch Service**。ライセンス変更を機にサービス名・エンジン名ともに改名された。試験で「Elasticsearch Service」という旧称が出てきても同一サービスの旧名と理解してよい

## 提供形態: Provisioned（マネージドクラスタ）とServerless

| 観点 | OpenSearch Service（Provisioned/マネージドクラスタ） | OpenSearch Serverless |
|------|--------------------------------------------------------|--------------------------|
| インフラ管理 | インスタンスタイプ・ノード数・ストレージ・シャード数などを利用者が設計・指定する | キャパシティ管理不要。OCU（OpenSearch Compute Unit）単位で使用量に応じ自動スケール |
| 起動・運用の手間 | クラスタのプロビジョニング・チューニング・スケーリング設計が必要 | コレクションを作成すればすぐ使える。チューニングの自由度は下がる代わりに運用負荷が低い |
| 課金 | 起動しているノードの時間課金（EC2的な課金） | 実際に消費したOCUに応じた従量課金 |
| コレクションタイプ | 該当なし（クラスタ全体を汎用的に利用） | **Time series**（ログ・時系列分析）／**Search**（全文検索）／**Vector search**（ベクトル検索）の3種類から用途に応じて選択して作成する |
| 向いているワークロード | 負荷パターンが予測でき、きめ細かいチューニングが必要な大規模ワークロード | 負荷が読みにくい／急増するワークロード、素早く立ち上げたいRAGのベクトルストア用途 |

- 生成AI文脈（RAGのベクトルストア）で登場する場合は、素早く立ち上げられスケーリングを意識しなくてよい**OpenSearch Serverless（Vector searchコレクション）**が案内されることが多い

## ベクトル検索（k-NN）とRAGでの役割

- OpenSearchは**k-NN（k-Nearest Neighbor）プラグイン**により、Embeddingベクトルに対する近似最近傍探索（ANN）をサポートする。ベクトル同士の類似度（コサイン類似度等）で近いベクトルを高速に検索できる
- この機能により、OpenSearch（特にOpenSearch Serverlessの**Vector search**コレクション）は**Bedrock Knowledge Basesのベクトルストアの選択肢の一つ**として使われる（他の選択肢はAurora PostgreSQL(pgvector)、Pinecone、Redis Enterprise Cloud、MongoDB Atlasなど。比較は21-rag-basics.md参照）
- **ハイブリッド検索**（ベクトル類似度検索とBM25ベースのキーワード検索を組み合わせてスコアを統合する手法）にも対応しており、Bedrock Knowledge Basesの`retrievalConfiguration`で`overrideSearchType`に`HYBRID`を指定する際のバックエンドとして機能する（対応するベクトルストアが必要という制約の実体がこれにあたる。詳細は22-bedrock-knowledge-bases-and-agents.md参照）
- ベクトル検索を使う場合でも、インデックスにはベクトルだけでなく元テキスト・メタデータも一緒に格納するのが一般的で、メタデータフィルタリング（部署・日付・カテゴリ等での絞り込み）と組み合わせて使える

## フルテキスト検索としての位置づけ（Kendraとの違い）

- OpenSearchは検索語と文書中の単語の一致度・出現頻度などに基づいてスコアリングする**キーワード検索エンジン**であり、ランキングロジックの設計・チューニングは利用者側の責務になる
- Amazon Kendraは機械学習モデルによって質問文の**意味を理解した上で**関連度の高い結果を返す検索サービスで、両者は「自分でスコアリングを組むキーワード検索エンジン（OpenSearch）」対「検索版の理解力の高いAI（Kendra）」という役割分担で問われやすい（詳細は27-fully-managed-ai-services.md参照）

## セキュリティ・アクセス制御

| 機能 | 内容 |
|------|------|
| VPCアクセス | ドメイン／コレクションをVPC内に配置し、パブリックエンドポイントを持たせずプライベートにアクセスさせる構成が可能 |
| きめ細かなアクセス制御（Fine-Grained Access Control, FGAC） | インデックス単位・ドキュメント単位・フィールド単位でアクセス権限を制御できる。内部ユーザーDBまたはIAMのプリンシパルに対してロールをマッピングする |
| IAMベースのアクセスポリシー | ドメイン／コレクションへのアクセス自体をIAMポリシーで制御する |
| 暗号化 | 保管時暗号化（KMS）、転送時暗号化（HTTPS／ノード間暗号化）に対応 |

## 試験でのひっかけポイント整理

- 「OpenSearch ServiceはAmazon Elasticsearch Serviceとは別サービスである」→ 誤り。OpenSearch ServiceはAmazon Elasticsearch Serviceの改名後の名称であり、Elastic社のライセンス変更を機にAWSがフォークしたOSSプロジェクトOpenSearchをベースにしている
- 「OpenSearchはKendraと同様に、質問文の意味を理解して回答を返す検索サービスである」→ 誤り。OpenSearchは単語の一致度・出現頻度に基づくキーワード検索エンジンであり、意味理解に基づく検索を行うのはKendraの役割
- 「Bedrock Knowledge Basesのベクトルストアとして使えるのはOpenSearch Serviceの通常のマネージドクラスタだけである」→ 要注意。素早く立ち上げられスケーリング管理が不要な**OpenSearch Serverless（Vector searchコレクション）**が標準的な選択肢として案内されることが多く、Provisionedクラスタに限定されるわけではない
- 「OpenSearch ServerlessはProvisionedクラスタと同じくインスタンスタイプ・ノード数を指定して構築する」→ 誤り。ServerlessはOCU単位で自動スケールし、インスタンス管理そのものが不要
- 「OpenSearchのハイブリッド検索は、ベクトル検索かキーワード検索のどちらか一方を選ぶ機能である」→ 誤り。ハイブリッド検索はベクトル類似度検索とキーワード検索（BM25等）の**両方のスコアを統合**してランキングする機能
- 「OpenSearch Serverlessのコレクションタイプはどれを選んでも同じ機能が使える」→ 誤り。Time series（ログ・時系列分析）／Search（全文検索）／Vector search（ベクトル検索）の3種類があり、用途に応じて作成時に選択する必要がある
