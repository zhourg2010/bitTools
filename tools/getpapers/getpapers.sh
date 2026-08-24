#!/usr/bin/env bash
# getpapers.sh - ERIC 英语教育论文批量下载（Ubuntu 版）
# 用法: ./getpapers.sh [最大页数] [每页条数] [输出目录]
# 示例: ./getpapers.sh 10 40 /home/rong/ClaudeCode/TinyMelon/收件/20260824

set -euo pipefail

MAX_PAGES=${1:-5}
ROWS_PER_PAGE=${2:-40}
OUTPUT_DIR=${3:-"./eric_english_education_papers"}

QUERY='("English language teaching" OR TESOL OR EFL OR ESL OR "English education" OR "language pedagogy")'
PDF_DIR="${OUTPUT_DIR}/pdfs"
METADATA_FILE="${OUTPUT_DIR}/metadata.jsonl"
LOG_FILE="${OUTPUT_DIR}/download.log"
SLEEP_SECONDS=1.5

mkdir -p "${PDF_DIR}"
: > "${METADATA_FILE}"
: > "${LOG_FILE}"

echo "开始检索 ERIC：${QUERY}" | tee -a "${LOG_FILE}"
echo "输出目录：${OUTPUT_DIR}" | tee -a "${LOG_FILE}"
echo "最大页数：${MAX_PAGES}，每页：${ROWS_PER_PAGE}" | tee -a "${LOG_FILE}"

BASE_URL="https://api.ies.ed.gov/eric/"
START=0
PAGE=1
TOTAL_DOWNLOADED=0
TOTAL_CHECKED=0

sanitize() {
    local s="$1"
    s=$(echo "$s" | tr -s '[:space:]' '_')
    s=$(echo "$s" | tr -d '/\\:*?"<>|')
    s=$(echo "$s" | tr -s '_' | sed 's/^_//;s/_$//')
    echo "${s:0:120}"
}

while [[ ${PAGE} -le ${MAX_PAGES} ]]; do
    echo "正在获取第 ${PAGE} 页（start=${START}）..." | tee -a "${LOG_FILE}"

    # 增加 HTTP 状态码捕获，方便诊断
    HTTP_CODE=$(curl -s -o /tmp/eric_response.json -w "%{http_code}" -G "${BASE_URL}" \
        --data-urlencode "search=${QUERY}" \
        --data-urlencode "format=json" \
        --data-urlencode "start=${START}" \
        --data-urlencode "rows=${ROWS_PER_PAGE}" \
        --data-urlencode "peerreviewed=true" 2>/dev/null || echo "000")

    RESPONSE=$(cat /tmp/eric_response.json 2>/dev/null || echo "")

    if [[ "${HTTP_CODE}" != "200" ]]; then
        echo "API 请求失败，HTTP 状态码：${HTTP_CODE}" | tee -a "${LOG_FILE}"
        echo "响应前 300 字符：" | tee -a "${LOG_FILE}"
        echo "${RESPONSE:0:300}" | tee -a "${LOG_FILE}"
        break
    fi

    DOCS_COUNT=$(echo "${RESPONSE}" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    print(len(data.get("response", {}).get("docs", [])))
except Exception as e:
    print(0)
' 2>/dev/null || echo 0)

    if [[ "${DOCS_COUNT}" -eq 0 ]]; then
        echo "本页返回 0 条。可能原因：查询无结果 / JSON 解析失败 / 被限流。" | tee -a "${LOG_FILE}"
        echo "响应前 400 字符：" | tee -a "${LOG_FILE}"
        echo "${RESPONSE:0:400}" | tee -a "${LOG_FILE}"
        break
    fi

    NUM_FOUND=$(echo "${RESPONSE}" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get("response", {}).get("numFound", 0))
except Exception:
    print("?")
' 2>/dev/null || echo "?")

    echo "本页返回 ${DOCS_COUNT} 条（总计约 ${NUM_FOUND} 条）" | tee -a "${LOG_FILE}"

    TMP_DOCS=$(mktemp)
    echo "${RESPONSE}" | python3 -c '
import sys, json
data = json.load(sys.stdin)
for doc in data.get("response", {}).get("docs", []):
    print(json.dumps(doc, ensure_ascii=False))
' > "${TMP_DOCS}"

    while IFS= read -r doc; do
        ID=$(echo "${doc}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("id",""))' 2>/dev/null || echo "")
        TITLE=$(echo "${doc}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("title","untitled"))' 2>/dev/null || echo "untitled")
        YEAR=$(echo "${doc}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("publicationdateyear","0000"))' 2>/dev/null || echo "0000")
        AUTHOR=$(echo "${doc}" | python3 -c '
import sys, json
d = json.load(sys.stdin)
a = d.get("author", [])
if isinstance(a, list) and a:
    print(a[0])
else:
    print("Unknown")
' 2>/dev/null || echo "Unknown")

        echo "${doc}" >> "${METADATA_FILE}"

        FULLTEXT_URL="https://files.eric.ed.gov/fulltext/${ID}.pdf"

        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -I "${FULLTEXT_URL}" 2>/dev/null || true)
        HTTP_CODE=${HTTP_CODE:-000}
        ((TOTAL_CHECKED++)) || true

        if [[ "${HTTP_CODE}" != "200" ]]; then
            echo "无全文（${HTTP_CODE}）：${ID} - ${TITLE}" | tee -a "${LOG_FILE}"
            continue
        fi

        SAFE_AUTHOR=$(sanitize "${AUTHOR}")
        SAFE_TITLE=$(sanitize "${TITLE}")
        FILENAME="${SAFE_AUTHOR}_${YEAR}_${SAFE_TITLE}.pdf"
        if [[ ${#FILENAME} -gt 180 ]]; then
            FILENAME="${SAFE_AUTHOR}_${YEAR}_${ID}.pdf"
        fi
        PDF_PATH="${PDF_DIR}/${FILENAME}"

        if [[ -f "${PDF_PATH}" ]]; then
            echo "已存在，跳过：${FILENAME}" | tee -a "${LOG_FILE}"
            continue
        fi

        echo "下载：${ID} → ${FILENAME}" | tee -a "${LOG_FILE}"
        if curl -sL --fail --max-time 90 -o "${PDF_PATH}" "${FULLTEXT_URL}"; then
            if file "${PDF_PATH}" 2>/dev/null | grep -qi "PDF"; then
                ((TOTAL_DOWNLOADED++)) || true
                echo "成功：${PDF_PATH}" | tee -a "${LOG_FILE}"
            else
                rm -f "${PDF_PATH}"
                echo "非 PDF 内容，已删除：${ID}" | tee -a "${LOG_FILE}"
            fi
        else
            echo "下载失败：${FULLTEXT_URL}" | tee -a "${LOG_FILE}"
            rm -f "${PDF_PATH}"
        fi

        sleep "${SLEEP_SECONDS}"
    done < "${TMP_DOCS}"

    rm -f "${TMP_DOCS}"
    START=$((START + ROWS_PER_PAGE))
    PAGE=$((PAGE + 1))
    sleep "${SLEEP_SECONDS}"
done

echo "========================================" | tee -a "${LOG_FILE}"
echo "检查记录数：${TOTAL_CHECKED}" | tee -a "${LOG_FILE}"
echo "成功下载数：${TOTAL_DOWNLOADED}" | tee -a "${LOG_FILE}"
echo "元数据文件：${METADATA_FILE}" | tee -a "${LOG_FILE}"
echo "PDF 目录：${PDF_DIR}" | tee -a "${LOG_FILE}"
echo "完成。" | tee -a "${LOG_FILE}"
