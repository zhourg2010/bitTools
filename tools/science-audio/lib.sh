#!/usr/bin/env bash
# lib.sh — 加载配置与源列表
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$TOOLS_DIR/config.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "缺少配置: $CONFIG_FILE" >&2
  echo "先复制一份模板: cp $TOOLS_DIR/config.env.example $CONFIG_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

OUTPUT_ROOT="${OUTPUT_ROOT:-$HOME/ScienceAudio}"
USE_PROXY="${USE_PROXY:-1}"
PROXY_ADDRESS="${PROXY_ADDRESS:-http://127.0.0.1:1080}"
MAX_ITEMS_PER_SOURCE="${MAX_ITEMS_PER_SOURCE:-30}"
AUDIO_FORMAT="${AUDIO_FORMAT:-mp3}"
AUDIO_QUALITY="${AUDIO_QUALITY:-0}"

YOUTUBE_SOURCES="${YOUTUBE_SOURCES:-$TOOLS_DIR/sources/youtube.txt}"
PODCAST_SOURCES="${PODCAST_SOURCES:-$TOOLS_DIR/sources/podcasts.txt}"

trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# 已知分级，仅用于校验拼写；源文件里写别的词也能用，只是会提示一句
KNOWN_LEVELS="kids middle ya adult unsorted"

load_sources() {
  # $1 = 文件路径
  # 输出：每行 level<TAB>name<TAB>url
  #   用 TAB 而不是 | 分隔，是因为 URL 里可能出现 |，但不会出现 TAB
  #   格式不合法的行输出 __bad__<TAB>原始行<TAB>，交给调用方计数和报警
  local file="$1" line level="unsorted" name url
  [[ -f "$file" ]] || { echo "缺少源文件: $file" >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    # 只把行首、或前面紧挨空白的 # 当注释起点，
    # 这样 URL 里的 #fragment 不会被误砍（贪婪匹配取最后一个）
    if [[ "$line" == "#"* ]]; then
      line=""
    elif [[ "$line" =~ ^(.*[[:space:]])#.*$ ]]; then
      line="${BASH_REMATCH[1]}"
    fi
    line="$(trim_ws "$line")"
    [[ -z "$line" ]] && continue

    # [kids] 这样的段落头，往下的条目都归到这一级
    if [[ "$line" =~ ^\[([A-Za-z0-9_-]+)\]$ ]]; then
      level="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
      if [[ " $KNOWN_LEVELS " != *" $level "* ]]; then
        echo "[提示] 源文件 $file 里有未知分级 [$level]，仍会照常处理" >&2
      fi
      continue
    fi

    if [[ "$line" != *"|"* ]]; then
      printf '__bad__\t%s\t\n' "$line"
      continue
    fi
    name="$(trim_ws "${line%%|*}")"
    url="$(trim_ws "${line#*|}")"
    if [[ -z "$name" || -z "$url" ]]; then
      printf '__bad__\t%s\t\n' "$line"
      continue
    fi
    printf '%s\t%s\t%s\n' "$level" "$name" "$url"
  done < "$file"
}

# 判断某个分级是否在 LEVEL_FILTER 里；LEVEL_FILTER 为空表示全要
level_wanted() {
  local want="$1" item
  [[ -z "${LEVEL_FILTER:-}" ]] && return 0
  local IFS=','
  for item in $LEVEL_FILTER; do
    item="$(trim_ws "$item")"
    [[ "$item" == "$want" ]] && return 0
  done
  return 1
}

setup_proxy() {
  proxy_args=()
  if [[ "${USE_PROXY}" == "1" ]]; then
    export http_proxy="$PROXY_ADDRESS"
    export https_proxy="$PROXY_ADDRESS"
    export ALL_PROXY="$PROXY_ADDRESS"
    proxy_args=(--proxy "$PROXY_ADDRESS")
    echo "[proxy] $PROXY_ADDRESS"
  else
    unset http_proxy https_proxy ALL_PROXY all_proxy || true
    echo "[proxy] off"
  fi
}

setup_cookies() {
  # 故意不加 local：靠动态作用域写调用方（download_list）里的 cookie_args
  cookie_args=()
  if [[ -n "${COOKIES_FILE:-}" && -f "$COOKIES_FILE" ]]; then
    cookie_args=(--cookies "$COOKIES_FILE")
    echo "[cookies] file $COOKIES_FILE"
  elif [[ -n "${COOKIES_FROM_BROWSER:-}" ]]; then
    cookie_args=(--cookies-from-browser "$COOKIES_FROM_BROWSER")
    echo "[cookies] browser $COOKIES_FROM_BROWSER"
  else
    echo "[cookies] none"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "缺少命令: $1" >&2; exit 1; }
}
