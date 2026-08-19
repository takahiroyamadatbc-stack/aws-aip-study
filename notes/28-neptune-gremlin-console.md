# Amazon Neptune Gremlinコンソール

## Amazon Neptuneとは何か

**Amazon Neptune**は、フルマネージドの**グラフデータベース**サービス。リレーショナルDBが「表と外部キー」でデータ間の関係を表すのに対し、グラフDBは「ノード（頂点）」と「エッジ（辺、ノード間の関係）」でデータを表現し、**エンティティ同士の繋がりを辿るクエリ**（「Aの友人の友人で、かつBと同じ会社に勤めている人は誰か」等）を高速に処理できるよう設計されている。ソーシャルネットワーク分析、レコメンデーション、不正検知、ナレッジグラフ、GraphRAG（[22-bedrock-knowledge-bases-and-agents.md](22-bedrock-knowledge-bases-and-agents.md)参照）などが典型的なユースケース。

### 2つのグラフモデルと対応クエリ言語

Neptuneは1つのエンジンで**2種類のグラフモデル**を扱え、それぞれ対応するクエリ言語が異なる。

| グラフモデル | 概要 | 対応クエリ言語 |
|------|------|------|
| プロパティグラフ（Property Graph） | ノード・エッジそれぞれにプロパティ（key-value）を持たせられる、実務でよく使われる汎用的なグラフモデル | **Gremlin**（Apache TinkerPop） / **openCypher** |
| RDF（Resource Description Framework） | 「主語-述語-目的語」の3つ組（トリプル）でデータを表現する、W3C標準のセマンティックWeb向けモデル | **SPARQL** |

- 同じNeptuneクラスタに対し、プロパティグラフ用の2言語（Gremlin/openCypher）は併用可能（同じデータを異なるクエリ言語で操作できる）
- RDF（SPARQL）とプロパティグラフ（Gremlin/openCypher）は**別々のデータモデル**であり、両方を同じクラスタで混在させて使うことはできない（クラスタ全体としてどちらのモデルを使うかが決まる）

## Gremlinコンソールとは何か

「Gremlinコンソール」はNeptune独自の機能ではなく、**Apache TinkerPop**プロジェクトが提供する汎用のGroovyベース対話型CLIツール。Gremlinをサポートする任意のグラフDB（Neptune、JanusGraph等）に接続できる、いわば「グラフDB版の`psql`/`mysql`クライアント」に相当するオープンソースツールである。**Neptune自体がGUIやWeb管理画面としてクエリコンソールを提供しているわけではない**という点が試験でひっかけになりやすい。

### Neptuneへの接続の特徴

| 項目 | 内容 |
|------|------|
| 接続方式 | `bin/gremlin.sh`を起動し、`:remote connect tinkerpop.server conf/neptune-remote.yaml`のようにNeptuneのGremlinエンドポイント（`wss://<cluster-endpoint>:8182/gremlin`）へWebSocket接続する |
| ネットワーク制約 | NeptuneはVPC内リソースであり、パブリックエンドポイントを持たない。Gremlinコンソールを動かすクライアント（ローカルPC/EC2/Cloud9等）が同一VPC内、またはVPN/Direct Connect/踏み台経由でVPCに到達できる必要がある |
| 認証 | デフォルトはVPC内到達性のみで認証不要（NeptuneはVPCのセキュリティグループでアクセス制御する設計が基本）。IAM DBAuth（SigV4署名）を有効化している場合は、リクエストへの署名処理が必要になり、素の`gremlin.sh`だけでは完結せず署名用のプラグイン/ラッパーが要る |
| ポート | 8182（デフォルト） |

## Neptune Workbenchとの違い（試験での比較対象）

Neptuneには「Neptune Workbench」という、AWSマネジメントコンソールから起動できる**マネージドのJupyterノートブック環境**が用意されており、こちらが公式のクエリ実行手段として案内されることが多い。

| | Gremlinコンソール | Neptune Workbench |
|---|---|---|
| 実体 | TinkerPop提供のOSS CLIツール（自前でインストール・起動が必要） | Neptuneがマネージドで用意するJupyterノートブック（`%%gremlin`等のマジックコマンドでクエリ実行） |
| 起動場所 | 任意のクライアント環境 | AWSマネジメントコンソールから数クリックで起動（裏側はSageMaker Notebookインスタンス） |
| 対応言語 | Gremlinのみ | Gremlin / openCypher / SPARQLをマジックコマンドで切替可能 |
| 可視化 | なし（テキスト出力のみ） | `%%gremlin -d`等でグラフの可視化ウィジェットあり |
| ネットワーク到達性 | クライアント側で自分でVPC到達性を確保する必要がある | Workbench自体がNeptuneと同一VPCで起動されるため、到達性は自動的に確保される |

## 試験でのひっかけポイント整理

- 「Neptuneのマネジメントコンソール上で直接Gremlinクエリを実行できる」→ 誤り。マネジメントコンソールはクラスタの作成・設定管理用であり、クエリ実行はNeptune WorkbenchやGremlinコンソール等の**別のクライアント**経由で行う
- 「Gremlinコンソールはインターネット経由でどこからでも接続できる」→ 誤り。NeptuneはVPC内リソースでパブリックアクセス不可。クライアントがVPCに到達できる必要がある
- 「GremlinコンソールはAWS（Neptune）が独自に開発したツールである」→ 誤り。Apache TinkerPopプロジェクトが提供するOSSツールで、Neptune以外のGremlin対応グラフDBにも使える汎用クライアント
- 「NeptuneはRDF（SPARQL）とプロパティグラフ（Gremlin/openCypher）を同じクラスタ内で自由に混在させられる」→ 誤り。データモデルはクラスタ単位でどちらかに決まり、混在利用はできない
- 「Gremlin対応のNeptuneクラスタではopenCypherは使えない」→ 誤り。Gremlinとopen Cypherはどちらもプロパティグラフモデル向けの言語で、同じクラスタに対して併用できる
