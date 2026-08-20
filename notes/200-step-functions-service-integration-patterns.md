# AWS Step Functions のサービス統合パターンとヒューマンインザループ

## これは何か

**AWS Step Functions**は複数のAWSサービスを1つのワークフロー（ステートマシン）としてオーケストレーションするサーバーレスサービス。各State（Task状態）から他のAWSサービスを呼び出す際、**その呼び出しをどう完了とみなすか**の方式が3種類用意されている。これを**サービス統合パターン（Service Integration Pattern）**と呼ぶ。

呼び出し先のサービスが「すぐ終わる処理」なのか「バックグラウンドで動く長時間ジョブ」なのか「人間の判断待ち」なのかによって、Step Functions側の待ち方を変える必要がある。この使い分けを理解していないと、「人間の承認待ちを実現できるサービスはどれか」といった設問で、Step Functions以外の選択肢（EventBridge、SQS、Glueなど）に引っかかりやすい。

## 登場する要素

Step Functionsのリソース名（ARN）の末尾に付けるサフィックスで、3つのパターンを使い分ける。

| パターン | ARNのサフィックス | 完了とみなすタイミング | 主な用途 |
|---|---|---|---|
| **Request Response** | なし（デフォルト） | 呼び出し先APIから同期レスポンスが返ってきた時点 | Lambda関数呼び出し、DynamoDBへのPutItemなど、即座に終わる処理 |
| **Run a Job** | `.sync` | 起動したジョブそのものが完了した時点 | AWS Batch、ECS/Fargateタスク、SageMakerトレーニングジョブ、Glueジョブなど、起動後にバックグラウンドで走る処理 |
| **Wait for Callback** | `.waitForTaskToken` | 外部から**タスクトークンを添えたコールバックAPI**が呼ばれた時点 | 人間の承認待ち、外部システムからの非同期通知待ちなど、**Step Functions自身では完了を検知できない**処理 |

## waitForTaskToken によるヒューマンインザループの仕組み

1. State定義で `.waitForTaskToken` サフィックス付きのリソースを指定する（例: Lambda呼び出し）
2. 実行がこのStateに到達すると、Step Functionsは一意の**タスクトークン**を発行し、呼び出したLambda等にそのトークンを渡した上で**実行を一時停止**する
3. Lambdaはトークンをどこかに保存（DynamoDB等）しつつ、人間向けの通知（SNS、メール、Slack等）を送る
4. 人間がレビュー・承認操作を行うと、別のLambda（承認APIのハンドラなど）が保存しておいたトークンを使って `SendTaskSuccess`（承認/正常終了）または `SendTaskFailure`（却下/エラー）を呼ぶ
5. Step Functionsはこのコールバックを受けてワークフローを再開する

ポイントは、**Step Functions自身は「誰が」「いつ」タスクトークンを返してくるかを一切関知しない**こと。人間の操作でも、外部システムのWebhookでも、コールバックさえ来れば再開する汎用的な「待ち合わせ」の仕組みであり、ヒューマンインザループはその応用例の1つに過ぎない。

## Standard Workflows限定という制約

Step FunctionsにはStandard WorkflowsとExpress Workflowsの2種類があり、**`.waitForTaskToken`（および`.sync`）はStandard Workflowsでのみ使用可能**。Express Workflowsは高スループット・短時間実行（最大5分）を想定した課金モデルのため、Request Responseパターンしかサポートしない。

「ヒューマンインザループを実現したい」という要件が出てきた時点で、Express Workflowsの選択肢があれば消去できる（そもそもExpressにはコールバック待機の概念がない）。

## 他サービスとの混同ポイント（試験でのひっかけ）

- **AWS Glue**: ETL特化のオーケストレーションであり、Glueワークフロー自体にタスクトークンによる一時停止・再開の仕組みはない。「ワークフロー」という語に引きずられて「Glueでも人間承認ができそう」と誤解しやすいが、`SendTaskSuccess`はStep Functions固有のAPIであり、Glueとは直接紐づかない
- **Amazon EventBridge**: イベント駆動のルーティングは得意だが、「発行→誰かが処理するまで待つ」という一時停止・再開のステート管理は持たない。ルールが発火した時点で処理は完了扱いになり、後続の承認結果を待って先のステップに進む、という制御はできない
- **Lambda + SQSの自前実装**: `.waitForTaskToken`と同等のことは自前でも組めるが、待機中のタイムアウト管理・再試行・実行履歴の可視化をすべて自分で実装する必要があり、運用オーバーヘッドが大きい。Step Functionsのネイティブ機能と比較されたら、基本的にネイティブ機能を持つ選択肢が優先される
- **Amazon ElastiCache**: インメモリのキャッシュストアであり、永続性・耐久性の保証がない。「監査目的でレビュー決定を保存する」という要件が出てきたら、ElastiCacheのようなキャッシュ層ではなく、DynamoDBやS3のような耐久性のあるストレージが必要になる

## 試験でのひっかけポイント整理

- 「ヒューマンインザループ＝人間の判断を待つ仕組み」というキーワードが出たら、まず`.waitForTaskToken`（Wait for Callback パターン）を思い出す
- 一時停止・再開の仕組みを**ネイティブに持つのはStep Functionsだけ**。EventBridge/Glue/SQSはいずれも「ルーティング」「ジョブ実行」「メッセージキュー」であり、コールバック待機のステート管理機能は持たない
- Express Workflowsは`.waitForTaskToken`非対応。承認待ちのような長時間・不定時間の一時停止が必要な要件では、暗黙的にStandard Workflowsが前提になる
- 監査要件（レビュー決定の永続保存）が出てきたら、保存先はDynamoDBやS3のような耐久性ストレージが基本。ElastiCacheのようなインメモリ層は候補から外れる
