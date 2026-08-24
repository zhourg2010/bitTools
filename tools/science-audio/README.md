# science-audio

批量抓取科普内容的音频：YouTube 频道用 yt-dlp 抽音轨，播客直接吃 RSS。源按年龄分级，可以只下某一级；跑完按源分目录存放，带断点续传。

## 首次使用

```bash
cp config.env.example config.env   # 改成你自己的路径 / 代理 / cookie
./verify-sources.sh                # 先查一遍哪些源还活着
./download-all.sh
```

`config.env` 已被 `.gitignore` 忽略，不会提交——里面的 cookie 路径等同登录凭据。

## 用法

```bash
./download-all.sh                          # 全下
./download-all.sh youtube                  # 只下 YouTube
./download-all.sh podcast                  # 只下播客
./download-all.sh youtube --level kids     # 只下 YouTube 里的 kids
./download-all.sh --level ya,adult         # 两类里的 ya + adult
```

命令行参数优先决定跑什么，`config.env` 里的 `RUN_YOUTUBE=0` / `RUN_PODCAST=0` 可以再关掉其中一边。

## 分级

| 分级 | 大致年龄 | 说明 |
| --- | --- | --- |
| `kids` | 5-8 | 学龄前到小学低年级 |
| `middle` | 9-13 | 小学高年级到初中 |
| `ya` | 14-18 | 青少年 / 高中 |
| `adult` | — | 成人通识，给家长自己听的 |

源文件里用 `[分级]` 段落头划分，往下的条目都归到这一级，直到下一个段落头：

```
[kids]
SciShow_Kids|https://www.youtube.com/@SciShowKids/videos

[ya]
Veritasium|https://www.youtube.com/@veritasium/videos
```

段落头之前的条目算 `unsorted`。写了表格以外的词也能用，只会提示一句。

## 检查源是否还有效

```bash
./verify-sources.sh                     # 两份列表都查
./verify-sources.sh youtube --level ya  # 只查一部分
```

对每个源只解析第一条内容（`--simulate`，不下载），比真跑一遍快得多。有失效的会在最后列出来，退出码为 1。

**加了新源、或者很久没跑，建议先跑这个。** YouTube 频道改 handle、播客换托管商都会让链接失效，而 `download-all.sh` 因为有 `--ignore-errors`，失效的源只会刷一行 warn。

## 文件结构

```
science-audio/
├── download-all.sh       # 主入口
├── verify-sources.sh     # 检查源链接是否有效
├── lib.sh                # 配置加载、源列表解析、代理 / cookie 参数
├── config.env.example    # 配置模板（复制成 config.env 使用）
└── sources/
    ├── youtube.txt       # 目录名|频道URL
    └── podcasts.txt      # 目录名|RSS地址
```

## 源列表格式

一行一个源，`目录名|链接`：

```
SciShow_Kids|https://www.youtube.com/@SciShowKids/videos
```

- `#` 开头的整行，以及空白后面的 `#` 到行尾，都算注释
- URL 里的 `#fragment` 不会被当注释砍掉
- 目录名不能含 `/`；缺 `|` 分隔符的行会被跳过并报警告

## 输出

默认扁平存放：

```
$OUTPUT_ROOT/
└── <源名>/
    ├── 20240115 - 标题 [视频ID].mp3
    └── downloaded.txt        # yt-dlp 的下载存档，重跑时用来跳过已下内容
```

### 按分级分目录

`config.env` 里设 `GROUP_BY_LEVEL=1`，变成 `$OUTPUT_ROOT/<分级>/<源名>/`。

**已经下过一轮再改这个开关，旧的 `downloaded.txt` 就对不上了，会把所有内容重下一遍。** 先把已有目录挪过去：

```bash
cd "$OUTPUT_ROOT"
# 按 sources/*.txt 里的分级手动归位，例如：
mkdir -p kids middle ya adult
mv SciShow_Kids Crash_Course_Kids NatGeo_Kids FreeSchool TheDadLab Steve_Spangler kids/
mv TED_Ed NASA_STEM middle/
```

## 说明

- **续传**：靠每个源目录下的 `downloaded.txt`，重跑只下新增内容，删掉它就会全量重下
- **时长过滤**：超过 `MAX_DURATION_SEC_YOUTUBE` / `MAX_DURATION_SEC_PODCAST` 的条目会跳过。注意被过滤掉的条目**不会**写进 `downloaded.txt`，所以每次跑都要重新解析一遍它们的元数据，源攒多了会变慢
- **每源数量上限**：`MAX_ITEMS_PER_SOURCE`，设成 0 表示不限。默认 30 × 28 个源 ≈ 800 条，第一次全量跑会很久，建议先 `--level kids` 试水
- **0 字节残文件**会在每个源下完后自动清掉（不动 `downloaded.txt`）
- **退出码**：有源下载失败、或源列表里有格式错误的行时返回 1，方便挂定时任务时发现异常
- **代理 scheme 要和代理类型对上**：HTTP 代理写 `http://`，SOCKS 代理写 `socks5://`
- **纯音频不适合强视觉内容**：数学动画、实验演示类（Numberphile、3Blue1Brown 之类）抽成音频基本听不懂，`sources/youtube.txt` 里这两个默认注释掉了

## 重复源

`Wow in the World`、`Brains On`、`Tumble Science` 三个节目 YouTube 和 RSS 都有。默认走 RSS（更全、音质更好），`sources/youtube.txt` 里对应的行已注释掉。要反过来的话，把那几行取消注释，同时删掉 `sources/podcasts.txt` 里对应的三行——两边都留着会把同样的音频下两遍。

## 依赖

`bash` 4+、`yt-dlp`、`ffmpeg`
