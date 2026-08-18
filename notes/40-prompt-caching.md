# Prompt Caching（プロンプトキャッシュ）

## 何のための機能か

LLM呼び出しでは、システムプロンプト・大きなドキュメント（RAGで取得した文書全文など）・Few-shot例・ツール定義といった**毎回ほぼ同じ内容が入力トークンとして繰り返し送られる**ことが多い。これらを都度フル計算すると、レイテンシもコストも無駄になる。

Prompt Cachingは、**入力プロンプトの先頭側の「変わらない部分」をサーバー側にキャッシュしておき、次回以降のリクエストではそのキャッシュを再利用することで、再計算をスキップして応答レイテンシとトークン単価の両方を下げる**機能。長いコンテキストを何度も使い回すユースケース（同じドキュメントに対する複数質問のチャットボット、長いシステムプロンプト＋ツール定義を持つエージェント等）で特に効く。

## 仕組み（プレフィックスマッチ）

- キャッシュは**プレフィックス一致**で成立する。プロンプトの先頭からある位置（**キャッシュチェックポイント**）までのバイト列が完全一致したときだけキャッシュヒットする。チェックポイントより前の内容が1バイトでも変わると、それより後ろのキャッシュはすべて無効になる
- リクエストの描画順序は **`tools` → `system` → `messages`** の順。最後の`system`ブロックにチェックポイントを置けば、`tools`＋`system`をまとめてキャッシュできる
- **TTL（Time To Live）**: キャッシュがヒットするたびにTTLがリセットされる。TTL内にヒットが一度も発生しなければキャッシュは失効する
- 安定した内容（システムプロンプト、ツール定義）を先頭に、変動する内容（タイムスタンプ、ユーザーごとの質問）を末尾に置くのが基本設計。システムプロンプトに`datetime.now()`や乱数IDを埋め込むと、そこから後ろが常にキャッシュミスする「サイレントな無効化」の典型パターン

## Anthropicネイティブ API と Bedrock での構文比較

同じ機能だが、**APIごとにキャッシュチェックポイントを表すフィールド名が異なる**。ここが混同しやすく、試験でも狙われやすい。

| | Anthropic Messages API（ネイティブ） | Bedrock **Converse/ConverseStream** API | Bedrock **InvokeModel** API（Claude向けbody） |
|---|---|---|---|
| チェックポイントのフィールド名 | `cache_control` | `cachePoint` | `cache_control`（ネイティブAPIと同じキー名） |
| 値の例 | `{"type": "ephemeral", "ttl": "5m"}` | `{"type": "default", "ttl": "5m"}` | `{"type": "ephemeral", "ttl": "5m"}` |
| 配置できる場所 | `system` / `messages` / `tools`の各コンテンツブロック | `system` / `messages` / `tools`の各コンテンツブロック | bodyの`system`/`messages`内 |
| 最大チェックポイント数 | 4 | 4（Claude系モデル） | 4 |
| 明示配置が必須か | 必須（top-levelの`cache_control`で自動配置も可） | **必須**。Bedrockでは「何もしなくても自動でキャッシュされる」機能はない（Claude向けの簡易運用として、静的コンテンツの末尾に1つ置けば約20コンテンツブロック分を自動で遡って最長一致を探してくれる、という「簡易キャッシュ管理」はある） | 必須 |

Bedrock Converse APIでの配置例（`system`にキャッシュポイントを置く場合）:

```json
"system": [
  { "text": "You are an app that creates play lists for a radio station..." },
  { "cachePoint": { "type": "default" } }
]
```

`messages`・`tools`にも同様に`cachePoint`ブロックを追加できる。TTLを明示したい場合:

```json
"cachePoint": {
    "type": "default",
    "ttl": "5m"
}
```

Bedrock InvokeModel API（Claude、ネイティブと同じ`cache_control`キーを使う）:

```python
body = {
    "anthropic_version": "bedrock-2023-05-31",
    "system": "Reply concisely",
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "Describe the best way to learn programming."},
            {
                "type": "text",
                "text": "<キャッシュしたい長い固定コンテキスト>",
                "cache_control": {"type": "ephemeral"}
            }
        ]
    }],
    "max_tokens": 2048
}
```

**チェックポイントの処理順序は`tools` → `system` → `messages`で、最小トークン数の判定は3セクションの累積トークン数に対して行われる。** そのため`tools`を変更すると、それより後ろの`system`・`messages`のキャッシュも道連れで無効になる。

## 対応モデルと最小トークン数・TTL（Bedrock, 2026年時点の代表例）

モデルによって**最小トークン数がかなり異なる**点に注意（1,024〜4,096）。

| モデル | 最小トークン数/チェックポイント | 最大チェックポイント数 | 対応TTL |
|---|---|---|---|
| Claude Opus 4.5 | 4,096 | 4 | 5分, **1時間** |
| Claude Sonnet 4.5 | 4,096 | 4 | 5分, **1時間** |
| Claude Haiku 4.5 | 4,096 | 4 | 5分, **1時間** |
| Claude Opus 4.6 | 4,096 | 4 | 5分のみ |
| Claude Sonnet 4.6 | 1,024 | 4 | 5分のみ |
| Claude 3.7 Sonnet | 1,024 | 4 | 5分のみ |
| Claude Opus 4 | 1,024 | 4 | 5分のみ |

