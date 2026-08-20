# AWS Lake Formation と LFタグベースアクセスコントロール（LF-TBAC）

データレイク（S3 + Glue Data Catalog）に対して、データベース／テーブル／**カラム単位**でアクセス権限を管理する仕組み。「基盤モデルの統合、データ管理」領域で、クロスアカウントのきめ細かいデータ共有が問われる設問に登場する。IAMポリシーやS3バケットポリシーとの違い（何が違うレイヤーで、何を解決するためのものか）を先に押さえる。

## Lake Formationとは何か

**AWS Lake Formation** は、S3上に構築するデータレイクに対して、データカタログの管理・データの取り込み・そして**アクセス許可の一元管理**を行うサービス。裏側では**AWS Glue Data Catalog**（データベース／テーブル／カラムのメタデータを保持するカタログ）を利用し、Lake Formationはそのカタログに対して「誰が・どのデータベース／テーブル／カラムに・どんな操作（SELECT, DESCRIBE, ALTER等）を許可されるか」を管理する権限レイヤーとして機能する。

重要なのは、Lake Formationの権限は**S3バケットポリシーやIAMポリシーとは別のレイヤーで働く**という点。Athena、Redshift Spectrum、EMR、Glueジョブなどのクエリエンジンがデータを読みに行くとき、Lake Formationが一時的な認証情報（scoped credentials）を発行し、許可されたテーブル・カラムだけが見えるようフィルタする。

```
IAM/S3バケットポリシー … 「このIAMプリンシパルはこのS3パスにアクセスできるか」（オブジェクト単位の粗い制御）
Lake Formation権限   … 「このプリンシパルはこのテーブルのこのカラムを読めるか」（メタデータ単位の細かい制御）
```

IAMだけ・S3プレフィックスだけでは「テーブルの中の特定カラムを隠す」ことができない。これがLake Formationが必要になる根本理由。

## 権限付与の2つの方式

| 方式 | 概要 | 弱点 |
|---|---|---|
| **Named Resource Method** | データベース名・テーブル名を1つずつ指定して個別にgrantする | テーブル数が増えるたびに個別付与が必要で、大規模データレイクでは管理が破綻しやすい |
| **LF-Tag Based Access Control（LF-TBAC）** | リソース（DB/テーブル/カラム）とプリンシパルの両方に**タグ**を付け、タグが一致すれば権限が成立する | タグ設計さえ決めれば新規テーブルにも自動的に権限が波及し、スケールする |

LF-TBACは、IAMのABAC（属性ベースアクセス制御、タグの一致で権限を決める考え方）をデータカタログの世界に持ち込んだものとイメージすると理解しやすい。

## LFタグの仕組み

LFタグは**キー・バリュー形式のラベル**（例: `project = genomics-alpha`）で、以下の3ステップで使う。

1. **タグを作成する**（Lake Formation上でキーと許容値の一覧を定義）

```bash
aws lakeformation create-lf-tag \
  --tag-key "project" \
  --tag-values "genomics-alpha" "genomics-beta"
```

2. **カタログリソースにタグを割り当てる**（データベース／テーブル／**カラム単位**で可能）

```bash
aws lakeformation add-lf-tags-to-resource \
  --resource '{
    "TableWithColumns": {
      "DatabaseName": "genomics_db",
      "Name": "patient_samples",
      "ColumnNames": ["genetic_variant_data"]
    }
  }' \
  --lf-tags '[{"TagKey":"project","TagValues":["genomics-alpha"]}]'
```

3. **プリンシパル（IAMロール、他アカウント）にタグ条件付きの権限を付与する**

```bash
aws lakeformation grant-permissions \
  --principal DataLakePrincipalIdentifier="arn:aws:iam::<分析アカウントID>:role/AnalysisAppRole" \
  --permissions "SELECT" \
  --lf-tag-policy '{
    "ResourceType": "TABLE",
    "Expression": [{"TagKey":"project","TagValues":["genomics-alpha"]}]
  }'
```

この結果、「`project=genomics-alpha` というタグが付いたカラム／テーブルだけが、そのタグにマッチするプリンシパルから見える」という関係が成立する。新しいテーブルを作っても同じタグを付ければ自動的に同じ権限が適用されるため、テーブルが増え続けるデータレイクでも管理コストが増えにくい。

## カラムレベル制御が肝

LFタグは**データベース／テーブルだけでなくカラムにも付与できる**。同一テーブル内に一般的なメタデータと機微情報（患者の遺伝情報、氏名等）が混在していても、機微カラムだけに別のタグを付けて権限を絞れる。これが「S3プレフィックスベースの制御ではできないこと」の核心にあたる。S3プレフィックスは物理的なオブジェクト配置（フォルダ構造）の話であり、1つのParquet/CSVファイルの中に混在する個々のカラムを区別できない。カラムを認識できるのは、Glue Data Catalogのメタデータを扱うLake Formationならでは。

## クロスアカウント共有

別アカウントのデータレイクに対してカラムレベルでアクセスを絞る場合、Lake Formationは内部的に**AWS RAM（Resource Access Manager）**を使ってタグベースの権限を他アカウントに共有する。共有される側のアカウントでは、共有されたリソースへの**リソースリンク（resource link）**をGlue Data Catalog上に作成し、それを通じてクエリを実行する。データ本体（S3オブジェクト）を直接コピーするわけではなく、あくまでメタデータ・権限レベルでの共有になる点に注意。

```
データ管理アカウント                     解析用アカウント
┌─────────────────────┐            ┌─────────────────────┐
│ Glue Data Catalog     │  AWS RAM   │ リソースリンク         │
│  DB: genomics_db      │  で共有    │  (共有先カタログへの   │
│  Table: patient_...   │──────────▶│   ポインタ)           │
│  Column: ...variant   │            │                       │
│  LFタグ: project=alpha│            │ IAMロールにLFタグ    │
│                        │            │ project=alpha を付与  │
│ S3: 実データ           │            │ → SELECTでカラムが   │
└─────────────────────┘            │   フィルタされる       │
                                      └─────────────────────┘
```

## 試験でのひっかけポイント整理

- 「S3バケットポリシーやIAMロールのプリンシパル条件でカラムレベルの制御ができる」→ 誤り。IAM/S3はオブジェクト単位の制御までで、**カラム単位の制御はLake Formationの領分**
- 「S3プレフィックスをテーブル単位に分ければテーブル制御になる」→ 部分的には正しいが、**カラム単位の制御はプレフィックス設計では実現不可能**
- 「Named Resource Methodでもクロスアカウント共有はできるので、LF-TBACは必須ではない」→ テーブル数・プロジェクト数が増えるデータレイクでは、Named Resource Methodは個別grantの管理コストが破綻しやすい。**「研究プロジェクトごと」のように分類軸がタグ的な性質を持つ場合はLF-TBACが定石**
- 「Lake FormationはS3データそのものを暗号化・移動する仕組みである」→ 誤り。Lake Formationは**アクセス許可（誰が何を見られるか）を管理するレイヤー**であり、データの物理的な移動や暗号化そのものを行うわけではない
- 「アプリケーション側で全カラムを取得してからフィルタリングすればよい」→ セキュリティのベストプラクティスに反する。**インフラ（Lake Formation）側でカラムへのアクセス自体を制限する**のが最小権限の原則に沿った設計
