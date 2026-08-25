"""要約Lambda: 前段(research)の出力をコンテキストとしてConverseへ渡す。

State間のJSON受け渡し自体はStep Functionsのoutput_path指定が担うが、
「どのキーをどう読み替えてプロンプトへ埋め込むか」は各Lambda内での自前実装になる。
"""

import boto3

MODEL_ID = "anthropic.claude-3-5-sonnet-20241022-v2:0"

bedrock = boto3.client("bedrock-runtime")


def lambda_handler(event, context):
    research_result = event["research_result"]
    messages = [
        {
            "role": "user",
            "content": [
                {
                    "text": (
                        "次の調査結果を重要度順に3〜5個の要点へ要約してください。\n\n"
                        f"{research_result}"
                    )
                }
            ],
        }
    ]
    response = bedrock.converse(modelId=MODEL_ID, messages=messages)
    summary_text = "".join(
        block["text"] for block in response["output"]["message"]["content"] if "text" in block
    )
    return {
        "topic": event["topic"],
        "research_result": research_result,
        "summary": summary_text,
    }
