"""CDKアプリのエントリポイント。

スタック名は aip-NNN-topic 形式(aip-004-multi-agent-orchestration)。
デプロイ時はタグ Project=aip-study を必ず付ける
(例: cdk deploy --tags Project=aip-study)。
"""

import aws_cdk as cdk

from stack import MultiAgentStepFunctionsStack

app = cdk.App()

MultiAgentStepFunctionsStack(app, "aip-004-multi-agent-orchestration")

app.synth()
