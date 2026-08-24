#!/bin/bash

echo "🚀 开始一键配置 WSL Zsh 环境..."

# 1. 更新系统并安装必要的依赖
echo "📦 [1/6] 安装依赖包 (zsh, git, curl, locales)..."
sudo apt update -y
sudo apt install -y zsh git curl locales lsb-release

# 2. 解决中文文件名乱码问题
echo "🌐 [2/6] 配置语言环境 (UTF-8 防乱码)..."
sudo locale-gen en_US.UTF-8 zh_CN.UTF-8
sudo update-locale LANG=en_US.UTF-8

# 3. 安装 Oh My Zsh (非交互模式)
echo "⚙️ [3/6] 安装 Oh My Zsh..."
# --unattended: 不自动切换 shell，也不自动进入 zsh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# 4. 配置 .zshrc (环境变量、ls别名、自定义提示符)
echo "🎨 [4/6] 配置提示符与防乱码设置..."

ZSHRC_FILE=~/.zshrc

# 清理可能存在的旧配置，防止重复执行时叠加
sed -i '/export LANG=/d' $ZSHRC_FILE
sed -i '/export LC_ALL=/d' $ZSHRC_FILE
sed -i "/alias ls='ls -N --color=auto'/d" $ZSHRC_FILE
sed -i '/^OS_INFO=/d' $ZSHRC_FILE
sed -i '/^PROMPT=/d' $ZSHRC_FILE

# 写入新的配置
echo 'export LANG=en_US.UTF-8' >> $ZSHRC_FILE
echo 'export LC_ALL=en_US.UTF-8' >> $ZSHRC_FILE
echo "alias ls='ls -N --color=auto'" >> $ZSHRC_FILE

# 获取系统版本信息变量
echo 'OS_INFO=$(lsb_release -ds 2>/dev/null || echo "Linux")' >> $ZSHRC_FILE

# 设置带颜色的提示符：青色 user@Ubuntu 22.04 LTS : 绿色路径 : $ echo 'PROMPT="%{$fg[cyan]%}%n@${OS_INFO}%{$reset_color%}:%{$fg[green]%}%~%{$reset_color%}\$ "' >> $ZSHRC_FILE

# 5. 切换默认 Shell 为 Zsh
echo "🔄 [5/6] 切换默认 Shell 为 Zsh..."
# 确保 zsh 在合法 shell 列表中
if ! grep -q "$(which zsh)" /etc/shells; then
    echo "$(which zsh)" | sudo tee -a /etc/shells > /dev/null
fi
chsh -s $(which zsh)

# 6. 完成
echo "✅ [6/6] 配置全部完成！"
echo "======================================"
echo "🎉 恭喜！配置已全部就绪。"
echo "⚠️  请关闭当前终端窗口，重新打开一个新窗口，即可看到完美的效果。"
echo "======================================"
