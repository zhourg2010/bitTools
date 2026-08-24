# myzsh

WSL / Ubuntu 上一键配置 Zsh 环境：装 Oh My Zsh、修中文乱码、设置提示符、把默认 shell 切成 zsh。

## 用法

```bash
./myzsh.sh
```

过程中需要 sudo 密码。跑完**关掉终端重开**才生效。

## 做了什么

1. `apt install zsh git curl locales lsb-release`
2. 生成 `en_US.UTF-8` / `zh_CN.UTF-8` locale，解决中文文件名乱码
3. 非交互模式安装 Oh My Zsh（已装过则跳过）
4. 往 `~/.zshrc` 写入 `LANG` / `LC_ALL`、`ls -N --color=auto` 别名和自定义提示符
5. 把 zsh 加进 `/etc/shells` 并设为默认 shell

## 说明

- 写进 `~/.zshrc` 的内容包在 `# >>> myzsh >>>` / `# <<< myzsh <<<` 标记块里，重复执行只会替换这一块，不动你自己加的任何配置
- 早期版本零散追加的那几行也会被顺带清掉，从旧版升上来不会残留
- 提示符格式：`青色 用户名@系统版本 : 绿色当前路径 $`
- 切换默认 shell 走 `sudo chsh`，免去再输一次登录密码；失败会提示手动命令，不中断脚本
- 只在 Debian 系（apt）上能跑，非 apt 环境会直接报错退出
