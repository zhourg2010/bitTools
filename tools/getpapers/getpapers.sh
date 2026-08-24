#!/usr/bin/env bash
# getpapers.sh - ERIC 英语教育论文批量下载（Ubuntu 版）
# 用法: ./getpapers.sh [最大页数] [每页条数] [输出目录]
# 示例: ./getpapers.sh 10 40 ~/papers/20260824
# 检索词可用环境变量 ERIC_QUERY 覆盖

set -euo pipefail

MAX_PAGES=${1:-5}
ROWS_PER_PAGE=${2:-40}
OUTPUT_DIR=${3:-"./eric_english_education_papers"}

# peerreviewed 是检索字段而不是 URL 参数，必须写在 search 里才生效
DEFAULT_QUERY='peerreviewed:T AND ("English language teaching" OR TESOL OR EFL OR ESL OR "English education" OR "language pedagogy")'
QUERY=${ERIC_QUERY:-${DEFAULT_QUERY}}

PDF_DIR="${OUTPUT_DIR}/pdfs"
METADATA_FILE="${OUTPUT_DIR}/metadata.jsonl"
LOG_FILE="${OUTPUT_DIR}/download.log"
SLEEP_SECONDS=1.5
BASE_URL="https://api.ies.ed.gov/eric/"

for cmd in curl python3 file; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "❌ 缺少依赖：${cmd}" >&2
        exit 1
    fi
done

mkdir -p "${PDF_DIR}"
: > "${METADATA_FILE}"
: > "${LOG_FILE}"

log() { echo "$*" | tee -a "${LOG_FILE}"; }

RESPONSE_FILE=$(mktemp)
DOCS_FILE=$(mktemp)
trap 'rm -f "${RESPONSE_FILE}" "${DOCS_FILE}"' EXIT

log "开始检索 ERIC：${QUERY}"
log "输出目录：${OUTPUT_DIR}"
log "最大页数：${MAX_PAGES}，每页：${ROWS_PER_PAGE}"

START=0
PAGE=1
TOTAL_DOWNLOADED=0
TOTAL_CHECKED=0

