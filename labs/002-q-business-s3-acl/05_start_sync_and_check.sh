#!/usr/bin/env bash
# データソース同期を開始し、ACLがドキュメントに反映されたかを確認する。
set -euo pipefail

# shellcheck source=.lab002-ids.env
source .lab002-ids.env

aws qbusiness start-data-source-sync-job \
  --application-id "${APP_ID}" \
  --index-id "${INDEX_ID}" \
  --data-source-id "${DATA_SOURCE_ID}"

echo "同期ジョブを開始した。ステータスは以下で確認する。"
echo "  aws qbusiness list-data-source-sync-jobs --application-id ${APP_ID} --index-id ${INDEX_ID} --data-source-id ${DATA_SOURCE_ID}"
echo
echo "期待される挙動:"
echo "  - dept-sales/memo.txt は SalesGroup のメンバーにのみ検索・回答結果として表示される"
echo "  - dept-hr/memo.txt は HRGroup のメンバーにのみ表示される"
echo "  - config/acl-config.json 自体は exclusionPrefixes で除外済みのため、そもそもドキュメントとして取り込まれない"
echo
echo "確認方法（Q Business Web Experienceでのチャット、または以下のAPIで検索結果を比較）:"
echo "  aws qbusiness chat-sync --application-id ${APP_ID} --user-id <SalesGroup所属ユーザー> --user-message '人事部の情報を教えて'"
echo "  → HRGroup専用ドキュメントが回答に含まれないことを確認する"
