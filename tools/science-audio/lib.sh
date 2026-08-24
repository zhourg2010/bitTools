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

load_sources() {
  # $1 = 文件路径 → 打印 name|url（跳过空行和注释）
  local file="$1" line
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
    [[ "$line" == *"|"* ]] || continue
    printf '%s\n' "$line"
  done < "$file"
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
