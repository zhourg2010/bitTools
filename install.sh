#!/usr/bin/env bash
# install.sh — bitTools 一键部署（Ubuntu / Debian）
#
#   curl -fsSL https://raw.githubusercontent.com/zhourg2010/bitTools/main/install.sh | bash
# 或在已 clone 的目录里:
#   ./install.sh
#
# 装到 ~/.bitTools，命令软链到 ~/.local/bin，以 bt- 开头。
set -euo pipefail

REPO_URL="${BITTOOLS_REPO:-https://github.com/zhourg2010/bitTools.git}"
PREFIX="${BITTOOLS_HOME:-$HOME/.bitTools}"
BIN_DIR="${BITTOOLS_BIN:-$HOME/.local/bin}"
WITH_DEPS=1
WITH_PATH=1
WITH_WHISPER=0
ACTION="install"
PURGE=0

BEGIN_MARKER='# >>> bitTools >>>'
END_MARKER='# <<< bitTools <<<'

usage() {
  cat <<'USAGE'
用法: install.sh [选项]

  --prefix DIR      安装目录，默认 ~/.bitTools
  --bin-dir DIR     命令目录，默认 ~/.local/bin
  --no-deps         跳过依赖安装（apt / venv）
  --no-path         不改 ~/.bashrc / ~/.zshrc 的 PATH
  --with-whisper    顺带装 faster-whisper（体积大，转写才需要）
  --uninstall       卸载：删掉命令和 PATH 配置
  --purge           配合 --uninstall，连安装目录一起删
  -h, --help

环境变量 BITTOOLS_HOME / BITTOOLS_BIN / BITTOOLS_REPO 同上。
重复执行 = 更新，不会重复叠加任何配置。
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) [[ $# -ge 2 ]] || { echo "--prefix 后要跟目录" >&2; exit 1; }; PREFIX="$2"; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    --bin-dir) [[ $# -ge 2 ]] || { echo "--bin-dir 后要跟目录" >&2; exit 1; }; BIN_DIR="$2"; shift 2 ;;
    --bin-dir=*) BIN_DIR="${1#*=}"; shift ;;
    --no-deps) WITH_DEPS=0; shift ;;
    --no-path) WITH_PATH=0; shift ;;
    --with-whisper) WITH_WHISPER=1; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; echo >&2; usage >&2; exit 1 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

# 一次装好的命令清单： 命令名:相对路径
COMMANDS=(
  "bt-audio:tools/science-audio/download-all.sh"
  "bt-transcribe:tools/science-audio/transcribe.sh"
  "bt-reorganize:tools/science-audio/reorganize.sh"
  "bt-verify-sources:tools/science-audio/verify-sources.sh"
  "bt-papers:tools/getpapers/getpapers.sh"
  "bt-myip:tools/myip/myip.sh"
  "bt-zsh:tools/myzsh/myzsh.sh"
)

# ------------------------------------------------------------------ 卸载

remove_path_block() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  grep -qF "$BEGIN_MARKER" "$rc" || return 0
  sed -i "/^${BEGIN_MARKER}\$/,/^${END_MARKER}\$/d" "$rc"
  say "已从 $rc 移除 PATH 配置"
}

if [[ "$ACTION" == "uninstall" ]]; then
  for entry in "${COMMANDS[@]}"; do
    rm -f "$BIN_DIR/${entry%%:*}"
  done
  rm -f "$BIN_DIR/bittools"
  say "已删除 $BIN_DIR 下的 bt-* 命令"
  remove_path_block "$HOME/.bashrc"
  remove_path_block "$HOME/.zshrc"
  if [[ "$PURGE" == "1" ]]; then
    rm -rf "$PREFIX"
    say "已删除安装目录 $PREFIX"
  else
    say "安装目录保留在 $PREFIX（要一起删加 --purge）"
  fi
  echo "卸载完成。"
  exit 0
fi

# ------------------------------------------------------------------ 取代码

# 从 curl | bash 跑的时候 $0 不是真实路径，取不到就当没有本地 checkout
SELF_DIR=""
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

