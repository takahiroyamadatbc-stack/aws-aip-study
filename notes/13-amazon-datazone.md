# Amazon DataZone

組織横断でデータをカタログ化・検索・共有・ガバナンスするためのマネージドサービス。「基盤モデルの統合、データ管理、コンプライアンス」領域で、**エンドツーエンドのデータ系統（データリネージ）追跡**や**データガバナンスの自動化**が問われる設問に登場する。AWS Glue Data Catalogや[[12-lake-formation-lf-tags|Lake Formation]]と混同しやすいが、DataZoneは「誰が・どのデータに・どんな権限でアクセスできるか」を細かく制御するレイヤーではなく、**データを見つけて・意味を理解して・使う許可を申請する、より上位のガバナンス／カタログ／コラボレーション層**である点が最大の違い。

## Amazon DataZoneとは何か

AWS上・オンプレミス・サードパーティに散らばったデータを**カタログ化（catalog）・発見（discover）・共有（share）・ガバナンス（govern）**するためのデータ管理サービス。データエンジニア・データサイエンティスト・アナリスト・ビジネスユーザーなど異なる役割の人が、同じデータポータルを通じてデータを探し、意味（ビジネス用語）を理解し、アクセスを申請し、承認を経て利用できるようにする「社内データマーケットプレイス」に近いイメージを持つとわかりやすい。

データそのものを移動・複製するわけではなく、**Amazon Redshift、AWS Glue Data Catalog（S3上のテーブル）、Amazon Athena、Amazon QuickSight、AWS Lake Formationなどの既存サービスと統合し、メタデータとアクセス許可のワークフローを一元管理する**ポジションのサービス。

## 主要な構成要素

| 要素 | 役割 |
|---|---|
| **Domain** | DataZoneの最上位の管理境界。事業部・ライン・組織単位で1つ作成し、その配下でデータ資産・用語定義・ガバナンス方針を管理する |
| **Project** | Domain内のワークスペース。データの生産者（producer）・消費者（consumer）がチーム単位で共同作業する場所 |
| **Environment** | Projectに紐づくコンピュート・ストレージリソース（Redshiftクラスター、Athenaワークグループなど）の実体 |
| **Data Source** | AWS Glue Data CatalogやRedshiftなど、データの実体がある場所への接続定義。ここからカタログへ資産を取り込む |
| **Asset（データ資産）** | カタログに公開された個々のデータセット（テーブル・ビュー等） |
| **Business Glossary（ビジネスグロッサリー）** | 「顧客ID」「解約」のようなビジネス用語の共通定義。異なる部署でも同じ意味でデータを解釈できるようにする |
| **Subscription（サブスクリプション）** | 消費者がAssetへのアクセスを申請し、生産者側が承認／却下する**ガバナンス付きの申請ワークフロー**。承認されると裏側でLake Formation権限などが自動的に付与される |
| **データポータル** | ブラウザベースのWebアプリ。IAM Identity Center等で認証し、カタログ検索・サブスクリプション申請・データ分析への入口となる |

## データ系統（データリネージ）の仕組み

問題52で問われている「エンドツーエンドのデータ系統」の中核機能。**OpenLineage互換**の仕組みで、データの出所（provenance）から加工・変換、最終的な消費までを追跡・可視化する。

- **自動キャプチャ対象**: AWS Glue Data Catalog・Amazon Redshiftのデータソースは、DataZoneに追加するだけで自動的にリネージを収集できる（Glueクローラーが対応するS3・DynamoDB・Delta Lake・Iceberg・Hudi等のソースが対象。JDBC/DocumentDBは非対応）
- **Sparkジョブのリネージ**: AWS Glue（v5.0以降）のETLジョブやノートブックは、`OpenLineageSparkListener`を設定することでジョブ実行時のリネージイベントをDataZoneドメインへ送信できる
- **API経由の取り込み**: `PostLineageEvent` APIを使えば、Glue/Redshift以外の任意のシステム（オンプレミスのETL、サードパーティツール等）からもOpenLineage形式でリネージイベントを投稿できる。`GetLineageNode`／`ListLineageNodeHistory`で参照する
- **ノードの種類**: リネージグラフは「Dataset node（テーブル・ビュー等の資産）」と「Job (run) node（変換ジョブとその実行履歴）」の2種類のノードで構成される
- **バージョニング**: リネージイベントごとにバージョンが記録され、ある時点のリネージを見たり、時系列での変化を比較したりできる。監査・トラブルシューティングの証跡として使える
- **カラムレベルリネージ**: テーブル単位だけでなく列単位でも追跡可能。**「PIIがどのカラムに存在し、どう下流に伝播したか」を示す**ことができ、コンプライアンス証跡としての価値が高い

## Lake Formationとの関係・違い

両者は補完関係にあり、試験では役割分担の理解が問われる。

```
Amazon DataZone      … 「このデータは何か（意味・用語）」「誰が使ってよいか（申請・承認のワークフロー）」
                         「どこから来てどう変換されたか（リネージ）」を扱うガバナンス・カタログ層
AWS Lake Formation    … DataZoneでサブスクリプションが承認された後、実際に
                         「どのテーブル・カラムを読めるか」を強制する権限（アクセス制御）レイヤー
```

### Subscription承認からLake Formation権限付与までの実際の流れ

DataZoneがLake Formation管理下のGlue Data Catalogテーブル（**managed asset**と呼ぶ）を対象にサブスクリプションを承認すると、以下が自動的に起こる。

1. 承認されたテーブルが、消費者側プロジェクトの**既存のすべてのdata lake environment**に自動的に追加される
2. DataZoneが裏側で**Lake Formationの権限（Named Resource Method）**をそのテーブルに対して付与・管理する。付与された結果、消費者側アカウントのGlue Data Catalog上にもリソースとして見えるようになり、Athenaからクエリできる
3. サブスクリプション承認後に**新しいenvironmentを追加した場合、そのenvironmentへの権限付与は自動追従しない**。データポータルの「Add grant」操作で手動付与が必要（試験でひっかけになりやすいポイント）

