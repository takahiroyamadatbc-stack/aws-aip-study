#!/usr/bin/env bash
# 全部門のマッピングを1つにまとめたACL設定ファイルを、データと同じバケット内にアップロードする。
# ファイル名・配置場所は任意（同バケット内であればよい）。ここでは config/ プレフィックスに置く。
set -euo pipefail

BUCKET="aip-002-q-business-s3-acl"

aws s3 cp \
  ./acl-config.sample.json \
  "s3://${BUCKET}/config/acl-config.json"

echo "アップロードしたACL設定ファイル: s3://${BUCKET}/config/acl-config.json"
echo "注意: ACLファイルに記載のないプレフィックス（config/ 自体を含む）は全ユーザーがアクセス可能になる。"
echo "      そのため、データソース側の filterConfiguration.exclusionPrefixes で config/ を除外する。"
