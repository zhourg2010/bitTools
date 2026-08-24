# getpapers

从 [ERIC](https://eric.ed.gov/)（美国教育资源信息中心）批量检索并下载英语教育方向的论文全文 PDF。

## 用法

```bash
./getpapers.sh [最大页数] [每页条数] [输出目录]
```

默认值：`5` 页、每页 `40` 条、输出到 `./eric_english_education_papers`。

示例：

```bash
./getpapers.sh 10 40 ~/papers/20260824
```

## 检索范围

只取同行评审（`peerreviewed=true`）的记录，关键词固定为：

```
"English language teaching" OR TESOL OR EFL OR ESL OR "English education" OR "language pedagogy"
```

要改检索词，编辑脚本里的 `QUERY` 变量。

## 输出

```
<输出目录>/
├── pdfs/          # 下载到的 PDF，命名为 作者_年份_标题.pdf
├── metadata.jsonl # 每条检索结果的完整元数据，一行一条 JSON
└── download.log   # 完整运行日志
```

## 说明

- 只有 ERIC 提供全文的记录才会下载，无全文的会在日志里记为 `无全文（404）`
- 已存在的同名文件会跳过，可以中断后重跑续传
- 下载到的内容会用 `file` 校验是否真的是 PDF，不是就删掉
- 每次请求之间 sleep 1.5 秒，避免给 ERIC 造成压力

## 依赖

`bash`、`curl`、`python3`、`file`
