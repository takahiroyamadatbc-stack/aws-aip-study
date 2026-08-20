# mar-09. Amazon Bedrock Prompt Management（承認ワークフローの説明不足）

## 問題文

あるゲーム開発スタジオが、Amazon Bedrockを使用して多言語対応のゲーム内テキストを大量に生成するシステムを構築しています。生成するテキストは、クエストの説明や NPC のセリフ、アイテムの説明など多岐にわたります。このシステムでは、数百種類にのぼるプロンプトテンプレートの管理が必要です。現在は、複数のローカライゼーションチームが、世界中の複数の AWS リージョンからこれらのテンプレートを使ってテキストを生成しています。

この運用にあたり、シニアライターへのレビュー通知を含めた、承認ワークフロー付きのバージョン管理機能が必要です。また、プロンプトの編集や使用履歴を正確に記録する、詳細な監査証跡機能が求められています。さらに、ゲームの世界観やトーンの一貫性を保つために、プロンプトのパラメータを統一して管理する仕組みも必要です。

これらの要件をすべて満たす最適なソリューションはどれでしょうか？

### 選択肢

**A.** プロンプトテンプレートを Git リポジトリで管理し、AWS CodeCommit のプルリクエスト機能でシニアライターの承認ワークフローを実装する。AWS CodePipeline でテンプレートのデプロイを自動化する。Amazon CloudWatch Logs にプロンプト使用ログを格納する。

**B.（想定解答）** Amazon Bedrock Prompt Management を使用し、バージョン管理されたパラメータ付きテンプレートを作成する。AWS CloudTrail でプロンプトの作成・変更・使用の監査ログを自動記録する。IAM ポリシーでチームごとの承認権限を管理する。

**C.** プロンプトテンプレートを Amazon DynamoDB に格納し、条件付き書き込みでバージョン管理を実装する。AWS Step Functions で承認ワークフローを構築し、Amazon SES でシニアライターに通知を送信する。DynamoDB Streams でテンプレート変更をログに記録する。

**D.** Amazon SageMaker Studio のノートブックでプロンプトテンプレートを管理し、SageMaker Experiments でバージョンを追跡する。SageMaker Pipelines で承認ステップを実装し、Amazon SNS で通知を送信する。SageMaker の実験ログを監査証跡として使用する。

## 論点

想定解答Bの解説は「IAMポリシーを用いた詳細なアクセス制御を組み合わせることで、プロンプトの承認や本番環境への反映（ステージング移行）ができるユーザーを厳格に限定できる」としているが、これは要件の「シニアライターへのレビュー通知を含めた承認ワークフロー」を満たす説明として弱い。

## 検証結果

- Amazon Bedrock Prompt Management はプロンプトのバージョニング（ドラフト⇔スナップショットとしての数値バージョン）とパラメータ化をネイティブに提供する。アクセス制御は `bedrock:GetPrompt` 等のIAMアクションで行う。（[Deploy a prompt to your application using versions in Prompt management](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-management-deploy.html)、[Construct and store reusable prompts with Prompt management](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-management.html)）
- しかし「承認待ち」ステータスや、レビュアー（シニアライター）への通知をトリガーする機能はBedrock Prompt Managementにネイティブには存在しない。IAMポリシーは「誰が何をできるか」という静的なアクセス制御であり、「ドラフト作成 → レビュー依頼通知 → 承認/差し戻し → 本番反映」という動的なワークフローそのものを実装するものではない。
- AWSは公式サンプルとして [aws-samples/prompt-approval-example](https://github.com/aws-samples/prompt-approval-example) を公開しており、これはBedrock Prompt Managementの前後にStep FunctionsやSNS等の別コンポーネントを組み合わせて承認ワークフローを構築するものである。裏を返せば、承認ワークフロー（レビュー通知含む）はBedrock単体のネイティブ機能では完結せず、別途構築が必要であることの傍証になる。

## 結論

選択肢Bの「バージョン管理」「パラメータ化」「CloudTrailによる監査証跡」の部分は正しくBedrockの強みだが、「IAMポリシーでチームごとの承認権限を管理する」という記述だけで「シニアライターへのレビュー通知を含めた承認ワークフロー」要件を満たしたとするのは実態と乖離している。この要件を厳密に満たすには、Bedrock Prompt Management単体ではなく、選択肢Cのような通知・承認ステップ（Step Functions + SNS/SES等）を組み合わせる必要がある。出題側が「承認ワークフロー」という要件語をBedrockのIAMアクセス制御にやや強引にマッピングしている点は、解説の精度として改善の余地がある。
