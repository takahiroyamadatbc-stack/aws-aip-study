# 001 Bedrock Provisioned Throughput（ルーティング先はARN指定で決まる）

## 問題
<!-- 模擬試験 問23 -->
バイオテック企業のデータサイエンスチームが Amazon Bedrock 上の Anthropic Claude モデルで実験レポートを生成している。
オンデマンドモデルから、安定した処理能力を確保する目的でプロビジョンドスループットに切り替えたが、
モデル切替後もパフォーマンスが改善しない。原因として最も適切なものはどれか。

- A. モデル起動の際の API が古い modelId を指定したままである。
- B. invoke_model を converse に置き換えていない。さらに inferenceConfig に provisioned: true を追加し忘れている。
- C. boto3.client の初期化時に region_name を指定していない。さらに config で retries.mode="adaptive" を有効化していない。
- D. ペイロードに useProvisionedThroughput: false フラグを設定している。accept="application/vnd.bedrock.provisioned+json" を指定していない。

## 選んだ答えと理由
A を選択し、正解。

Provisioned Throughput は「購入した」だけでは有効にならず、CreateProvisionedModelThroughput が返す
provisionedModelArn を InvokeModel/Converse の modelId に明示的に渡さない限り、リクエストは従来通り
オンデマンドエンドポイントに流れ続ける、という仕様を把握していたため。B/C/Dはいずれも実在しないパラメータ
（inferenceConfig.provisioned、retries.mode="adaptive"はSDKリトライの話でスループット経路とは無関係、
useProvisionedThroughputやapplication/vnd.bedrock.provisioned+jsonは存在しない）と判断して消去した。

## 誤答の型
該当なし（正解）。ただし「purchase = 自動的にルーティングされる」という誤解をしていないか、
実際のCLIコマンドとレスポンス（provisionedModelArnの形、CloudWatch上の見え方）を手を動かして確認したい。

## 仮説
- CreateProvisionedModelThroughputはprovisionedModelArnを返し、これはベースモデルIDとは別のARN形式になる
- InvokeModel/Converseのmodel-idにベースモデルID（オンデマンド）を渡し続けている限り、Provisioned Throughput
  を購入していてもCloudWatch上のProvisioned側メトリクス（ProvisionedModelArnディメンション）は動かない
- modelIdをprovisionedModelArnに切り替えた時点で初めてProvisioned容量が消費される

## 検証
実機デプロイは行わず、コードの意図と期待される挙動として整理する（Claude ProvisionedThroughputは
No Commitmentでも時間単位課金が発生するモデルユニット購入を伴うため、標準ルールに従いデプロイしない）。

1. [01_check_model_provisioned_support.sh](01_check_model_provisioned_support.sh)
   `list-foundation-models` で対象モデルの `inferenceTypesSupported` に `PROVISIONED` が含まれるか確認する。
   オンデマンド専用モデルは次の購入ステップ自体が失敗する。

2. [02_create_provisioned_throughput.sh](02_create_provisioned_throughput.sh)
   `create-provisioned-model-throughput` でモデルユニットを1つ購入する（`--commitment-duration`省略でNo Commitment）。
   レスポンスに含まれる `provisionedModelArn`（例: `arn:aws:bedrock:us-east-1:123456789012:provisioned-model/xxxxxxxxxxxx`）
   がルーティング先を決める鍵になる。

3. [03_get_provisioned_throughput.sh](03_get_provisioned_throughput.sh)
   `get-provisioned-model-throughput` でステータスが `Creating` → `InService` に遷移するのを確認する。

4. [04_invoke_ondemand_vs_provisioned.sh](04_invoke_ondemand_vs_provisioned.sh)
   同一プロンプトを (a) ベースモデルID（オンデマンド） (b) `provisionedModelArn` の両方に対して
   `invoke-model` で送信し比較する。CloudWatch `AWS/Bedrock` 名前空間の `ProvisionedModelArn` ディメンション
   にメトリクスが乗るかどうかで、実際にProvisioned容量が使われたかを判定できる。
   modelIdがベースモデルIDのままだと、このディメンションには何も記録されない。

5. [05_delete_provisioned_throughput.sh](05_delete_provisioned_throughput.sh)
   検証後の片付け（`delete-provisioned-model-throughput`）。

## 結論（1行）
Bedrock Provisioned Throughputは「購入」だけでは使われず、InvokeModel/Converseのmodel-idに
`provisionedModelArn`（ベースモデルIDとは別物）を明示的に渡すことで初めて専用容量にルーティングされる。

## 片付け
実機デプロイを行っていないため対象リソースなし。実行した場合は
[05_delete_provisioned_throughput.sh](05_delete_provisioned_throughput.sh) を実行し、
`list-provisioned-model-throughputs` で残骸がないことを確認する。
