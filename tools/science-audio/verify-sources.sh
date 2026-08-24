#!/usr/bin/env bash
# verify-sources.sh — 检查源列表里的链接是否还有效
# 对每个源只解析第一条（--simulate 不下载），跑得比真下载快得多。
# 用法:
#   ./verify-sources.sh                     # 两份列表都查
#   ./verify-sources.sh youtube
#   ./verify-sources.sh --level kids,middle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'USAGE'
用法: verify-sources.sh [youtube|podcast|both] [--level 分级[,分级...]]

只解析每个源的第一条内容来确认链接还活着，不下载任何东西。
有失效的源时退出码为 1，并在最后列出来。
USAGE
}

MODE="both"
LEVEL_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    youtube|podcast|podcasts|both|all) MODE="$1"; shift ;;
    --level)
      [[ $# -ge 2 ]] || { echo "--level 后面要跟分级" >&2; exit 1; }
      LEVEL_FILTER="$2"; shift 2 ;;
    --level=*) LEVEL_FILTER="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; echo >&2; usage >&2; exit 1 ;;
  esac
done

need_cmd yt-dlp

proxy_args=()
setup_proxy

OK_COUNT=0
BAD_COUNT=0
BAD_LIST=()

check_list() {
  local kind="$1" list_file="$2" use_cookies="$3"

  echo ""
  echo "######## $kind ########"
  echo "sources: $list_file"

  if [[ ! -f "$list_file" ]]; then
    echo "[skip] 无源文件: $list_file"
    return 0
  fi

  local cookie_args=()
  [[ "$use_cookies" == "1" ]] && setup_cookies

  local entries=()
  mapfile -t entries < <(load_sources "$list_file")

  local entry level name url
  for entry in "${entries[@]}"; do
    IFS=$'\t' read -r level name url <<< "$entry"

    if [[ "$level" == "__bad__" ]]; then
      echo "  ✗ [格式错误] $name"
      BAD_COUNT=$((BAD_COUNT + 1))
      BAD_LIST+=("$kind 格式错误: $name")
      continue
    fi

    level_wanted "$level" || continue

    printf '  … %-34s ' "[$level] $name"
    if yt-dlp --simulate --quiet --no-warnings \
         --playlist-items 1 \
         --socket-timeout 20 \
         --retries 2 \
         "${proxy_args[@]}" \
         "${cookie_args[@]}" \
         -- "$url" </dev/null >/dev/null 2>&1; then
      printf '✓\n'
      OK_COUNT=$((OK_COUNT + 1))
    else
      printf '✗ 解析失败\n'
      BAD_COUNT=$((BAD_COUNT + 1))
      BAD_LIST+=("[$level] $name → $url")
    fi
  done
}

case "$MODE" in
  youtube) check_list "youtube" "$YOUTUBE_SOURCES" 1 ;;
  podcast|podcasts) check_list "podcast" "$PODCAST_SOURCES" 0 ;;
  both|all)
    check_list "youtube" "$YOUTUBE_SOURCES" 1
    check_list "podcast" "$PODCAST_SOURCES" 0
    ;;
esac

echo ""
echo "========================================"
echo "可用: $OK_COUNT  失效: $BAD_COUNT"
if [[ ${#BAD_LIST[@]} -gt 0 ]]; then
  echo ""
  echo "需要处理的源："
  printf '  %s\n' "${BAD_LIST[@]}"
  exit 1
fi
echo "全部正常。"
