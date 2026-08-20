# 002 Amazon Q Business S3コネクタのACL設定（単一ファイルでプレフィックス→グループを一元管理）

## 問題
<!-- 模擬試験 問18 -->
あるソフトウェア企業が、Amazon Q Businessを使用して、従業員が自然言語プロンプトで会社情報や個人情報にアクセスできるAIアシスタントを構築している。会社はこの情報をAmazon S3バケットに保存している。

会社の各部門はS3バケット内に専用のプレフィックスを持つ。各オブジェクト名には、そのオブジェクトが属する部門のS3プレフィックスが含まれる。各部門はAWS IAM Identity Center内の1つのグループにのみ属する。各従業員は1つの部門にのみ属する。

会社はAmazon Q Businessを設定し、S3バケットに保存されたデータをデータソースとしてアクセスする。会社は、AIアシスタントがユーザーのIAM Identity Centerグループメンバーシップに基づくアクセス制御を遵守することを保証する必要がある。最も運用オーバーヘッドが少ないソリューションはどれか。

- A. 各部門フォルダにそれぞれ個別のACL設定用JSONファイルを配置し、データソース設定のアクセス制御セクションでJSONファイルの場所を指定する。
- B.（正解）S3バケット内に単一のJSONファイルを作成し、各部門のS3プレフィックスを対応するIAM Identity Centerグループにマッピングするアクセス制御エントリを追加する。データソース設定のアクセス制御セクションで、そのJSONファイルのS3パスを指定する。
- C. S3バケットのトップレベルに`metadata.json`という単一のメタデータファイルを作成し、`AccessControlList`オブジェクトに各部門プレフィックスのS3パスとアクセス可能なグループを列挙する。
- D. 各IAM Identity Centerグループに対して全プレフィックスへのアクセスを拒否するアクセス許可セットを作成し、`StringNotEquals`条件キーで自部門のみ許可する。

## 選んだ答えと理由
B を選択し、正解。

Amazon Q BusinessのS3コネクタ（S3V2）はドキュメントレベルのアクセス制御を`accessControlConfiguration.aclConfigurationFilePath`という単一の文字列パラメータで実現しており、複数ファイルを配列で渡す仕組みではない。1つのJSONファイルの中に`keyPrefix`＋`aclEntries`のエントリを複数並べられるため、部門が増減してもこのファイル1つを編集するだけで済み、運用オーバーヘッドが最小になると判断した。

## 誤答の型
該当なし（正解）。ただし以下の点は「知っていたつもり」で、正確なJSON構造・APIパラメータの階層までは把握していなかったため、実際のスキーマを確認して整理したい。
- `aclConfigurationFilePath`が`configuration`JSON全体のどの階層（`accessControlConfiguration`のサブプロパティ）にあるか
- ACLファイルに載っていないプレフィックスがどう扱われるか（このLabで初めて「全ユーザーに公開される」という仕様を確認した）
- 選択肢Cの「メタデータファイル」との違い（Q Businessには`<document>.<extension>.metadata.json`という別の仕組みがあり、ACL設定ファイルと役割・命名規則が異なる）

## 仮説
- `create-data-source`の`--configuration`は`type: S3V2`の場合、`connectionConfiguration` / `filterConfiguration` / `accessControlConfiguration` / `deletionProtectionConfiguration`などのトップレベルキーを持つ1つのJSONオブジェクトで、`aclConfigurationFilePath`は`accessControlConfiguration`の中の1つの文字列プロパティである（配列や複数パスの指定はできない）
- ACL設定ファイルはデータと同じバケット内であればパス・ファイル名は自由。1ファイルの中に`keyPrefix`ごとの`aclEntries`（`Type: GROUP`の`Name`はIAM Identity Centerのグループ表示名）を複数エントリ並べられる
- ACLファイルに記載のないプレフィックスは、デフォルトで**全ユーザーに公開**される。そのためACLファイル自身の置き場所（例: `config/`）は`filterConfiguration.exclusionPrefixes`でインデックス対象から除外しておかないと、ACL設定ファイルの内容そのものが検索対象になり得る
- 選択肢Cの`.metadata.json`はドキュメント単位の付随ファイルであり、`AccessControlList`フィールドは持てるが、1ファイルでバケット全体のプレフィックスを一元管理する用途には使えない

