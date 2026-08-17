"""CDKアプリのエントリポイント。

スタック名は必ず `aip-NNN-topic` 形式にすること(例: aip-002-bedrock-guardrails)。
デプロイ時はタグ Project=aip-study を必ず付ける
(例: cdk deploy --tags Project=aip-study)。
"""

import aws_cdk as cdk

from stack import AipLabStack

app = cdk.App()

# TODO: NNN-topic をこのLabの連番・テーマに書き換える
AipLabStack(app, "aip-NNN-topic")

app.synth()
