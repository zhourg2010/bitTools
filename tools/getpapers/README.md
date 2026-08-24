# getpapers

从 [ERIC](https://eric.ed.gov/)（美国教育资源信息中心）批量检索并下载英语教育方向的论文全文 PDF。

## 用法

```bash
./getpapers.sh [最大页数] [每页条数] [输出目录]
```

默认值：`5` 页、每页 `40` 条、输出到 `./eric_english_education_papers`。

```bash
./getpapers.sh 10 40 ~/papers/20260824
```

换检索词不用改脚本，用环境变量覆盖：

```bash
ERIC_QUERY='peerreviewed:T AND ("task-based learning" OR TBLT)' ./getpapers.sh 5 40 ~/papers/tblt
```

## 检索范围

默认只取同行评审的记录：

```
peerreviewed:T AND ("English language teaching" OR TESOL OR EFL OR ESL
                    OR "English education" OR "language pedagogy")
```

注意 `peerreviewed` 是 ERIC 的**检索字段**，必须写在 `search` 里；作为独立 URL 参数传是无效的（会被静默忽略，结果里混进非同行评审的记录）。

## 输出

```
<输出目录>/
├── pdfs/          # 下载到的 PDF，命名为 作者_年份_标题.pdf
├── metadata.jsonl # 每条检索结果的完整元数据，一行一条 JSON
└── download.log   # 完整运行日志
```

`metadata.jsonl` 记录所有检索到的条目，包括没有全文的，方便事后回溯。

## 说明

- 只有 ERIC 提供全文的记录才下得到，无全文的在日志里记为 `无全文（404）`
- 已存在的同名文件直接跳过且**不发网络请求**，可以中断后重跑续传
- 下载到的内容用 `file -b --mime-type` 校验必须是 `application/pdf`，否则删除（有些条目会返回 HTML 拦截页）
- 每次请求之间 sleep 1.5 秒，避免给 ERIC 造成压力
- 取满 `numFound` 条后自动停止，不会空跑剩余页数

## 依赖

`bash`、`curl`、`python3`、`file`
