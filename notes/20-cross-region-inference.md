# Cross-Region Inference（CRI）

## これは何か

Amazon Bedrockの推論リクエストを、呼び出し元が指定した1つのリージョンだけでなく、複数のAWSリージョンに**自動的に振り分けて処理する**機能。目的は以下の2つ。

- **可用性・スループットの向上**: 特定リージョンでスロットリング（オンデマンド推論のクォータ超過）が発生しても、他のリージョンの空き容量を使って処理を継続できる
- **追加コストなし**: ルーティング自体に追加料金は発生しない。課金は「どのリージョンから呼び出したか（呼び出し元リージョン）」を基準に計算される（実際に処理されたリージョンではない）

呼び出し方法は通常のモデルID（例: `anthropic.claude-3-5-sonnet-20241022-v2:0`）ではなく、**推論プロファイル（inference profile）ID**を指定する点が実装上の最大の違い。

```bash
# 推論プロファイル一覧を確認
aws bedrock list-inference-profiles

# 推論プロファイルIDを指定して呼び出し（モデルIDの代わりにプレフィックス付きIDを使う）
aws bedrock-runtime invoke-model \
  --model-id us.anthropic.claude-3-5-sonnet-20241022-v2:0 \
  --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":100,"messages":[{"role":"user","content":"hello"}]}' \
  --cli-binary-format raw-in-base64-out \
  output.json
```

推論プロファイルはモデルと「ルーティング先リージョンの集合」を紐付けた論理的なリソース。IAMの`bedrock:InvokeModel`権限も、実行先リージョンではなく**この推論プロファイルのARN**に対して付与する。

## Geographic 型 と Global 型

CRIには2種類あり、コンプライアンス要件に応じて選ぶ。

| 項目 | Geographic CRI | Global CRI |
|------|---------------|------------|
| データ在留 | 地理的境界内（US, EU, APACなど）に限定 | 世界中の商用リージョンに拡大しうる |
| ルーティング範囲 | 指定した地理（geo）内のみ | 世界中 |
| コスト | 通常料金 | 約10%安い |
| 用途 | データレジデンシー要件がある組織向け | コスト最適化を優先する組織向け |

データレジデンシー要件がある場合はGeographic型を選ぶ、というのが基本方針。推論プロファイルIDのプレフィックス（`us.` / `eu.` など）がgeoを表す。

## モニタリング

- CloudTrailにはリクエストを送った**呼び出し元リージョン**でログが記録される
- どのリージョンで実際に処理されたかは、CloudTrailイベントの `additionalEventData.inferenceRegion` フィールドで確認する
- CRIは、AWSアカウントで手動有効化（リージョンオプトイン）していないリージョンにもルーティングされうる。CRIを使う上でリージョンの手動有効化は不要

## サービスコントロールポリシー（SCP）との関係

ここが実装・運用でよく事故る（＝試験でも狙われやすい）ポイント。

### 何が起きるか

組織でリージョン制限SCP（`aws:RequestedRegion` を条件に使うDenyポリシーなど。Control TowerのRegion deny SCPが典型例）を敷いている環境で、CRIの推論プロファイルを呼び出すと、**呼び出し元リージョンはSCPで許可されているのに、Bedrockが内部的にルーティングした先のリージョンがSCPでブロックされていてリクエストが失敗する**、という現象が起きる。

推論プロファイルに含まれる宛先リージョンが1つでもSCPでブロックされていれば、他の宛先リージョンが許可されていてもリクエスト自体が失敗しうる、という点に注意（「一部のリージョンだけ許可すれば動く」わけではない）。

### 対処方針（型によって異なる）

| CRIの型 | SCP側で必要な対応 |
|---------|-------------------|
| Geographic CRI | 推論プロファイルが使いうる**宛先リージョンを全てSCPの許可リストに含める**（対象geo内の全リージョン。一覧はBedrockの「Supported Regions and models for inference profiles」ドキュメントで確認） |
| Global CRI | `aws:RequestedRegion` が **unspecified（未指定）** となるケースを許可する |

Global CRIで「unspecified を許可する」という考え方が直感的にわかりにくいが、これはIAMポリシー評価の一般原則に基づく。`StringNotEquals` で許可リージョンを列挙するタイプのリージョン制限Deny文は、**リクエストにそのキー自体が存在しない場合は条件不一致（＝Deny文は適用されない）**として評価される。Global CRIのルーティングでは宛先リージョンがリクエスト上で明示されないケースがあるため、こうした条件キー不在（unspecified）の扱いを潰す書き方（`StringNotEqualsIfExists` を使う、または明示的にBedrockの推論系アクションを対象外にするなど）をしてしまうと、Global CRIそのものが機能しなくなる。

### 実務上のSCPの書き方

「リージョンを絞る」という要件自体は変えず、Bedrockの推論系アクションだけを例外にするのが基本パターン。

```json
{
  "Effect": "Deny",
  "NotAction": [
    "bedrock:InvokeModel",
    "bedrock:InvokeModelWithResponseStream",
    "bedrock:CreateModelInvocationJob"
  ],
  "Resource": "*",
  "Condition": {
    "StringNotEquals": {
      "aws:RequestedRegion": ["ap-northeast-1", "us-east-1"]
    }
  }
}
```

- グローバルにリージョン制限を緩めるのではなく、**Bedrockの推論アクションだけをリージョン制限の対象から外す**（`NotAction` で除外する、あるいは許可リストに宛先リージョンを追加する）のが正しい対処
- IAMポリシー側（誰が推論プロファイルを呼べるか）とSCP側（どのリージョンでBedrockのAPIが使えるか）は別レイヤーの制御であり、両方が揃って初めてCRIが動く

## 試験でのひっかけポイント整理

- 「CRIは追加コストがかかる」→ 誤り。ルーティング自体は無料（Global型はむしろ約10%安い）
- 「CRIを使うには宛先リージョンを手動で有効化（オプトイン）する必要がある」→ 誤り。不要
- 「モデルIDを直接指定すればCRIが使える」→ 誤り。推論プロファイルID（`us.` / `eu.` などのプレフィックス付きID）を指定する必要がある
- 「リージョン制限SCPがあってもBedrockの呼び出し元リージョンさえ許可していればCRIは動く」→ 誤り。宛先リージョンがブロックされていれば失敗する
- 「SCPでリージョンを制限している環境ではGeographic/Global問わず同じ対処でよい」→ 誤り。Geographicは宛先リージョンの明示的な許可、Globalは`aws:RequestedRegion`unspecified時の扱いに注意、と対処が異なる
