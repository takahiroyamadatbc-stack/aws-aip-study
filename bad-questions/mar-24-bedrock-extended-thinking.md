# mar-24. Amazon Bedrock 拡張思考（extended thinking）とマニュアル引用の混同

## 問題文

ある製造業の企業が、工場作業員向けに機械の故障診断を支援する AI アシスタントを構築中です。プロダクトオーナーからの受け入れ基準として、診断結果を提示する際にモデルがどのような思考ステップで結論に至ったかを人間が追跡できることが求められており、参照した社内マニュアルの章・節を回答内に明示する必要もあります。

現場作業員が待たされないよう、応答はなるべく短い時間で返る必要があります。また、可能な限りマネージドサービスで構築して追加の自前実装を最小化することも条件として提示されています。

これらの基準を満たすソリューションはどれですか？

### 選択肢

**A.（想定解答）** Amazon Bedrock 上の Anthropic Claude モデルで拡張思考（extended thinking）機能を有効化する。推論トレースと引用箇所を Amazon OpenSearch Serverless に保存して監査に利用する。

**B.** LangChain の ReAct エージェントを Amazon EC2 上に自前でホストし、社内マニュアルは Amazon FSx for Lustre 上のベクトルインデックスから検索する。推論の中間ステップを Amazon ElastiCache に保存する。

**C.** Amazon Bedrock の基盤モデルに zero-shot プロンプトで明示するよう指示する。マニュアル参照は Amazon Kendra の Query API を呼ぶ Lambda を独自実装し、応答結合ロジックも Lambda 内に書く。

**D.** Amazon Bedrock Flows で推論ステップを 5 段階のノードに分割し、各ノードで chain-of-thought プロンプトを実行させる。各ノードの結果を Amazon SQS 経由で次段に渡し、最終応答を Amazon API Gateway 経由で返す。

### 解説（原文要約）

想定解答Aの根拠として、「Anthropic Claude の拡張思考（extended thinking）機能は、モデルが結論を出す前に構造化された思考ブロックをネイティブに出力する仕組みである」「思考と最終応答が明確に分離された構造化フォーマットで返される」「推論トレースと引用箇所を Amazon OpenSearch Serverless に保存する構成は監査時の検索要件に適しており、すべてマネージドサービスで完結する」としている。

## 論点

想定解答Aの解説には技術的に独立した2つの問題が混在している。

1. **thinkingブロックの性質の誤解**: 「拡張思考機能により推論トレースが明示的に含まれる」という説明は、返ってくる`thinking`テキストがモデルの内部推論をそのまま公開したものであるかのように読める。しかし実際には、多くの構成でこれは**要約（summarized）されたテキスト**であり、生のchain-of-thoughtそのものではない。
2. **「引用箇所」の出どころの誤解**: 拡張思考は「モデルが自分の推論過程を言語化する」機能であり、「社内マニュアルという外部知識ソースを検索し、その章・節を特定して回答に添付する」機能ではない。この2つは独立した機構であり、後者を実現するには検索/RAGの仕組み（例: Bedrock Knowledge Bases）が別途必要になる。選択肢Aにはこれが存在しない。

## 検証結果

### 1. thinkingブロックは要約であり、生のCoTではない

Anthropic公式ドキュメント「Thinking」の "Summarized thinking" 節に明記されている。

> When `display` is `"summarized"`, the thinking text you receive is a summary of Claude's full thinking process rather than the raw chain of thought. Summarized thinking provides the full intelligence benefits of thinking while preventing misuse. **No `display` setting returns the raw chain of thought.**
>
> — Summarization is processed by a different model from the one you target in your requests. The thinking model does not see the summarized output.

