# Bedrock APIエラーのトラブルシューティング（429/400/503/403/404）

## これは何か

Amazon Bedrock（Runtime API: `InvokeModel`/`Converse`/`ConverseStream`等）を呼び出した際に返る代表的なエラーを整理する。トラブルシューティングの最初の一歩は、**エラーが「一時的で待てば/構成を変えれば解消するもの」か「リクエスト内容やアクセス権限そのものが誤っているもの」かを見分けること**。この区別を誤ると、直らないエラーを延々リトライしてコストと時間を浪費したり、逆に一時的なエラーを設定不備と誤認して不要な変更を加えたりする。

| 系統 | 該当エラー | 性質 | リトライの意味 |
|---|---|---|---|
| キャパシティ/可用性起因 | ThrottlingException（429）、ServiceUnavailableException（503） | 一時的。時間や送信元を変えれば成功しうる | **意味がある**（バックオフ必須） |
| リクエスト/権限起因 | ValidationException（400）、AccessDeniedException（403）、ResourceNotFoundException（404） | 恒常的。リクエスト内容・IAM設定・IDを直さない限り何度呼んでも失敗する | **意味がない**（単純リトライではなく原因側の修正が必要） |

## エラー一覧: 原因と対処

| エラー / HTTPステータス | 主な原因 | 対処法 |
|---|---|---|
| **ThrottlingException**<br>429 | ・アカウント/モデルごとのRPM・TPM上限超過<br>・複数クライアントが同一モデルのオンデマンド枠を共有し瞬間的にバーストした<br>・リトライの多重発火によるスパイク | ・指数バックオフ+ジッターでリトライ（SDK標準のリトライ機構を利用）<br>・**Cross-Region Inference（推論プロファイル）を使い、複数リージョンにリクエストを自動分散してオンデマンド枠のクォータを実質的に拡大する**（[[20-cross-region-inference]]）<br>・Provisioned Throughputを購入して専用キャパシティを確保<br>・Service Quotasでモデル単位のクォータ引き上げを申請<br>・クライアント側でリクエストレートを平滑化（キューイング等） |
| **ValidationException**<br>400 | ・リクエストJSONの構文/スキーマ誤り<br>・モデルがサポートしないパラメータ値（temperature/top_pの範囲外、max_tokens超過など）<br>・モデル固有のプロンプト形式（`InvokeModel`利用時、プロバイダごとに異なるリクエスト形式）に沿っていない<br>・入力トークン数がモデルのコンテキストウィンドウを超過<br>・必須フィールドの欠落、モデルIDの指定ミス | ・使用モデルのInference parameters仕様をドキュメントで確認し値を修正<br>・**Converse/ConverseStream APIを使いモデル横断で統一されたリクエスト形式に寄せる**（`InvokeModel`の生ペイロードはプロバイダごとに差異があり誤りやすい。[[25-streaming-responses]]）<br>・送信前にスキーマバリデーション・トークン数カウントを入れる<br>・エラーメッセージ本文（どのフィールドが不正か）を必ず確認する |
| **ServiceUnavailableException**<br>503 | ・Bedrockサービス側/モデル提供側の一時的な障害<br>・オンデマンド枠のキャパシティ不足（人気モデル・混雑時間帯）<br>・リージョン側の一時的な問題 | ・指数バックオフでリトライ（一時的事象であることが多い）<br>・**Cross-Region Inference（推論プロファイル）を利用し、単一リージョンの一時的なキャパシティ不足/障害を他リージョンへの自動ルーティングで回避する**（[[20-cross-region-inference]]）<br>・Provisioned Throughputでキャパシティを専有し安定性を確保<br>・Service Health Dashboard/CloudWatchで状態確認<br>・恒久対策としてマルチリージョン構成でフェイルオーバー |
| **AccessDeniedException**<br>403 | ・IAMプリンシパルに`bedrock:InvokeModel`等の権限がない<br>・Bedrockコンソールでのモデルアクセス（Model access）が有効化されていない<br>・SCP/リソースベースポリシーでのブロック<br>・カスタムモデルやKMS暗号化を使う場合のKMSキーポリシー不足 | ・IAMポリシーに必要なBedrockアクション（`InvokeModel`、`InvokeModelWithResponseStream`、`Converse`等）を追加<br>・Bedrockコンソール「Model access」で対象モデルへのアクセスをリクエスト・有効化（これはIAM権限とは別レイヤーの許可であり、両方揃わないと呼び出せない）<br>・SCP/権限境界/リソースポリシーを確認<br>・KMSキーを使う構成ならキーポリシーにIAMロールを許可 |
| **ResourceNotFoundException**<br>404 | ・指定したモデルID/カスタムモデルARN/Agent ID/Knowledge Base ID等が存在しない、またはタイポ<br>・そのリージョンでモデルが提供されていない（モデルの提供状況はリージョンごとに異なる）<br>・Provisioned Throughput ARN・推論プロファイルARNの参照誤り<br>・既に削除されたリソースを参照 | ・`ListFoundationModels`でモデルIDとリージョンでの提供有無を確認<br>・ARN/IDを正確にコピーし直す（推論プロファイルを使う場合は`us.`等のプレフィックス込みで指定）<br>・利用中リージョンがそのモデルをサポートしているか確認<br>・削除済みリソースでないか確認 |

## リトライ設計の指針

- **429/503のみ**を対象に指数バックオフ+ジッターでリトライする。400/403/404はリクエスト内容や権限設定という「再送しても変わらない原因」なので、リトライループに含めるとエラーを長引かせるだけでなく、403/404の大量再送はコスト・ログノイズの増加や誤ったアラート発報にもつながる
- SDK（boto3等）は標準でリトライ設定（`retries={"max_attempts": ..., "mode": "adaptive"}`など）を持つため、まずはこれを活用し、独自実装は最小限にする
- 429/503が頻発する場合、単純なリトライ回数の増加ではなく、**Provisioned Throughputでの専用キャパシティ確保**や**Cross-Region Inferenceでの分散**といった構造的な対策を検討する（リトライは症状への対処、CRI/Provisioned Throughputは原因側の緩和という位置づけの違い）

## 試験の勘所

- 「エラーは全部リトライすればいずれ成功する」という考え方は誤り。400/403/404は構成・権限側の恒久的な誤りであり、リトライでは解決しない
- 403は「IAM権限があれば呼べる」と誤解しやすいが、**IAMポリシーとBedrockコンソールでのモデルアクセス有効化は別レイヤー**であり、片方だけでは403が解消しないケースがある
- 429/503への対処として「リトライだけ」を選ばせようとする設問には注意。Cross-Region Inferenceや Provisioned Throughputという**構造的な緩和策**も選択肢に挙がりうる（[[20-cross-region-inference]]）
- 400は「モデルが悪い/サービス障害」ではなく「呼び出し側のリクエストが悪い」ことを示すエラーであり、Converse APIへの統一やパラメータ検証といった**呼び出し側の実装改善**が正しい対処になる