- 最小トークン数に満たないプレフィックスにチェックポイントを置いても**推論自体はエラーにならず成功する**。ただし、その区間はキャッシュされない（黙ってフル課金になる）
- 1時間TTLを使う場合は`cachePoint`（Converse）/`cache_control`（InvokeModel）に`"ttl": "1h"`を明示する。省略時は常に5分TTL
- **1時間TTLと5分TTLを同一リクエスト内で混在させる場合、TTLが長いエントリを先（プロンプトの前方）に、短いエントリを後ろに置く必要がある**
- プロンプトキャッシュは**オンデマンド推論エンドポイントのみ対応**。バッチ推論API（Batch Inference）では使えない
- Cross-Region Inference（[[20-cross-region-inference]]参照）と併用可能。ただしCRISが高需要時に別リージョンへルーティングすると、そのリージョンにはキャッシュがまだ無いため**キャッシュ書き込みが増える**ことがある

## 料金体系

Anthropicネイティブ・Bedrockのいずれも経済性は同じ構造。

| 種別 | 料金 |
|---|---|
| キャッシュ書き込み（5分TTL） | 通常入力トークン単価の **約1.25倍** |
| キャッシュ書き込み（1時間TTL） | 通常入力トークン単価の **約2倍** |
| キャッシュ読み取り（ヒット） | 通常入力トークン単価の **約0.1倍（90%割引）** |
| キャッシュ対象外の入力トークン | 通常単価 |

- 損益分岐点の目安: 5分TTLは2回目のリクエストで元が取れる（1.25 + 0.1 = 1.35 ＜ 2回分の通常課金2.0）。1時間TTLは最低3回のヒットが必要（2.0 + 0.2×n）。**頻繁に（5分以内隔で）再利用されるプロンプトはむしろ5分TTLの方が有利**（何度ヒットしても追加料金なしでTTLがリセットされ続けるため）。1時間TTLが有利なのは「5分より疎だが1時間よりは密」な再利用パターン（レイテンシ重視の長時間セッション、エージェントのサブタスクなど）
- キャッシュヒットはレート制限（トークン/分クォータ）の消費が少ない、というメリットもある

## 使用量の確認（レスポンスのusageフィールド）

| | Anthropic Messages API | Bedrock Converse API |
|---|---|---|
| キャッシュ書き込みトークン数 | `usage.cache_creation_input_tokens` | `cacheWriteInputTokens` |
| キャッシュ読み取りトークン数 | `usage.cache_read_input_tokens` | `cacheReadInputTokens` |
| キャッシュ対象外の入力トークン数 | `usage.input_tokens` | `inputTokens`（**非キャッシュ分のみ**を表す点に注意） |

**総入力トークン数 = inputTokens（非キャッシュ）+ cacheReadInputTokens + cacheWriteInputTokens**。`inputTokens`だけを見て「入力が少ない」と誤解しないこと（キャッシュ経由の分がここに含まれていないだけ）。

`cache_read_input_tokens`（または`cacheReadInputTokens`）が同一プレフィックスの繰り返しリクエストでも常に0なら、システムプロンプト内の日時埋め込みやツール定義の順序不安定などサイレントな無効化要因を疑う。

## 試験でのひっかけポイント整理

- 「Bedrockでは特別な設定をしなくても自動的にプロンプトがキャッシュされる」→ 誤り。Claude系モデルでは`cachePoint`（Converse API）または`cache_control`（InvokeModel API）を明示的に配置する必要がある
- 「プロンプトキャッシュの最小トークン数はどのモデルでも同じ」→ 誤り。モデルによって1,024〜4,096まで異なり、Bedrockの新しいモデルほど最小値が大きくなっている場合もある（例: Claude Opus 4.5/Sonnet 4.5/Haiku 4.5は4,096）
- 「1時間TTLの方が常にお得」→ 誤り。書き込みコストが2倍になるため、5分以内の頻度で再利用されるなら5分TTL（ヒットのたびに無料でTTLリセット）の方が有利
- 「Converse APIでもAnthropicネイティブAPIと同じ`cache_control`というキー名を使う」→ 誤り。Converse APIでは`cachePoint`、InvokeModel APIでは（Anthropicモデルに限り）ネイティブと同じ`cache_control`を使う。APIによってキー名が異なる
- 「プロンプトキャッシュはバッチ推論でも使える」→ 誤り。オンデマンド推論エンドポイントのみ対応
- 「キャッシュのTTLはヒットしても延長されない（作成時刻からの固定TTL）」→ 誤り。ヒットするたびにTTLはリセットされる
- 「`tools`の内容を変えても`system`や`messages`のキャッシュには影響しない」→ 誤り。処理順序が`tools`→`system`→`messages`のため、`tools`の変更はそれより後ろのキャッシュをすべて無効化する
