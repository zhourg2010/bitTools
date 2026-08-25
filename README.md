# bitTools

个人工具集合仓库，存放平时自用的各类小工具和脚本。全部是 Bash，各自独立。

## 安装

Ubuntu / Debian 上一键装好：

```bash
curl -fsSL https://raw.githubusercontent.com/zhourg2010/bitTools/main/install.sh | bash
```

或者 clone 下来再装（不需要联网拉代码）：

```bash
git clone https://github.com/zhourg2010/bitTools.git
cd bitTools && ./install.sh
```

装完 `source ~/.bashrc`（或重开终端）就能用了。

装了些什么：

| 位置 | 内容 |
| --- | --- |
| `~/.bitTools` | 代码本体（一个 git clone，方便 `bittools update`） |
| `~/.bitTools/.venv` | 独立的 Python 环境，装 `yt-dlp` 和 `maxminddb` |
| `~/.local/bin/bt-*` | 各个命令的包装脚本 |
| `~/.bashrc` / `~/.zshrc` | 一个带标记的块，把 `~/.local/bin` 加进 PATH |

系统包走 apt：`curl git ffmpeg file gzip tar python3 python3-venv`。

`yt-dlp` 不用 apt 装——源里的版本往往过旧，YouTube 一改就失效。它和 `maxminddb` 一起装进 `~/.bitTools/.venv`，命令包装脚本会把这个 venv 放进 PATH，所以不污染系统 Python，也不受 PEP 668 限制。

**依赖装失败不会中断安装**，命令照样装好，缺什么各个脚本运行时会自己提示。

### 安装选项

```bash
./install.sh --prefix ~/tools/bitTools   # 换安装目录，默认 ~/.bitTools
./install.sh --bin-dir ~/bin             # 换命令目录，默认 ~/.local/bin
./install.sh --no-deps                   # 只装命令，不碰 apt 和 venv
./install.sh --no-path                   # 不改 shell 配置
./install.sh --with-whisper              # 顺带装 faster-whisper（体积大，转写才需要）
```

重复执行 = 更新，PATH 配置和命令都不会叠加，已有的 `config.env` 不会被覆盖。

### 更新与卸载

```bash
bittools update              # 拉最新代码并重装命令
./install.sh --uninstall     # 删命令和 PATH 配置，保留 ~/.bitTools
./install.sh --uninstall --purge   # 连安装目录一起删
```

## 使用方法

装完后所有命令以 `bt-` 开头，随时随地可调用：

```bash
bittools                     # 看命令列表和安装位置
```

| 命令 | 作用 |
| --- | --- |
| `bt-audio` | 下载科普音频（YouTube + 播客） |
| `bt-transcribe` | 给音频生成 SRT/VTT 字幕 |
| `bt-reorganize` | 按分级整理目录（默认 dry-run） |
| `bt-verify-sources` | 检查源链接是否还有效 |
| `bt-papers` | 从 ERIC 批量下载论文 PDF |
| `bt-myip` | 查外网 IP 与归属地 |
| `bt-zsh` | 配置 Zsh 环境 |

### 科普音频：下载 → 整理 → 转写

抓少儿科普 YouTube 频道和播客 RSS 的音频，按年龄分级（`kids` 5-8 / `middle` 9-13 / `ya` 14-18 / `adult`），带断点续传。

```bash
# 配置：代理、cookie、输出目录
vim ~/.bitTools/tools/science-audio/config.env

bt-verify-sources               # 先查哪些源还活着
bt-audio --level kids           # 只下 5-8 岁那档
bt-audio youtube --level ya,adult
bt-transcribe                   # 给下到的音频生成字幕
bt-reorganize                   # 看整理计划（不动文件）
bt-reorganize --apply           # 确认后执行
```

默认 30 条/源 × 28 个源 ≈ 800 条，第一次建议先 `--level kids` 试水。
详见 [tools/science-audio/](tools/science-audio/)。

### ERIC 论文下载

从 ERIC 检索英语教育方向的同行评审论文，下全文 PDF，同时留一份完整元数据。

```bash
bt-papers 10 40 ~/papers/20260824          # 10 页 × 每页 40 条
ERIC_QUERY='peerreviewed:T AND (TBLT)' bt-papers   # 换检索词
```

详见 [tools/getpapers/](tools/getpapers/)。

### 外网 IP 与归属地

```bash
bt-myip                # 查 IP + 归属地，顺带后台更新 GeoIP 库
bt-myip --no-update    # 本次不检查更新
```

数据库更新在后台跑，不挡着先出结果。详见 [tools/myip/](tools/myip/)。

### Zsh 环境配置

装 Oh My Zsh、修中文文件名乱码、设置提示符、切默认 shell。可重复执行，不会叠加配置。

```bash
bt-zsh                 # 跑完关掉终端重开才生效
```

详见 [tools/myzsh/](tools/myzsh/)。

## 不装也能用

每个脚本都可以直接跑，不依赖安装：

```bash
cd tools/myip && ./myip.sh
```

只是要自己保证 `yt-dlp`、`maxminddb` 之类的依赖在 PATH 里。

## 结构

```
install.sh            # 一键部署
tools/
├── science-audio/    # 下载 / 转写 / 整理 / 校验，共 5 个脚本
├── getpapers/
├── myip/
└── myzsh/
```

每个工具一个目录，自带 `README.md` 说明用法、输出、依赖和注意事项。上面只是索引，细节看各自的文档。

## 约定

- 一个工具一个目录，放在 `tools/<name>/` 下，自带 `README.md`
- 依赖各自独立，工具之间不互相耦合（`science-audio` 内部的 `lib.sh` 只在该目录内共享）
- **密钥、token、cookie 路径一律不进仓库**：走环境变量，或者提交 `config.env.example` 模板、把真实配置加进 `.gitignore`
- 破坏性操作（移动、删除文件）默认 dry-run，要加 `--apply` 才真执行
- 脚本默认 `set -euo pipefail`（`myip.sh` 因为要自己接管各步返回值，只用 `set -uo pipefail`）
- 批量任务统计失败数，有失败时退出码非 0，方便挂定时任务
- 写 shell 配置文件用带标记的块（`# >>> xxx >>>`），重复执行只替换该块，不动用户自己的配置
