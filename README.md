# bitTools

个人工具集合仓库，存放平时自用的各类小工具和脚本。

## 工具列表

| 工具 | 说明 |
| --- | --- |
| [getpapers](tools/getpapers/) | 从 ERIC 批量检索并下载英语教育方向论文的全文 PDF |
| [myzsh](tools/myzsh/) | WSL / Ubuntu 一键配置 Zsh 环境（Oh My Zsh、中文乱码、提示符） |

## 约定

- 每个工具放在 `tools/<name>/` 下，自带一份 `README.md` 说明用途和用法
- 依赖尽量各自独立，不要互相耦合
- 涉及密钥、token 的配置走环境变量或本地未提交的配置文件，不要写进仓库
