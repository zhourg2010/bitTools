#!/usr/bin/env bash
# myzsh.sh - WSL / Ubuntu 一键配置 Zsh 环境
# 装 Oh My Zsh、修中文乱码、设置提示符、把默认 shell 切成 zsh
# 可重复执行，不会叠加配置

set -euo pipefail

echo "🚀 开始一键配置 WSL Zsh 环境..."

if ! command -v apt-get >/dev/null 2>&1; then
    echo "❌ 只支持 Debian / Ubuntu 系（需要 apt）" >&2
    exit 1
fi

# 1. 更新系统并安装必要的依赖
echo "📦 [1/6] 安装依赖包 (zsh, git, curl, locales)..."
sudo apt-get update -y
sudo apt-get install -y zsh git curl locales lsb-release

# 2. 解决中文文件名乱码问题
echo "🌐 [2/6] 配置语言环境 (UTF-8 防乱码)..."
sudo locale-gen en_US.UTF-8 zh_CN.UTF-8
sudo update-locale LANG=en_US.UTF-8

# 3. 安装 Oh My Zsh (非交互模式)
echo "⚙️  [3/6] 安装 Oh My Zsh..."
if [[ -d "${HOME}/.oh-my-zsh" ]]; then
    echo "    已安装，跳过。"
else
    # --unattended: 不自动切换 shell，也不自动进入 zsh
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

# 4. 配置 .zshrc (环境变量、ls别名、自定义提示符)
echo "🎨 [4/6] 配置提示符与防乱码设置..."

ZSHRC="${HOME}/.zshrc"
BEGIN_MARKER='# >>> myzsh >>>'
END_MARKER='# <<< myzsh <<<'

touch "${ZSHRC}"

# 删掉上一次本脚本写入的整块，保证重复执行不叠加
sed -i "/^${BEGIN_MARKER}\$/,/^${END_MARKER}\$/d" "${ZSHRC}"

# 兼容旧版本：清掉早期版本零散追加的那几行
sed -i '/^export LANG=en_US.UTF-8$/d' "${ZSHRC}"
sed -i '/^export LC_ALL=en_US.UTF-8$/d' "${ZSHRC}"
sed -i "/^alias ls='ls -N --color=auto'\$/d" "${ZSHRC}"
sed -i '/^OS_INFO=/d' "${ZSHRC}"
sed -i '/^PROMPT=/d' "${ZSHRC}"

# 写入新的配置块（PROMPT 里的 $ 由 zsh 在加载时展开，这里必须用带引号的 heredoc）
cat >> "${ZSHRC}" <<'BLOCK_EOF'
# >>> myzsh >>>
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
alias ls='ls -N --color=auto'

# 获取系统版本信息变量
OS_INFO=$(lsb_release -ds 2>/dev/null || echo "Linux")

# 带颜色的提示符：青色 user@Ubuntu 22.04 LTS : 绿色路径 $
autoload -U colors && colors
PROMPT="%{$fg[cyan]%}%n@${OS_INFO}%{$reset_color%}:%{$fg[green]%}%~%{$reset_color%}\$ "
# <<< myzsh <<<
BLOCK_EOF

# 5. 切换默认 Shell 为 Zsh
echo "🔄 [5/6] 切换默认 Shell 为 Zsh..."
ZSH_PATH=$(command -v zsh)
CURRENT_USER=$(id -un)

# 确保 zsh 在合法 shell 列表中
if ! grep -qxF "${ZSH_PATH}" /etc/shells; then
    echo "${ZSH_PATH}" | sudo tee -a /etc/shells > /dev/null
fi

if [[ "${SHELL:-}" == "${ZSH_PATH}" ]]; then
    echo "    默认 Shell 已经是 zsh，跳过。"
elif sudo chsh -s "${ZSH_PATH}" "${CURRENT_USER}"; then
    echo "    已切换为 ${ZSH_PATH}"
else
    echo "    ⚠️  自动切换失败，请手动执行：chsh -s ${ZSH_PATH}"
fi

# 6. 完成
echo "✅ [6/6] 配置全部完成！"
echo "======================================"
echo "🎉 恭喜！配置已全部就绪。"
echo "⚠️  请关闭当前终端窗口，重新打开一个新窗口，即可看到完美的效果。"
echo "======================================"
