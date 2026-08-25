# bitTools

个人工具集合仓库，存放平时自用的各类小工具和脚本。全部是 Bash，各自独立，clone 下来就能用。

## 工具

### [science-audio](tools/science-audio/) — 科普音频下载与转写

抓少儿科普 YouTube 频道和播客 RSS 的音频，按年龄分级（kids / middle / ya / adult），可只下某一级；带断点续传，能生成 SRT/VTT 字幕。

```bash
cp config.env.example config.env
./verify-sources.sh              # 先查哪些源还活着
./download-all.sh --level kids   # 只下 5-8 岁那档
./transcribe.sh                  # 生成字幕
```

`download-all.sh` 下载 · `transcribe.sh` 转写 · `reorganize.sh` 整理目录 · `verify-sources.sh` 检查源

### [getpapers](tools/getpapers/) — ERIC 论文批量下载

从 ERIC 检索英语教育方向的同行评审论文，下全文 PDF，同时留一份完整元数据。

```bash
./getpapers.sh 10 40 ~/papers/20260824
ERIC_QUERY='peerreviewed:T AND (TBLT)' ./getpapers.sh    # 换检索词
```

### [myip](tools/myip/) — 外网 IP 与归属地

查外网 IP，用本地 GeoIP 库给出归属地。数据库每次运行检查更新，但更新在后台跑，不挡着先出结果。

```bash
./myip.sh
```

### [myzsh](tools/myzsh/) — WSL/Ubuntu Zsh 一键配置

装 Oh My Zsh、修中文文件名乱码、设置提示符、切默认 shell。可重复执行，不会叠加配置。

```bash
./myzsh.sh
```

## 结构

```
tools/
├── science-audio/
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
