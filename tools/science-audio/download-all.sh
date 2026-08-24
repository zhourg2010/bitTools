#!/usr/bin/env bash
# download-all.sh — YouTube + Podcast 统一下载
# 用法:
#   ./download-all.sh                      # 两者都下（看 config 开关）
#   ./download-all.sh youtube
#   ./download-all.sh podcast
#   ./download-all.sh both --level kids,middle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'USAGE'
用法: download-all.sh [youtube|podcast|both] [--level 分级[,分级...]]

  youtube | podcast | both   下载哪一类，默认 both
  --level kids,middle        只下这些分级；不给就是全下
                             可用分级: kids middle ya adult unsorted

例:
  ./download-all.sh                          # 全下
  ./download-all.sh youtube --level kids     # 只下 YouTube 里的 kids
  ./download-all.sh --level ya,adult         # 两类里的 ya + adult
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

run_youtube=0
run_podcast=0
case "$MODE" in
  youtube) run_youtube=1 ;;
  podcast|podcasts) run_podcast=1 ;;
  both|all)
    run_youtube=1
    run_podcast=1
    ;;
esac

# 也可被 config / 环境变量关掉
[[ "${RUN_YOUTUBE:-1}" != "1" ]] && run_youtube=0
[[ "${RUN_PODCAST:-1}" != "1" ]] && run_podcast=0

need_cmd yt-dlp
need_cmd ffmpeg
mkdir -p "$OUTPUT_ROOT"

proxy_args=()   # setup_proxy 会重设，这里只是保证 set -u 下一定有定义
setup_proxy

TOTAL_SOURCES=0
FAILED_SOURCES=0
SKIPPED_ENTRIES=0
FILTERED_OUT=0

download_list() {
  local kind="$1"          # youtube | podcast
  local list_file="$2"
  local max_dur="$3"
  local use_cookies="$4"   # 1/0

  echo ""
  echo "######## $kind ########"
  echo "sources: $list_file"
  echo "max_items=$MAX_ITEMS_PER_SOURCE  duration<=${max_dur}s  level=${LEVEL_FILTER:-全部}"

  if [[ ! -f "$list_file" ]]; then
    echo "[skip] 无源文件: $list_file"
    return 0
  fi

  local cookie_args=()
  if [[ "$use_cookies" == "1" ]]; then
    setup_cookies
    # setup_cookies 靠动态作用域写上面这个 cookie_args
    if [[ ${#cookie_args[@]} -eq 0 ]]; then
      echo "[cookies] ⚠️  没有配置 cookie，年龄限制/会员内容会下不到"
    fi
  else
    echo "[cookies] skip ($kind)"
  fi

  # 先整份读进数组：避免循环体内的子进程抢走 while 的 stdin，把剩下的源吃掉
  local entries=()
  mapfile -t entries < <(load_sources "$list_file")

  if [[ ${#entries[@]} -eq 0 ]]; then
    echo "[skip] 源文件里没有可用条目: $list_file"
    return 0
  fi

  local entry level name url target archive
  for entry in "${entries[@]}"; do
    IFS=$'\t' read -r level name url <<< "$entry"

    if [[ "$level" == "__bad__" ]]; then
      echo "[skip] 格式不合法（应为 名称|链接），跳过: $name"
      SKIPPED_ENTRIES=$((SKIPPED_ENTRIES + 1))
      continue
    fi

    if ! level_wanted "$level"; then
      FILTERED_OUT=$((FILTERED_OUT + 1))
      continue
    fi

    # name / level 会直接拼进路径，含 / 或是 . / .. 会建出意料之外的目录
    if [[ "$name" == */* || "$name" == "." || "$name" == ".." \
       || "$level" == */* || "$level" == "." || "$level" == ".." ]]; then
      echo "[skip] 名称或分级不合法，跳过: $level|$name"
      SKIPPED_ENTRIES=$((SKIPPED_ENTRIES + 1))
      continue
    fi

    if [[ "${GROUP_BY_LEVEL:-0}" == "1" ]]; then
      target="$OUTPUT_ROOT/$level/$name"
    else
      target="$OUTPUT_ROOT/$name"
    fi
    archive="$target/downloaded.txt"
    mkdir -p "$target"
    TOTAL_SOURCES=$((TOTAL_SOURCES + 1))

    echo ""
    echo "========== [$level] $name =========="
    echo "$url"

    local args=(
      -x --audio-format "$AUDIO_FORMAT" --audio-quality "$AUDIO_QUALITY"
      --download-archive "$archive"
      --no-overwrites
      --ignore-errors
      --sleep-interval 2
      --max-sleep-interval 6
      --retries 10
      --fragment-retries 10
      --match-filter "duration <=? $max_dur"
      "${proxy_args[@]}"
    )

    # 直播回放/首播的 upload_date 可能为空，回落到 release_date，否则文件名会以 NA 开头
    args+=(--output "$target/%(upload_date>%Y%m%d,release_date>%Y%m%d)s - %(title)s [%(id)s].%(ext)s")

    if [[ "$kind" == "youtube" ]]; then
      args+=("${cookie_args[@]}")
    fi

    if [[ "${MAX_ITEMS_PER_SOURCE:-0}" -gt 0 ]]; then
      args+=(--playlist-end "$MAX_ITEMS_PER_SOURCE")
    fi

    # -- 之后才是 URL，避免以 - 开头的链接被当成选项
    # </dev/null 保证 yt-dlp 及其子进程绝不会去动脚本的 stdin
    if yt-dlp "${args[@]}" -- "$url" </dev/null; then
      :
    else
      echo "[warn] $name 有错误，继续"
      FAILED_SOURCES=$((FAILED_SOURCES + 1))
    fi

    # 清理 0 字节残文件，但别误删空的 archive；扩展名跟着 AUDIO_FORMAT 走，不写死
    find "$target" -type f -size 0 ! -name 'downloaded.txt' -delete 2>/dev/null || true
  done
}

MAX_YT="${MAX_DURATION_SEC_YOUTUBE:-2700}"
MAX_POD="${MAX_DURATION_SEC_PODCAST:-3600}"

echo "[download-all] root=$OUTPUT_ROOT mode=$MODE yt=$run_youtube pod=$run_podcast group_by_level=${GROUP_BY_LEVEL:-0}"

[[ "$run_youtube" == "1" ]] && \
  download_list "youtube" "$YOUTUBE_SOURCES" "$MAX_YT" 1

[[ "$run_podcast" == "1" ]] && \
  download_list "podcast" "$PODCAST_SOURCES" "$MAX_POD" 0

echo ""
echo "下载完成 → $OUTPUT_ROOT"
echo "源总数: $TOTAL_SOURCES  失败: $FAILED_SOURCES  跳过的坏条目: $SKIPPED_ENTRIES  被分级过滤: $FILTERED_OUT"

# 有失败就用非零退出码收场，定时任务才看得出来
if [[ "$FAILED_SOURCES" -gt 0 || "$SKIPPED_ENTRIES" -gt 0 ]]; then
  exit 1
fi
