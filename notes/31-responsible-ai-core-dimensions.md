# AWSが定義する責任あるAI（Responsible AI）の8つのコアディメンション

AWSは「責任あるAI」を単一の機能や設定ではなく、**設計・開発・運用のライフサイクル全体を横断する8つの観点（コアディメンション）**として整理している。試験では「この選択肢はどのディメンションの説明か」「あるディメンションを満たすためにどのAWSサービス・機能を使うか」という形で問われやすい。このノートは各ディメンションの定義と、対応するAWSサービス・機能をセットで整理する。

## 8つのコアディメンション一覧

| ディメンション | 定義（何を問う観点か） | 典型的な問い |
|----------------|------------------------|--------------|
| Fairness（公平性） | モデルの予測・出力が、人種・性別・年齢等の属性によって不当に偏っていないか | 特定の属性グループに対して不利な判定が出ていないか？ |
| Explainability（説明可能性） | なぜモデルがその出力・予測に至ったのか、要因を人間が理解できる形で示せるか | どの特徴量が予測にどれだけ寄与したか？ |
| Privacy and Security（プライバシーとセキュリティ） | 学習データ・入出力データに含まれる個人情報・機微情報が保護され、不正アクセスから守られているか | PIIが漏洩・混入していないか？アクセス制御は十分か？ |
| Safety（安全性） | モデルが有害・危険・意図しない出力（暴力的表現、危険な指示への追従等）を生成しないか | 有害コンテンツの生成を防げているか？ |
| Controllability（制御性） | AIシステムの挙動を人間が監視・介入・修正できる仕組みがあるか | 想定外の挙動をした時に止められるか？人間の承認プロセスがあるか？ |
| Veracity and Robustness（真実性と堅牢性） | 出力が事実に基づき正確か（ハルシネーションしていないか）、予期しない入力・敵対的入力に対しても安定して動くか | 事実と異なる回答をしていないか？異常な入力で誤動作しないか？ |
| Governance（ガバナンス） | 責任あるAIの実践を定義・実装・徹底するための組織的なプロセス・体制が存在するか | 誰が承認し、誰が監査し、どう記録が残るか？ |
| Transparency（透明性） | AIシステムの能力・限界・学習データ・意図された用途について、利用者・関係者に情報が開示されているか | 利用者はこのAIが何をどう学習したモデルか知ることができるか？ |

- 8つは**互いに独立ではなく重なり合う**。例えばハルシネーション対策は主にVeracity and Robustnessの話だが、その検知結果を人間が確認・修正できる仕組みを作ればControllabilityにも関わる
- 試験では「Fairnessの話をExplainabilityの選択肢にすり替える」といった**隣接ディメンションの取り違え**が典型的なひっかけになる。定義の**問いの主語**（「偏りがないか」＝Fairness、「理由が分かるか」＝Explainability）で区別するとよい

## 各ディメンションと対応するAWSサービス・機能

| ディメンション | 主なAWSサービス・機能 | 何をしてくれるか |
|----------------|------------------------|------------------|
| Fairness | **SageMaker Clarify** | 学習前（pre-training bias、例: クラス不均衡の検出）・学習後（post-training bias、例: 属性グループ間での予測結果の偏り）のバイアスメトリクスを計算 |
| Explainability | **SageMaker Clarify**（SHAP値による特徴量重要度）、**SageMaker Model Cards** | 個々の予測に対してどの特徴量がどれだけ寄与したかを定量化・可視化 |
| Privacy and Security | **Amazon Macie**（S3上のPII棚卸し）、**Amazon Comprehend**（テキストPII検出）、**Bedrock Guardrails**（機微情報フィルター）、IAM／KMS／VPCエンドポイント | データの発見・マスキング・暗号化・アクセス制御（詳細は[[30-bedrock-guardrails-and-reliability]]のPII検出の使い分け表を参照） |
| Safety | **Bedrock Guardrails**（コンテンツフィルター、拒否トピック、ワードフィルター） | 有害コンテンツ・望ましくない話題の生成をブロック（詳細は[[30-bedrock-guardrails-and-reliability]]） |
| Controllability | **Amazon Augmented AI（A2I）**（人間によるレビューworkflow）、Guardrailsの`ApplyGuardrail`単体呼び出し、エージェントのアクション権限の最小化（IAM境界） | 自動化されたAIの判断に人間の承認・介入ポイントを差し込む |
| Veracity and Robustness | **Bedrock Guardrailsの Contextual Grounding Check**（ハルシネーション検知）、**Automated Reasoning checks**（形式論理での検証）、敵対的入力に対するレッドチーミング・負荷テスト | 出力の事実整合性の検証、想定外入力への耐性確認（詳細は[[30-bedrock-guardrails-and-reliability]]のGroundingセクション） |
| Governance | **SageMaker Model Cards**（モデルの目的・学習データ・評価結果・既知の制約を文書化）、**SageMaker Role Manager**（ペルソナ別の最小権限ロールをテンプレートから付与）、**AWS AI Service Cards**、CloudTrailによる監査ログ | モデルのライフサイクル全体を通じた文書化・権限管理・監査証跡の整備 |
| Transparency | **AWS AI Service Cards**（AWSが提供するAIサービス自体の意図された用途・限界を開示する文書）、**SageMaker Model Cards**（自社が作ったモデルについて同様の情報を開示） | 「AWSのAIサービスについての透明性」と「自社モデルについての透明性」を、それぞれ別の文書形式でカバーする |

- **AI Service CardsとModel Cardsの違い**が試験のひっかけになりやすい。AI Service Cardsは**AWSが提供するAIサービス（Rekognition、Comprehend等）自体**についてAWSが公開している文書、Model Cardsは**ユーザーがSageMakerで学習・デプロイした自分のモデル**について作成する文書。「誰が」「何について」書く文書かが違う
- Fairness・Explainabilityは主に**モデル開発段階（SageMaker Clarify）**、Safety・Privacyは主に**推論時のランタイム防御（Guardrails）**、Governance・Transparencyは**ライフサイクル全体を通じた文書化・体制**という時間軸の違いも押さえておくと選択肢を絞りやすい

## 試験でのひっかけポイント整理

- 「Explainabilityは、モデルが偏りなく公平に判定しているかを保証する観点である」→ 誤り。それはFairnessの定義。Explainabilityは「なぜその判定になったか」を人間が理解できるようにする観点であり、公平かどうかとは別軸
- 「SageMaker ClarifyはFairnessだけでなくExplainabilityの検証にも使える」→ 正しい。Clarifyはバイアスメトリクス（Fairness）とSHAP値による特徴量重要度（Explainability）の両方を提供する、単一目的のツールではない点に注意
- 「Bedrock GuardrailsだけですべてのResponsible AIディメンションをカバーできる」→ 誤り。GuardrailsはSafety（有害コンテンツ抑制）とVeracity and Robustness（Grounding Check）に強いが、Fairness・Explainability・Governance・Transparencyは別のサービス・プロセス（SageMaker Clarify、Model Cards等）で補う必要がある
- 「AI Service Cardsは自社で学習したカスタムモデルについても作成できる」→ 誤り。AI Service CardsはAWSが自社のAIサービスについて公開する文書であり、ユーザーが自分のモデルについて作成するのはSageMaker Model Cardsの役割
- 「Controllabilityは、モデルの精度を人間がチェックして正確性を担保する観点である」→ 誤り。精度・事実整合性の話はVeracity and Robustness。Controllabilityは「動作中のAIシステムに人間が介入・修正できる仕組みがあるか」という制御性の観点であり、正確性そのものの評価とは別
