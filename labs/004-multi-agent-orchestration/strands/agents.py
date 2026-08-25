"""Strands Agents SDKのWorkflowパターンで3エージェントを結線する。

調査 -> 要約 -> レポート作成の順に、前段タスクの出力が後続タスクの
コンテキストへ自動的に引き渡される。エージェントの推論ループ・ツール呼び出し・
コンテキスト受け渡しはすべてstrands_toolsのworkflowツールが肩代わりするため、
自前で書くのはタスク定義(何をするか)だけでよい。

実機デプロイ・実行はユーザーの明示的な指示があるまで行わない(標準ルール)。
strands-agents-toolsのworkflowツールのパラメータ名は公開ドキュメントに基づく
記述であり、実行前にインストール済みバージョンのAPIと突き合わせること。
"""

from strands import Agent
from strands.models import BedrockModel
from strands_tools import http_request, workflow

MODEL_ID = "anthropic.claude-3-5-sonnet-20241022-v2:0"


def build_orchestrator() -> Agent:
    """workflowツールを持つオーケストレータエージェントを作る。

    workflowツールはタスクのdependenciesを見て、前段タスクの出力を
    後続タスクの入力コンテキストへ自動的に引き渡す。
    """
    model = BedrockModel(model_id=MODEL_ID)
    return Agent(model=model, tools=[workflow, http_request])


def define_report_pipeline(orchestrator: Agent, topic: str) -> None:
    """調査 -> 要約 -> レポート作成のパイプラインを1つのworkflowとして定義する。"""
    orchestrator.tool.workflow(
        action="create",
        workflow_id="weekly_report",
        tasks=[
            {
                "task_id": "research",
                "description": (
                    f"'{topic}'について業界動向を調査し、"
                    "根拠となる出典URLと共に箇条書きでまとめる。"
                ),
                "system_prompt": (
                    "あなたは調査エージェントです。http_requestツールで外部情報を収集し、"
                    "一次情報の出典を明記してください。"
                ),
                "tools": ["http_request"],
                "priority": 5,
            },
            {
                "task_id": "summarize",
                "description": "researchタスクの調査結果を、重要度順に3〜5個の要点へ要約する。",
                "system_prompt": "あなたは要約エージェントです。冗長な記述を削り、要点を抽出してください。",
                "dependencies": ["research"],
                "priority": 3,
            },
            {
                "task_id": "report",
                "description": "summarizeタスクの要約を基に、見出し付きの週次レポートを成形する。",
                "system_prompt": "あなたはレポート作成エージェントです。Markdown形式で読みやすく成形してください。",
                "dependencies": ["summarize"],
                "priority": 1,
            },
        ],
    )


def run_report_pipeline(topic: str) -> str:
    """パイプラインを起動し、最終ステータス(各タスクの成果物を含む)を返す。"""
    orchestrator = build_orchestrator()
    define_report_pipeline(orchestrator, topic)
    orchestrator.tool.workflow(action="start", workflow_id="weekly_report")
    return orchestrator.tool.workflow(action="status", workflow_id="weekly_report")
