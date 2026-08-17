"""検証用の最小Lambdaハンドラ。"""


def lambda_handler(event, context):
    """呼び出されたことが分かればよい、検証用の最小実装。"""
    return {"statusCode": 200, "body": "ok"}
