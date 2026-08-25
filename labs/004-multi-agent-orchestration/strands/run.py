"""動作確認用のエントリポイント。

実機実行(pip install -r requirements.txt && python run.py)はユーザーの
明示的な指示があるまで行わない(標準ルール。CLAUDE.md「AWS実行について」参照)。
"""

from agents import run_report_pipeline

if __name__ == "__main__":
    result = run_report_pipeline("生成AIエージェントフレームワークの動向")
    print(result)
