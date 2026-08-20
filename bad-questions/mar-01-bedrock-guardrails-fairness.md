# mar-01. Amazon Bedrock Guardrails（公平性メトリクスへの飛躍）

## 問題文

ある人材採用プラットフォーム企業が、Amazon Bedrock を使用した生成 AI（GenAI）の候補者スクリーニングアプリケーションを運用しています。このアプリケーションは、職務経歴書と求人要件をもとに候補者の適性スコアを生成します。同社は、性別・年齢・出身地域などの属性グループ間でスコアリングの偏りがないかを検証するため、2 つのプロンプトアプローチを比較する公平性評価を実装する必要があります。同社は公平性メトリクスをリアルタイムで収集・監視したいと考えています。属性グループ間の公平性メトリクスの差異が 10% を超えた場合にアラートを受信する必要があります。また、2 つのプロンプトアプローチのパフォーマンスを比較する隔週レポートも必要です。

これらの要件を最小限のカスタム開発で満たすソリューションはどれですか？

### 選択肢

**A.** Amazon Bedrock のモデル呼び出しログを Amazon S3 に格納する。AWS Glue ETL ジョブを使用して属性グループごとのスコアリング結果を集計する。Amazon QuickSight でダッシュボードを作成して公平性メトリクスを可視化する。Amazon SNS を設定して差異が検出された場合に通知を送信する。

**B.（想定解答）** Amazon Bedrock Prompt Management でプロンプトバリアントを定義し、Amazon Bedrock Flows でトラフィック比率を指定して両バリアントを並行運用する。Amazon Bedrock ガードレールをフローのプロンプトノードに関連付けて、属性グループごとの出力傾向を継続的にモニタリングする。ガードレールの介入メトリクスに対して CloudWatch アラームを設定し、しきい値超過時に通知を発行する。

**C.** Amazon SageMaker Model Monitor を設定して、属性グループごとのモデル出力ドリフトを検出する。Amazon Managed Grafana でカスタムダッシュボードを作成してメトリクスを表示する。AWS Lambda 関数を使用してプロンプトバリアント間のパフォーマンスを集計し、Amazon SES 経由でレポートを配信する。

**D.** Amazon Bedrock エージェントを作成し、アクショングループ内で公平性分析ロジックを実装する。エージェントの推論トレースを Amazon DynamoDB に格納する。Amazon EventBridge Scheduler を使用して定期的に DynamoDB のデータを集計し、公平性レポートを生成する。

### 想定解答の解説（原文要約）

「Bedrock Guardrails をフロー内の各プロンプトノードに直接関連付けることで、ユーザーの属性グループ（年齢層、地域、権限レベルなど）ごとに、モデルからの出力がセキュリティポリシーやブランドガイドラインに適合しているかを継続的にモニタリングできる。これにより、バリアントごとの安全性の違いを定量的に評価可能になる」「これらの仕組みは、すべて Bedrock のネイティブ機能と CloudWatch の標準機能だけで完結するため、独自の監視スクリプトやダッシュボードをカスタム開発するコストを最小限に抑えられる」

## 論点

想定解答Bは「Guardrailsをプロンプトノードに関連付けることで、属性グループごとの出力傾向を継続的にモニタリングできる」「すべてBedrockのネイティブ機能とCloudWatchの標準機能だけで完結する」としているが、これはGuardrailsおよびそのCloudWatch連携の実際の機能を超えた飛躍がある。Guardrailsは「属性グループ」という概念自体を認識しない機能であり、公平性メトリクス（属性グループ間のスコア差異）をネイティブに算出する仕組みではない。

## 検証結果

- Guardrailsは1回のAPI呼び出し（`ApplyGuardrail`、またはモデル呼び出しに付随する評価）ごとに、その入出力テキストが有害コンテンツ・拒否トピック・機微情報・文脈上の根拠不足等に該当するかを判定する機能であり、複数の呼び出しを横断して「属性グループ別」に分類・比較する仕組みは存在しない。（[Use cases for Amazon Bedrock Guardrails](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails-use.html)）
- Flowsのプロンプトノードに付与できる`guardrailConfiguration`は、そのノードの入出力に対してPII検出・有害コンテンツフィルタ・カスタムワードフィルタ等の**既存のGuardrailポリシーを適用するだけ**であり、「属性グループごとの出力傾向モニタリング」という別種の機能を追加するものではない。（[PromptFlowNodeConfiguration - Amazon Bedrock API Reference](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_PromptFlowNodeConfiguration.html)、[Node types for your flow](https://docs.aws.amazon.com/bedrock/latest/userguide/flows-nodes.html)）
- CloudWatch連携について公式ドキュメントで全ディメンションを確認したところ、Guardrails関連メトリクス（`InvocationsIntervened`等）で使えるディメンションは次の5系統のみ:
  - `Operation`（値: `ApplyGuardrail`）
  - `GuardrailContentSource`（値: `Input` / `Output`）
  - `GuardrailPolicyType`（値: `ContentPolicy` / `TopicPolicy` / `WordPolicy` / `SensitiveInformationPolicy` / `ContextualGroundingPolicy`）
  - `GuardrailArn`, `GuardrailVersion`
  - `FindingType` + `PolicyArn`/`GuardrailArn`（Automated Reasoning関連）

  **性別・年齢・出身地域のような「属性グループ」に対応するディメンションは1つも存在しない。**（[Monitor Amazon Bedrock Guardrails using CloudWatch metrics](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring-guardrails-cw-metrics.html)）
- したがって「属性グループ間の公平性メトリクスの差異が10%を超えた場合にアラート」という要件をCloudWatch Alarmで実現するには、呼び出し側のアプリケーションが候補者の属性情報を保持し、Embedded Metric Format等で**属性グループをディメンションに持つ独自のカスタムメトリクスを新規に設計・実装する**必要がある。これは「Bedrockのネイティブ機能とCloudWatchの標準機能だけで完結する」という解説の主張と矛盾する、実質的なカスタム開発である。

## 結論

選択肢Bの「Prompt ManagementでバリアントをA/B管理する」「Guardrailsの介入をCloudWatchで監視する」という個々の要素は事実として正しいAWSの機能だが、それらを組み合わせただけで「属性グループ間の公平性メトリクス収集・監視」という要件が満たされるという解説の論理には根拠がない。Guardrailsは属性という概念を持たず、CloudWatch側のディメンションにも属性グループに相当するものは存在しないため、この要件を満たすには選択肢Aと同程度かそれ以上の自前集計ロジック（属性タグ付け・カスタムメトリクス設計）が必要になる。「最小限のカスタム開発」という設問の評価軸において、AとBの間にあるはずの差が、解説が主張するほど明確ではない。