while [[ ${PAGE} -le ${MAX_PAGES} ]]; do
    log "正在获取第 ${PAGE} 页（start=${START}）..."

    HTTP_CODE=$(curl -s -o "${RESPONSE_FILE}" -w "%{http_code}" --max-time 60 -G "${BASE_URL}" \
        --data-urlencode "search=${QUERY}" \
        --data-urlencode "format=json" \
        --data-urlencode "start=${START}" \
        --data-urlencode "rows=${ROWS_PER_PAGE}") || HTTP_CODE=000

    if [[ "${HTTP_CODE}" != "200" ]]; then
        log "API 请求失败，HTTP 状态码：${HTTP_CODE}"
        log "响应前 300 字符："
        log "$(head -c 300 "${RESPONSE_FILE}" 2>/dev/null || true)"
        break
    fi

    # 一次 python 调用搞定：解析、落元数据、生成文件名，避免每条记录反复起进程
    SUMMARY=$(python3 - "${RESPONSE_FILE}" "${DOCS_FILE}" "${METADATA_FILE}" <<'PY'
import json
import re
import sys

resp_path, docs_path, meta_path = sys.argv[1:4]

try:
    with open(resp_path, encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as exc:
    print("0\t0\t{}".format(exc))
    sys.exit(0)

response = data.get("response", {}) if isinstance(data, dict) else {}
docs = response.get("docs", [])
num_found = response.get("numFound", 0)


def first(value, default):
    """ERIC 的字段可能是标量也可能是数组，统一取第一个非空值。"""
    if isinstance(value, list):
        value = next((item for item in value if item), None)
    if value in (None, ""):
        return default
    return re.sub(r"\s+", " ", str(value)).strip() or default


def sanitize(text):
    text = re.sub(r"\s+", "_", text)
    text = re.sub(r'[/\\:*?"<>|]', "", text)
    text = re.sub(r"_+", "_", text).strip("_")
    return text[:120]


with open(docs_path, "w", encoding="utf-8") as docs_out, \
        open(meta_path, "a", encoding="utf-8") as meta_out:
    for doc in docs:
        meta_out.write(json.dumps(doc, ensure_ascii=False) + "\n")

        doc_id = first(doc.get("id"), "")
        if not doc_id:
            continue
        year = first(doc.get("publicationdateyear"), "0000")
        author = first(doc.get("author"), "Unknown")
        title = first(doc.get("title"), "untitled")

        filename = "{}_{}_{}.pdf".format(sanitize(author), year, sanitize(title))
        if len(filename) > 180:
            filename = "{}_{}_{}.pdf".format(sanitize(author), year, doc_id)

        docs_out.write("\t".join([doc_id, filename, title]) + "\n")

print("{}\t{}\t".format(len(docs), num_found))
PY
)

    IFS=$'\t' read -r DOCS_COUNT NUM_FOUND PARSE_ERROR <<< "${SUMMARY}"

    if [[ "${DOCS_COUNT}" -eq 0 ]]; then
        log "本页返回 0 条。可能原因：查询无结果 / JSON 解析失败 / 被限流。"
        [[ -n "${PARSE_ERROR}" ]] && log "解析错误：${PARSE_ERROR}"
        log "响应前 400 字符："
        log "$(head -c 400 "${RESPONSE_FILE}" 2>/dev/null || true)"
        break
    fi

    log "本页返回 ${DOCS_COUNT} 条（总计约 ${NUM_FOUND} 条）"

    while IFS=$'\t' read -r ID FILENAME TITLE; do
        [[ -n "${ID}" ]] || continue
        TOTAL_CHECKED=$((TOTAL_CHECKED + 1))
        PDF_PATH="${PDF_DIR}/${FILENAME}"

        # 先查本地再发请求，重跑续传时不会白白打一轮网络
        if [[ -f "${PDF_PATH}" ]]; then
            log "已存在，跳过：${FILENAME}"
            continue
        fi

        FULLTEXT_URL="https://files.eric.ed.gov/fulltext/${ID}.pdf"
        log "下载：${ID} → ${FILENAME}"

        DL_CODE=$(curl -sL -o "${PDF_PATH}" -w "%{http_code}" --max-time 90 "${FULLTEXT_URL}") || DL_CODE=000

        # 必须用 file -b：带文件名的输出里 ".pdf" 后缀会让任何内容都被误判成 PDF
        if [[ "${DL_CODE}" == "200" ]] && \
                [[ "$(file -b --mime-type "${PDF_PATH}" 2>/dev/null || true)" == "application/pdf" ]]; then
            TOTAL_DOWNLOADED=$((TOTAL_DOWNLOADED + 1))
            log "成功：${PDF_PATH}"
        else
            rm -f "${PDF_PATH}"
            if [[ "${DL_CODE}" == "404" ]]; then
                log "无全文（404）：${ID} - ${TITLE}"
            elif [[ "${DL_CODE}" == "200" ]]; then
                log "非 PDF 内容，已删除：${ID}"
            else
                log "下载失败（${DL_CODE}）：${FULLTEXT_URL}"
            fi
        fi

        sleep "${SLEEP_SECONDS}"
    done < "${DOCS_FILE}"

    START=$((START + ROWS_PER_PAGE))
    PAGE=$((PAGE + 1))

    if [[ "${NUM_FOUND}" =~ ^[0-9]+$ ]] && [[ ${START} -ge ${NUM_FOUND} ]]; then
        log "已取完全部 ${NUM_FOUND} 条结果。"
        break
    fi

    sleep "${SLEEP_SECONDS}"
done

log "========================================"
log "检查记录数：${TOTAL_CHECKED}"
log "成功下载数：${TOTAL_DOWNLOADED}"
log "元数据文件：${METADATA_FILE}"
log "PDF 目录：${PDF_DIR}"
log "完成。"