## 検証
実機デプロイは行わず、コードの意図と期待される挙動として整理する（Q BusinessアプリケーションはIAM Identity Center連携・インデックス作成を伴い、時間単位の課金が発生するため、標準ルールに従いデプロイしない）。

1. [01_create_s3_bucket_and_sample_docs.sh](01_create_s3_bucket_and_sample_docs.sh)
   検証用バケットを作成し、`dept-sales/` `dept-hr/` `dept-finance/` の3プレフィックスにサンプルドキュメントを配置する。

2. [02_upload_acl_config.sh](02_upload_acl_config.sh) / [acl-config.sample.json](acl-config.sample.json)
   3部門ぶんのマッピングを**1つのJSONファイル**にまとめ、同バケット内の`config/acl-config.json`にアップロードする。部門が増えてもこのファイルに配列要素を追記するだけでよく、選択肢Aのように部門ごとにファイルを分ける必要がない。

3. [03_create_identity_center_groups.sh](03_create_identity_center_groups.sh)
   検証用にIAM Identity Centerグループ（`SalesGroup` / `HRGroup` / `FinanceGroup`）を作成する。ACLファイルの`aclEntries[].Name`はこの表示名と一致させる。

4. [04_create_qbusiness_app_and_datasource.sh](04_create_qbusiness_app_and_datasource.sh)
   Q Businessアプリケーション・インデックス・リトリーバーを作成したうえで、`create-data-source`の`--configuration`に以下の形で`accessControlConfiguration.aclConfigurationFilePath`を指定する。

   ```json
   {
     "type": "S3V2",
     "connectionConfiguration": {
       "bucketName": "aip-002-q-business-s3-acl",
       "bucketOwnerAccountId": "<ACCOUNT_ID>"
     },
     "filterConfiguration": {
       "inclusionPrefixes": ["dept-sales/", "dept-hr/", "dept-finance/"],
       "exclusionPrefixes": ["config/"]
     },
     "accessControlConfiguration": {
       "aclConfigurationFilePath": "config/acl-config.json"
     }
   }
   ```

   このパラメータは配列ではなく単一の文字列のため、選択肢Aのように部門フォルダごとに複数のACLファイルを同時指定する構成はそもそも不可能であることがAPIスキーマのレベルで確認できる。

5. [05_start_sync_and_check.sh](05_start_sync_and_check.sh)
   同期ジョブを開始し、`chat-sync`でユーザーごとに検索結果が部門グループ単位でフィルタされることを確認する手順を記述する。

6. [06_delete_resources.sh](06_delete_resources.sh)
   検証後の片付け（データソース→インデックス→アプリケーション→Identity Centerグループ→S3バケットの順に削除）。

## 結論（1行）
Amazon Q BusinessのS3(V2)コネクタのドキュメントレベルACLは、`configuration.accessControlConfiguration.aclConfigurationFilePath`という単一の文字列パラメータで、同一バケット内の1つのJSONファイル（`keyPrefix`＋`aclEntries`の配列）を指定する仕組みであり、部門ごとに複数ファイルを並列指定する構成はサポートされない。またACLファイルに載らないプレフィックスは全ユーザーに公開される点に注意する。

## 片付け
実機デプロイを行っていないため対象リソースなし。実行した場合は
[06_delete_resources.sh](06_delete_resources.sh) を実行し、
`aws qbusiness list-applications` と
`aws cloudformation list-stacks` / タグ`Project=aip-study`の消し忘れ検出コマンド（README「消し忘れ検出コマンド」参照）で残骸がないことを確認する。