（[Thinking – Summarized thinking](https://platform.claude.com/docs/en/build-with-claude/thinking#summarized-thinking)）

さらに新しいモデル（Claude Opus 5 / Sonnet 5 / Fable 5 等）では `display` のデフォルトが `"omitted"` であり、その場合は`thinking`フィールドが空文字列で返り、そもそもテキストとしての推論トレースが得られない。

> `"omitted"`: thinking blocks are returned with an empty `thinking` field. ... This is the default on Claude Fable 5, Claude Mythos 5, Claude Opus 5, Claude Sonnet 5, Claude Opus 4.8, Claude Opus 4.7, and Claude Mythos Preview.

（[Thinking – Controlling thinking display](https://platform.claude.com/docs/en/build-with-claude/thinking#controlling-thinking-display)）

つまり「思考ステップで結論に至ったかを人間が追跡できる」という受け入れ基準に対して、拡張思考が提供するのは「要約された、安全性フィルタを経た推論の近似」であり、モデルの内部状態をそのまま監査可能な形で公開するものではない。この点を解説なしに「推論トレースが明示的に含まれる」と言い切るのは、監査・トレーサビリティ用途の設計判断としてミスリーディングである。

### 2. 拡張思考はマニュアルの検索・引用機能ではない

Anthropic公式ドキュメント「Thinking」「Extended thinking」の全体を確認したが、`thinking`ブロックが外部データソース（社内マニュアル等）を検索し、その出典（章・節）を返す仕組みであるという記述は存在しない。拡張思考はあくまでモデル自身の推論過程の言語化であり、モデルが学習時に知らない社内マニュアルの内容・章立てを正しく参照するには、その情報がプロンプトのコンテキストに実際に含まれている必要がある（＝検索/RAGが必要）。

一方、AWS公式ドキュメントでは、原文の出典（データソースの参照箇所）を回答に含める「引用（citations）」は、Amazon Bedrock **Knowledge Bases**（RAG）の `RetrieveAndGenerate` API の機能として明確に定義されている。

> Citations can be included in the generated response so the original data source can be referenced and accuracy can be checked. The `RetrieveAndGenerate` API output includes the generated response, source attribution, and retrieved text chunks, with citations containing `generatedResponsePart` and `retrievedReferences`.

（[Retrieve data and generate AI responses with Amazon Bedrock Knowledge Bases](https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base.html)）

つまり「参照した社内マニュアルの章・節を回答内に明示する」という要件を満たす標準的なマネージド構成は、

```
社内マニュアル → 検索/RAG（Bedrock Knowledge Bases） → Claude → 回答 + 引用（citations）
```

であり、拡張思考の有無とは独立に検索/RAGレイヤーが必須である。しかし選択肢A〜Dのいずれにも Bedrock Knowledge Bases（またはそれに相当するマネージドRAG）が登場しない。選択肢Cのみ検索コンポーネント（Kendra）を持つが、Lambdaでの独自実装が理由に不正解とされており、「Bedrock Knowledge Bases + Citations」という最も自然な正解候補が選択肢に存在しないまま、Extended Thinkingを検索・引用の代替であるかのように扱っているのが本問の構造的な弱点である。

## 結論

想定解答Aの解説には次の2点で改善の余地がある。

1. 拡張思考の`thinking`出力を「モデルの内部思考プロセスの明示的なトレース」であるかのように説明しているが、実際には要約（またはデフォルト設定によっては空）であり、生のchain-of-thoughtではない（[Summarized thinking](https://platform.claude.com/docs/en/build-with-claude/thinking#summarized-thinking)）。監査要件に対して「要約された近似である」という限界に一切触れていない。
2. 「参照した社内マニュアルの章・節を回答内に明示する」という引用機能の要件を、拡張思考機能だけで満たせるかのように書いているが、拡張思考は自身の推論の言語化であり、外部ドキュメントの検索・出典付与はBedrock Knowledge Bases等のRAG機構の役割である。選択肢AにはこのRAGレイヤーが存在せず、社内マニュアルをどう検索してモデルに渡すかが未定義のまま「引用箇所をOpenSearch Serverlessに保存する」としている点は、そもそも引用箇所をどう生成するかの説明が抜けている。
