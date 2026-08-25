"""レポート作成Lambda: 要約をMarkdown形式のレポートへ成形する。"""

import boto3

MODEL_ID = "anthropic.claude-3-5-sonnet-20241022-v2:0"

bedrock = boto3.client("bedrock-runtime")


def lambda_handler(event, context):
    topic = event["topic"]
    summary = event["summary"]
    messages = [
        {
            "role": "user",
            "content": [
                {
                    "text": (
                        f"'{topic}'に関する以下の要約を、見出し付きのMarkdown週次レポートへ"
                        f"成形してください。\n\n{summary}"
                    )
                }
            ],
        }
    ]
    response = bedrock.converse(modelId=MODEL_ID, messages=messages)
    report_text = "".join(
        block["text"] for block in response["output"]["message"]["content"] if "text" in block
    )
    return {"topic": topic, "report": report_text}
