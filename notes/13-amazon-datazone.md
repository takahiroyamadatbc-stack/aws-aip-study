# Amazon DataZone

組織横断でデータをカタログ化・検索・共有・ガバナンスするためのマネージドサービス。AWS Glue Data Catalogや[[12-lake-formation-lf-tags|Lake Formation]]と混同しやすいが、DataZoneは「誰が・どのデータに・どんな権限でアクセスできるか」を細かく制御するレイヤーではなく、**データを見つけて・意味を理解して・使う許可を申請する、より上位のガバナンス／カタログ／コラボレーション層**である点が最大の違い。

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

**OpenLineage互換**の仕組みで、データの出所（provenance）から加工・変換、最終的な消費までを追跡・可視化する機能。

- **自動キャプチャ**: AWS Glue Data CatalogやAmazon Redshiftのデータソースは、DataZoneに追加するだけでリネージを自動収集できる。Glue ETLジョブやサードパーティツールなど任意のシステムからも、OpenLineage形式でリネージ情報を投稿するAPIが用意されている
- **ノードの種類**: リネージグラフは「Dataset node（テーブル・ビュー等の資産）」と「Job (run) node（変換ジョブとその実行履歴）」の2種類で構成される
- **バージョニング**: リネージイベントごとにバージョンが記録され、ある時点の状態確認や時系列の変化比較ができ、監査の証跡になる
- **カラムレベルリネージ**: テーブル単位だけでなく列単位でも追跡でき、**「PIIがどのカラムに存在し、どう下流に伝播したか」を示せる**ため、コンプライアンス証跡としての価値が高い

## Lake Formationとの関係・違い

両者は補完関係にあり、試験では役割分担の理解が問われる。

```
Amazon DataZone      … 「このデータは何か（意味・用語）」「誰が使ってよいか（申請・承認のワークフロー）」
                         「どこから来てどう変換されたか（リネージ）」を扱うガバナンス・カタログ層
AWS Lake Formation    … DataZoneでサブスクリプションが承認された後、実際に
                         「どのテーブル・カラムを読めるか」を強制する権限（アクセス制御）レイヤー
```

DataZoneの画面上で「承認」ボタンを押す操作が、裏側ではLake Formationへの権限付与呼び出しに変換されているとイメージすると掴みやすい。

### Subscription承認からLake Formation権限付与までの流れ

DataZoneがLake Formation管理下のGlue Data Catalogテーブル（**managed asset**と呼ぶ）を対象にサブスクリプションを承認すると、以下が自動的に起こる。

1. 承認されたテーブルが、消費者側プロジェクトの**既存のすべてのdata lake environment**に自動的に追加される
2. DataZoneが裏側でLake Formationの権限をそのテーブルに対して付与・管理する。付与された結果、消費者側アカウントのGlue Data Catalog上にもリソースとして見えるようになり、Athenaからクエリできる
3. サブスクリプション承認後に**新しいenvironmentを追加した場合、そのenvironmentへの権限付与は自動追従しない**。データポータルの「Add grant」操作で手動付与が必要（試験でひっかけになりやすいポイント）

もう1点、対象がLake Formation管理下のテーブルであっても、**Glue Data CatalogアセットについてはLF-TBAC（[[12-lake-formation-lf-tags|LFタグベースの権限方式]]）はサポート対象外**で、テーブルを個別指定する権限方式のみが使われる。「DataZone経由の権限もLFタグで柔軟に管理できる」という理解は誤り。

### Hybrid mode（IAM権限管理のテーブルとの共存）

Lake Formationに未登録で、素のIAMポリシー（S3バケットポリシー等）だけでアクセス制御されているGlueテーブルも、Lake Formationへの事前登録なしにDataZone経由で共有できる仕組みが**Lake Formation hybrid mode**。消費者がそのテーブルにサブスクライブした時点でDataZoneが該当S3ロケーションを自動的にhybrid modeで登録し、既存のIAM権限を壊さずにLake Formation権限を追加で付与する。**既存ワークフローを止めずに段階的にLake Formationのガバナンス配下へ移行できる**のが狙いで、「Lake Formationに登録済みのテーブルしかDataZoneで共有できない」という理解は誤り。

まとめると、**DataZoneは「アクセスを許可すべきかの意思決定・申請フロー（Subscription）」を担い、実際の権限行使（強制）はLake Formationに委ねる**という分業になっている。

## 試験でのひっかけポイント整理

- 「DataZoneはデータそのものを保存・暗号化するサービスである」→ 誤り。DataZoneは**メタデータ・ガバナンス・ワークフロー**を扱う層であり、データ本体の実体はS3やRedshiftなど既存のデータソース側にある
- 「AWS ConfigやAWS DataSyncでデータ系統を追跡できる」→ 誤り。Configはリソースの**構成変更**、DataSyncはファイルの**転送**を扱うサービスであり、どちらもデータの変換履歴・依存関係（リネージ）を追跡する機能を持たない
- 「Athenaでクエリすればデータソースのリネージがわかる」→ 誤り。Athenaはアドホックなクエリ実行エンジンであり、系統情報を自動追跡・可視化する機能はない

## 参考

- [What is Amazon DataZone?](https://docs.aws.amazon.com/datazone/latest/userguide/what-is-datazone.html)
- [Data lineage in Amazon DataZone](https://docs.aws.amazon.com/datazone/latest/userguide/datazone-data-lineage.html)
- [Grant access to managed AWS Glue Data Catalog assets in Amazon DataZone](https://docs.aws.amazon.com/datazone/latest/userguide/grant-access-to-glue-asset.html)
- [Amazon DataZone integration with AWS Lake Formation hybrid mode](https://docs.aws.amazon.com/datazone/latest/userguide/hybrid-mode.html)
