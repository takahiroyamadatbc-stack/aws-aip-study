"""Step Functions + Lambda×3で3エージェントパイプラインを自前実装するスタック。

../strands/ (Strands Agents SDK版)との対比用。Step Functionsが提供するのは
ステート間のデータ受け渡し(入出力変換)・リトライ・並列実行の制御であって、
モデル主導の推論ループ(ツールを呼ぶかどうかの判断・呼び出し・結果の解釈)は
提供しない。そのため3つのLambda関数それぞれに、その部分を個別実装する必要がある
(特にsrc/research_handler.pyはツール呼び出しループを持つため実装量が最も多い)。
"""

from aws_cdk import Duration, Stack
from aws_cdk import aws_iam as iam
from aws_cdk import aws_lambda as lambda_
from aws_cdk import aws_stepfunctions as sfn
from aws_cdk import aws_stepfunctions_tasks as tasks
from constructs import Construct


class MultiAgentStepFunctionsStack(Stack):
    """AIP-C01検証用: Step Functions + Lambdaでのマルチエージェント自前実装。"""

    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        bedrock_invoke_policy = iam.PolicyStatement(
            actions=["bedrock:InvokeModel", "bedrock:Converse"],
            resources=["*"],
        )

        research_fn = self._make_agent_function("ResearchFunction", "research_handler.lambda_handler")
        summarize_fn = self._make_agent_function("SummarizeFunction", "summarize_handler.lambda_handler")
        report_fn = self._make_agent_function("ReportFunction", "report_handler.lambda_handler")

        for fn in (research_fn, summarize_fn, report_fn):
            fn.add_to_role_policy(bedrock_invoke_policy)

        research_task = tasks.LambdaInvoke(
            self,
            "ResearchStep",
            lambda_function=research_fn,
            output_path="$.Payload",
        )
        summarize_task = tasks.LambdaInvoke(
            self,
            "SummarizeStep",
            lambda_function=summarize_fn,
            output_path="$.Payload",
        )
        report_task = tasks.LambdaInvoke(
            self,
            "ReportStep",
            lambda_function=report_fn,
            output_path="$.Payload",
        )

        # 逐次パイプライン: 各タスクの出力(Payload)がそのまま次タスクの入力になる。
        # ここで自動化されるのは「JSONの受け渡し」のみ。前段の結果をどう解釈し、
        # 次にどのツールを呼ぶかという推論ループ自体は各Lambda内部の実装に依存する。
        definition = research_task.next(summarize_task).next(report_task)

        sfn.StateMachine(
            self,
            "ReportPipeline",
            state_machine_name="aip-004-report-pipeline",
            definition_body=sfn.DefinitionBody.from_chainable(definition),
            timeout=Duration.minutes(15),
        )

    def _make_agent_function(self, construct_id: str, handler: str) -> lambda_.Function:
        return lambda_.Function(
            self,
            construct_id,
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler=handler,
            code=lambda_.Code.from_asset("src"),
            timeout=Duration.seconds(60),
            memory_size=256,
        )
