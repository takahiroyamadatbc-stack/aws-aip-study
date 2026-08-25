"""調査Lambda: Bedrock Converseで推論ループとツール呼び出しを自前実装する。

Strands Agents SDK版なら Agent(tools=[...]) を定義するだけで済む部分を、
ここでは「モデルがtool_useを返す -> ツールを実行 -> 結果をmessagesへ積み戻す ->
再度モデルを呼ぶ」というループを手動で回す必要がある。3つのLambdaの中で
最も実装量が多いのはこのツール呼び出しループを持つ本ハンドラである。
"""

import boto3

MODEL_ID = "anthropic.claude-3-5-sonnet-20241022-v2:0"
MAX_TOOL_LOOPS = 5

bedrock = boto3.client("bedrock-runtime")

TOOL_CONFIG = {
    "tools": [
        {
            "toolSpec": {
                "name": "web_search",
                "description": "業界動向に関するWeb検索を行う",
                "inputSchema": {
                    "json": {
                        "type": "object",
                        "properties": {"query": {"type": "string"}},
                        "required": ["query"],
                    }
                },
            }
        }
    ]
}


def web_search(query: str) -> str:
    """検証用のダミー検索(実機では外部検索APIに差し替える)。"""
    return f"'{query}'に関するダミー検索結果(実装時は実APIに差し替え)"


def lambda_handler(event, context):
    topic = event.get("topic", "生成AIエージェントフレームワークの動向")
    messages = [
        {"role": "user", "content": [{"text": f"'{topic}'について調査してください。"}]}
    ]

    # --- 推論ループ: Strands Agents SDKならフレームワーク側が肩代わりする部分 ---
    output_message = None
    for _ in range(MAX_TOOL_LOOPS):
        response = bedrock.converse(
            modelId=MODEL_ID,
            messages=messages,
            toolConfig=TOOL_CONFIG,
        )
        output_message = response["output"]["message"]
        messages.append(output_message)

        if response["stopReason"] != "tool_use":
            break

        tool_results = []
        for block in output_message["content"]:
            if "toolUse" not in block:
                continue
            tool_use = block["toolUse"]
            if tool_use["name"] == "web_search":
                result_text = web_search(tool_use["input"]["query"])
            else:
                result_text = f"未知のツール: {tool_use['name']}"
            tool_results.append(
                {
                    "toolResult": {
                        "toolUseId": tool_use["toolUseId"],
                        "content": [{"text": result_text}],
                    }
                }
            )
        messages.append({"role": "user", "content": tool_results})
    # --- 推論ループここまで ---

    final_text = "".join(
        block["text"] for block in output_message["content"] if "text" in block
    )
    return {"topic": topic, "research_result": final_text}