command -v git >/dev/null 2>&1 || die "需要 git，先 sudo apt install git"

if [[ -d "$PREFIX/.git" ]]; then
  say "已存在安装，更新中: $PREFIX"
  if ! git -C "$PREFIX" pull --ff-only 2>&1 | sed 's/^/    /'; then
    warn "git pull 失败（本地有改动？），保持现状继续安装命令"
  fi
elif [[ -n "$SELF_DIR" && -d "$SELF_DIR/.git" && -d "$SELF_DIR/tools" ]]; then
  # 在 clone 出来的目录里跑：直接从本地复制，不需要联网
  say "从本地 checkout 安装到 $PREFIX"
  git clone --quiet "$SELF_DIR" "$PREFIX"
  git -C "$PREFIX" remote set-url origin "$REPO_URL"
else
  say "克隆 $REPO_URL → $PREFIX"
  git clone --quiet "$REPO_URL" "$PREFIX" || die "克隆失败，检查网络或 BITTOOLS_REPO"
fi

chmod +x "$PREFIX"/tools/*/*.sh 2>/dev/null || true

# ------------------------------------------------------------------ 依赖

VENV="$PREFIX/.venv"

install_deps() {
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "不是 Debian/Ubuntu，跳过系统包安装；请自行准备 curl ffmpeg file python3"
  else
    local SUDO=""
    if [[ "$(id -u)" != "0" ]]; then
      command -v sudo >/dev/null 2>&1 && SUDO="sudo" \
        || { warn "既不是 root 又没有 sudo，跳过系统包安装"; return 0; }
    fi
    # 依赖装不上不该阻断安装本身：命令照装，缺什么各个脚本运行时会自己报
    say "安装系统包（需要 sudo）"
    $SUDO apt-get update -y -qq \
      || warn "apt-get update 失败，继续尝试安装"
    $SUDO apt-get install -y -qq curl git ca-certificates ffmpeg file gzip tar \
                                 python3 python3-venv python3-pip \
      || warn "部分系统包没装上，稍后可手动: sudo apt install ffmpeg file python3-venv"
  fi

  # yt-dlp 用 venv 装：apt 源里的版本往往过旧，YouTube 一改就失效。
  # 同一个 venv 顺带装 maxminddb（myip 查归属地要用），
  # 这样命令包装脚本把 venv/bin 放进 PATH 就全齐了。
  say "准备 Python 环境: $VENV"
  if [[ ! -x "$VENV/bin/python3" ]]; then
    if ! python3 -m venv "$VENV"; then
      warn "创建 venv 失败（装一下 python3-venv），跳过 Python 依赖"
      return 0
    fi
  fi
  "$VENV/bin/python3" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
  say "安装 yt-dlp + maxminddb"
  "$VENV/bin/python3" -m pip install --quiet --upgrade yt-dlp maxminddb \
    || warn "pip 安装失败，稍后可手动: $VENV/bin/python3 -m pip install -U yt-dlp maxminddb"

  if [[ "$WITH_WHISPER" == "1" ]]; then
    say "安装 faster-whisper（较大，请稍候）"
    "$VENV/bin/python3" -m pip install --quiet --upgrade faster-whisper \
      || warn "faster-whisper 安装失败，转写功能暂不可用"
  fi
}

if [[ "$WITH_DEPS" == "1" ]]; then
  install_deps
else
  say "跳过依赖安装（--no-deps）"
fi

# ------------------------------------------------------------------ 命令

mkdir -p "$BIN_DIR"

write_wrapper() {
  local name="$1" target="$2"
  cat > "$BIN_DIR/$name" <<WRAPPER
#!/usr/bin/env bash
# 由 bitTools install.sh 生成，改了会在下次安装时被覆盖
BITTOOLS_HOME="$PREFIX"
# venv 优先：yt-dlp 和 maxminddb 都在里面
[[ -d "\$BITTOOLS_HOME/.venv/bin" ]] && PATH="\$BITTOOLS_HOME/.venv/bin:\$PATH"
export PATH
exec "\$BITTOOLS_HOME/$target" "\$@"
WRAPPER
  chmod +x "$BIN_DIR/$name"
}

say "安装命令到 $BIN_DIR"
for entry in "${COMMANDS[@]}"; do
  name="${entry%%:*}"
  target="${entry#*:}"
  if [[ -f "$PREFIX/$target" ]]; then
    write_wrapper "$name" "$target"
    printf '    %-20s → %s\n' "$name" "$target"
  else
    warn "找不到 $target，跳过 $name"
  fi
done

cat > "$BIN_DIR/bittools" <<DISPATCH
#!/usr/bin/env bash
# 由 bitTools install.sh 生成
BITTOOLS_HOME="$PREFIX"
case "\${1:-}" in
  update)
    git -C "\$BITTOOLS_HOME" pull --ff-only
    exec "\$BITTOOLS_HOME/install.sh" --prefix "\$BITTOOLS_HOME" --bin-dir "$BIN_DIR" --no-deps
    ;;
  path) echo "\$BITTOOLS_HOME" ;;
  ""|list|-h|--help)
    echo "bitTools — 安装于 \$BITTOOLS_HOME"
    echo ""
    echo "可用命令:"
    echo "  bt-audio            下载科普音频（--level kids|middle|ya|adult）"
    echo "  bt-transcribe       给音频生成 SRT/VTT 字幕"
    echo "  bt-reorganize       按分级整理目录（默认 dry-run）"
    echo "  bt-verify-sources   检查源链接是否有效"
    echo "  bt-papers           从 ERIC 批量下载论文 PDF"
    echo "  bt-myip             查外网 IP 与归属地"
    echo "  bt-zsh              配置 Zsh 环境"
    echo ""
    echo "  bittools update     拉取最新代码并重装命令"
    echo "  bittools path       打印安装目录"
    ;;
  *) echo "未知子命令: \$1" >&2; exit 1 ;;
esac
DISPATCH
chmod +x "$BIN_DIR/bittools"

# ------------------------------------------------------------------ 配置

SA_CONF="$PREFIX/tools/science-audio/config.env"
if [[ ! -f "$SA_CONF" && -f "$SA_CONF.example" ]]; then
  cp "$SA_CONF.example" "$SA_CONF"
  # 把转写用的解释器指向 venv，里面才有 whisper
  sed -i "s|^PYTHON=.*|PYTHON=\"$VENV/bin/python3\"|" "$SA_CONF"
  say "已生成 $SA_CONF（按需改代理、cookie、输出目录）"
else
  say "保留已有的 $SA_CONF"
fi

# ------------------------------------------------------------------ PATH

add_path_block() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  # 先删旧块再写，重复执行不叠加
  sed -i "/^${BEGIN_MARKER}\$/,/^${END_MARKER}\$/d" "$rc"
  {
    printf '%s\n' "$BEGIN_MARKER"
    printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
    printf '%s\n' "$END_MARKER"
  } >> "$rc"
  say "已把 $BIN_DIR 写进 $rc"
}

case ":$PATH:" in
  *":$BIN_DIR:"*) IN_PATH=1 ;;
  *) IN_PATH=0 ;;
esac

if [[ "$WITH_PATH" == "1" && "$IN_PATH" == "0" ]]; then
  add_path_block "$HOME/.bashrc"
  add_path_block "$HOME/.zshrc"
  NEED_RELOAD=1
else
  NEED_RELOAD=0
fi

# ------------------------------------------------------------------ 收尾

echo ""
echo "======================================"
echo "安装完成"
echo "  代码:   $PREFIX"
echo "  命令:   $BIN_DIR/bt-*"
[[ -x "$VENV/bin/yt-dlp" ]] && echo "  yt-dlp: $("$VENV/bin/yt-dlp" --version 2>/dev/null || echo '已装')"
echo "======================================"
if [[ "$NEED_RELOAD" == "1" ]]; then
  echo ""
  echo "$BIN_DIR 还不在当前 PATH 里，执行下面任一条:"
  echo "  source ~/.bashrc      # 或重开终端"
fi
echo ""
echo "先试试:  bittools        # 看命令列表"
echo "        bt-myip         # 查外网 IP"