この権限付与が成立するための前提条件も明確に決まっている。

- 対象のGlueテーブルが**Lake Formation管理下**にあること（DataZoneはLake Formation権限を操作することで許可を実現するため）
- テーブルを公開したdata lake environmentの**Manage accessロール**が、対象データベースに`DESCRIBE`/`DESCRIBE GRANTABLE`、対象テーブルに`DESCRIBE`/`SELECT`/`DESCRIBE GRANTABLE`/`SELECT GRANTABLE`のLake Formation権限を持っていること
- **Glue Data CatalogアセットについてはLF-TBAC（[[12-lake-formation-lf-tags|LFタグベースの権限方式]]）はサポート対象外**で、Named Resource Method（テーブル個別指定）のみが使われる。「DataZone経由の権限もLFタグで柔軟に管理できる」という選択肢は誤り

### Hybrid mode（IAM権限管理のテーブルとの共存）

Lake Formationに未登録で、素のIAMポリシー（S3バケットポリシー等）だけでアクセス制御されているGlueテーブルも、Lake Formationへの事前登録なしにDataZone経由で共有できる仕組みが**Lake Formation hybrid mode**。DefaultDataLakeブループリントで「Data location registration」を有効化しておくと、消費者がそのテーブルにサブスクライブした時点でDataZoneが該当S3ロケーションを自動的にhybrid modeで登録し、既存のIAM権限を壊さずにLake Formation権限を追加で付与する。**既存ワークフローを止めずに段階的にLake Formationのガバナンス配下へ移行できる**のが狙いで、「Lake Formationに登録済みのテーブルしかDataZoneで共有できない」という理解は誤り。

まとめると、**DataZoneは「アクセスを許可すべきかの意思決定・申請フロー（Subscription）」を担い、実際の権限行使（強制）はLake Formationに委ねる**という分業になっている。DataZoneの画面上で「承認」ボタンを押す操作が、裏側ではLake Formationの`grant-permissions`相当の呼び出しに変換されているとイメージすると、両者の関係が掴みやすい。

## 問題52のソリューション構成に見る役割分担

「データ系統・リアルタイムPIIフィルタリング・監査証跡・コンプライアンス自動報告」という4要件を満たす正解の構成は、1サービスで完結させず**専門サービスを縦に積む**発想になっている。

| 要件 | 担当サービス | ポイント |
|---|---|---|
| データ系統の追跡 | **Amazon DataZone** | データソース登録からデータ消費までをOpenLineage互換で追跡・可視化（本ノートの主題） |
| リアルタイムPIIフィルタリング | **Amazon Bedrock Guardrails**（機微情報フィルター） | 入力プロンプト・モデル応答をMLでリアルタイムに検出しブロック／マスク。**バッチ処理のComprehend Medicalスケジュール実行では「リアルタイム」要件を満たせない**のが典型的な誤答パターン |
| API呼び出しの監査証跡 | **AWS CloudTrail** → S3配信 | Bedrockの全API呼び出しを継続的に記録。X-Ray（分散トレーシング）やSession Manager（シェル操作ログ）はここでの代替にならない |
| 保存データのコンプライアンス報告 | **Amazon Macie** → **AWS Security Hub** | S3上の保存データをMLでスキャンし機微情報を検出、結果をSecurity Hubに集約してレポート化 |

## 試験でのひっかけポイント整理

- 「AWS ConfigやAWS DataSyncでデータ系統を追跡できる」→ 誤り。Configはリソースの**構成変更**、DataSyncはファイルの**転送**を扱うサービスであり、どちらもデータの変換履歴・依存関係（リネージ）を追跡する機能を持たない
- 「Athenaでクエリすればデータソースのリネージがわかる」→ 誤り。Athenaはアドホックなクエリ実行エンジンであり、系統情報を自動追跡・可視化する機能はない
- 「AWS WAFでPIIをフィルタリングできる」→ 誤り。WAFはSQLインジェクション・XSS対策のWebアプリケーションファイアウォールであり、PIIの検出・マスキング機能は持たない
- 「Comprehend Medicalをスケジュール実行すればリアルタイムPIIフィルタリング要件を満たせる」→ 誤り。スケジュール実行はバッチ処理であり「リアルタイム」の要件と矛盾する。リアルタイム性が求められる場合は**Bedrock Guardrailsの機微情報フィルター**が定石
- 「DataZoneはデータそのものを保存・暗号化するサービスである」→ 誤り。DataZoneは**メタデータ・ガバナンス・ワークフロー**を扱う層であり、データ本体の実体はS3やRedshiftなど既存のデータソース側にある
- 「Rekognition Custom Labelsでテキスト中のPIIを検出できる」→ 誤り。Rekognitionは**画像内のオブジェクト検出**に特化しており、テキストのPII検出にはComprehend/Comprehend MedicalやBedrock Guardrails、Macieが適する

## 参考

- [What is Amazon DataZone?](https://docs.aws.amazon.com/datazone/latest/userguide/what-is-datazone.html)
- [Data lineage in Amazon DataZone](https://docs.aws.amazon.com/datazone/latest/userguide/datazone-data-lineage.html)
- [Grant access to managed AWS Glue Data Catalog assets in Amazon DataZone](https://docs.aws.amazon.com/datazone/latest/userguide/grant-access-to-glue-asset.html)
- [Amazon DataZone integration with AWS Lake Formation hybrid mode](https://docs.aws.amazon.com/datazone/latest/userguide/hybrid-mode.html)
