"""Lab用の最小構成スタック。

Lambda関数1つだけを持つ、検証用の使い捨てスタック。
新しいLabを作る際はこのファイルをコピーし、以下を書き換える。
"""

from aws_cdk import Stack, Duration
from aws_cdk import aws_lambda as lambda_
from constructs import Construct


class AipLabStack(Stack):
    """AIP-C01検証用の最小Labスタック。"""

    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # 検証したい内容に応じてリソースを追加・変更する
        lambda_.Function(
            self,
            "Handler",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="handler.lambda_handler",
            code=lambda_.Code.from_asset("src"),
            timeout=Duration.seconds(10),
        )
