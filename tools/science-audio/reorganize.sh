#!/usr/bin/env bash
# reorganize.sh — 按 sources/*.txt 里的分级整理已下载的目录
#
# 默认只打印计划不动文件（dry-run），确认无误再加 --apply。
# 目标布局由 config.env 里的 GROUP_BY_LEVEL 决定：
#   GROUP_BY_LEVEL=1  →  $OUTPUT_ROOT/<分级>/<源名>/
#   GROUP_BY_LEVEL=0  →  $OUTPUT_ROOT/<源名>/
# 两个方向都支持，所以这个开关改来改去都能把目录挪回正确位置。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'USAGE'
用法: reorganize.sh [选项]

  --apply                真正执行；不加就只打印计划（默认）
  --root DIR             要整理的目录，默认 config.env 里的 OUTPUT_ROOT
  --rebuild-archives     顺带重建各目录的 downloaded.txt（从文件名里的视频 ID 还原）
  --min-duration SEC     列出超过这个时长的文件，默认 7200（2 小时），需要 ffprobe
  -h, --help

只移动 sources/*.txt 里登记过的目录。不认识的目录只报告，绝不动。
除了 0 字节的空文件，任何情况下都不会删除音频。
USAGE
}

APPLY=0
REBUILD_ARCHIVES=0
MIN_DURATION=7200
ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --root)
      [[ $# -ge 2 ]] || { echo "--root 后面要跟目录" >&2; exit 1; }
      ROOT="$2"; shift 2 ;;
    --root=*) ROOT="${1#*=}"; shift ;;
    --rebuild-archives) REBUILD_ARCHIVES=1; shift ;;
    --min-duration)
      [[ $# -ge 2 ]] || { echo "--min-duration 后面要跟秒数" >&2; exit 1; }
      MIN_DURATION="$2"; shift 2 ;;
    --min-duration=*) MIN_DURATION="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; echo >&2; usage >&2; exit 1 ;;
  esac
done

ROOT="${ROOT:-$OUTPUT_ROOT}"
if [[ ! -d "$ROOT" ]]; then
  echo "目录不存在: $ROOT" >&2
  exit 1
fi
ROOT="$(cd "$ROOT" && pwd)"

GROUP="${GROUP_BY_LEVEL:-0}"

echo "整理目录: $ROOT"
echo "目标布局: $([[ "$GROUP" == "1" ]] && echo '<分级>/<源名>/' || echo '<源名>/')"
if [[ "$APPLY" == "1" ]]; then
  echo "模式: 实际执行"
else
  echo "模式: dry-run（只看不动，确认后加 --apply）"
fi

# ---------- 1. 从源列表建立 源名 → 分级 的对照表 ----------
declare -A LEVEL_OF=()
for list_file in "$YOUTUBE_SOURCES" "$PODCAST_SOURCES"; do
  [[ -f "$list_file" ]] || continue
  while IFS=$'\t' read -r level name _url; do
    [[ "$level" == "__bad__" ]] && continue
    [[ -n "$name" ]] || continue
    LEVEL_OF["$name"]="$level"
  done < <(load_sources "$list_file")
done

echo "源列表里登记了 ${#LEVEL_OF[@]} 个目录名"

# ---------- 2. 找出所有已下载的源目录（含已分级和未分级两种布局）----------
# 判定标准：目录名在对照表里。深度只看 1 层和 2 层，不做全树递归。
declare -a PLANNED_FROM=() PLANNED_TO=()
declare -a UNKNOWN_DIRS=()
declare -a CONFLICTS=()

plan_move() {
  local from="$1" to="$2"
  [[ "$from" == "$to" ]] && return 0
  if [[ -e "$to" ]]; then
    CONFLICTS+=("$from  →  $to（目标已存在，跳过）")
    return 0
  fi
  PLANNED_FROM+=("$from")
  PLANNED_TO+=("$to")
}

shopt -s nullglob
for d1 in "$ROOT"/*/; do
  d1="${d1%/}"
  n1="$(basename "$d1")"

  if [[ -n "${LEVEL_OF[$n1]:-}" ]]; then
    # 一层：$ROOT/<源名>/
    if [[ "$GROUP" == "1" ]]; then
      plan_move "$d1" "$ROOT/${LEVEL_OF[$n1]}/$n1"
    fi
    continue
  fi

  # 两层：$ROOT/<分级>/<源名>/
  local_has_child=0
  for d2 in "$d1"/*/; do
    d2="${d2%/}"
    n2="$(basename "$d2")"
    if [[ -n "${LEVEL_OF[$n2]:-}" ]]; then
      local_has_child=1
      if [[ "$GROUP" == "1" ]]; then
        # 已分级，但可能归错级（源列表改过分级）
        plan_move "$d2" "$ROOT/${LEVEL_OF[$n2]}/$n2"
      else
        plan_move "$d2" "$ROOT/$n2"
      fi
    fi
  done
  [[ "$local_has_child" == "0" ]] && UNKNOWN_DIRS+=("$n1")
done
shopt -u nullglob

echo ""
echo "== 移动计划 =="
if [[ ${#PLANNED_FROM[@]} -eq 0 ]]; then
  echo "  目录已经在正确位置，无需移动。"
else
  for i in "${!PLANNED_FROM[@]}"; do
    printf '  %s\n    → %s\n' "${PLANNED_FROM[$i]#$ROOT/}" "${PLANNED_TO[$i]#$ROOT/}"
  done
  if [[ "$APPLY" == "1" ]]; then
    for i in "${!PLANNED_FROM[@]}"; do
      mkdir -p "$(dirname "${PLANNED_TO[$i]}")"
      mv "${PLANNED_FROM[$i]}" "${PLANNED_TO[$i]}"
    done
    echo "  已移动 ${#PLANNED_FROM[@]} 个目录。"
    # 清掉搬空之后剩下的空分级目录
    find "$ROOT" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
  fi
fi

if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
  echo ""
  echo "== 冲突（目标已存在，没动）=="
  printf '  %s\n' "${CONFLICTS[@]}"
fi

if [[ ${#UNKNOWN_DIRS[@]} -gt 0 ]]; then
  echo ""
  echo "== 源列表里没有的目录（原样保留，需要的话自己处理）=="
  printf '  %s\n' "${UNKNOWN_DIRS[@]}"
fi

# ---------- 3. 清理 0 字节文件 ----------
echo ""
echo "== 0 字节文件 =="
declare -a EMPTY=()
mapfile -t -d '' EMPTY < <(find "$ROOT" -type f -size 0 ! -name 'downloaded.txt' -print0)
if [[ ${#EMPTY[@]} -eq 0 ]]; then
  echo "  没有。"
else
  printf '  %s\n' "${EMPTY[@]/#$ROOT\/}"
  if [[ "$APPLY" == "1" ]]; then
    printf '%s\0' "${EMPTY[@]}" | xargs -0 rm -f
    echo "  已删除 ${#EMPTY[@]} 个。"
  fi
fi

# ---------- 4. 重建 downloaded.txt ----------
if [[ "$REBUILD_ARCHIVES" == "1" ]]; then
  echo ""
  echo "== 重建 downloaded.txt =="
  # yt-dlp 的输出模板把视频 ID 放在文件名末尾的方括号里，
  # 必须锚定 [xxx].ext 来抓；直接找「11 位字符」会抓到标题开头的单词
  while IFS= read -r -d '' dir; do
    declare -a ids=()
    declare -a noid=()
    while IFS= read -r -d '' f; do
      base="$(basename "$f")"
      if [[ "$base" =~ \[([A-Za-z0-9_-]{11})\]\.[A-Za-z0-9]+$ ]]; then
        ids+=("youtube ${BASH_REMATCH[1]}")
      else
        noid+=("$base")
      fi
    done < <(find "$dir" -maxdepth 1 -type f ! -name '*.srt' ! -name '*.vtt' \
                  ! -name '*.json' ! -name 'downloaded.txt' -print0)

    [[ ${#ids[@]} -eq 0 && ${#noid[@]} -eq 0 ]] && continue

    printf '  %-32s 有 ID %3d 条' "${dir#$ROOT/}" "${#ids[@]}"
    [[ ${#noid[@]} -gt 0 ]] && printf '，无 ID %d 条（不写入）' "${#noid[@]}"
    printf '\n'

    if [[ "$APPLY" == "1" && ${#ids[@]} -gt 0 ]]; then
      printf '%s\n' "${ids[@]}" | sort -u > "$dir/downloaded.txt"
    fi
  done < <(find "$ROOT" -mindepth 1 -type d -print0)
fi

# ---------- 5. 超长文件报告 ----------
echo ""
echo "== 时长超过 $((MIN_DURATION / 60)) 分钟的文件 =="
if command -v ffprobe >/dev/null 2>&1; then
  found=0
  while IFS= read -r -d '' f; do
    dur="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$f" 2>/dev/null || echo 0)"
    dur="${dur%.*}"
    [[ "$dur" =~ ^[0-9]+$ ]] || continue
    if [[ "$dur" -gt "$MIN_DURATION" ]]; then
      printf '  %5d min  %s\n' "$((dur / 60))" "${f#$ROOT/}"
      found=$((found + 1))
    fi
  done < <(find "$ROOT" -type f ! -name '*.srt' ! -name '*.vtt' \
                ! -name '*.json' ! -name 'downloaded.txt' -print0)
  [[ "$found" -eq 0 ]] && echo "  没有。"
else
  echo "  未找到 ffprobe，跳过（装 ffmpeg 即可）"
fi

echo ""
if [[ "$APPLY" == "1" ]]; then
  echo "完成。目录: $ROOT"
else
  echo "以上是 dry-run 结果，什么都没动。确认无误后加 --apply 执行。"
fi
