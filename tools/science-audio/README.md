# science-audio

批量抓取少儿科普内容的音频：YouTube 频道用 yt-dlp 抽音轨，播客直接吃 RSS。跑完按源分目录存放，带断点续传。

## 首次使用

```bash
cp config.env.example config.env   # 改成你自己的路径 / 代理 / cookie
./download-all.sh
```

`config.env` 已被 `.gitignore` 忽略，不会提交——里面的 cookie 路径等同登录凭据。

## 用法

```bash
./download-all.sh            # 两者都下（受 config 里 RUN_YOUTUBE / RUN_PODCAST 开关控制）
./download-all.sh youtube
./download-all.sh podcast
./download-all.sh both
```

命令行参数优先决定跑什么，`RUN_YOUTUBE=0` / `RUN_PODCAST=0` 可以再关掉其中一边。

## 文件结构

```
science-audio/
├── download-all.sh       # 主入口
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

```
$OUTPUT_ROOT/
└── <目录名>/
    ├── 20240115 - 标题 [视频ID].mp3
    └── downloaded.txt        # yt-dlp 的下载存档，重跑时用来跳过已下内容
```

## 说明

- **续传**：靠每个源目录下的 `downloaded.txt`，重跑只下新增内容，删掉它就会全量重下
- **时长过滤**：超过 `MAX_DURATION_SEC_YOUTUBE` / `MAX_DURATION_SEC_PODCAST` 的条目会跳过。注意被过滤掉的条目**不会**写进 `downloaded.txt`，所以每次跑都要重新解析一遍它们的元数据，源攒多了会变慢
- **每源数量上限**：`MAX_ITEMS_PER_SOURCE`，设成 0 表示不限
- **0 字节残文件**会在每个源下完后自动清掉（不动 `downloaded.txt`）
- **退出码**：有源下载失败、或源列表里有格式错误的行时返回 1，方便挂定时任务时发现异常
- **代理 scheme 要和代理类型对上**：SOCKS 代理（常见端口 1080）必须写 `socks5://`，写成 `http://` 连不上

## 重复源

`Wow in the World`、`Brains On`、`Tumble Science` 三个节目 YouTube 和 RSS 都有。默认走 RSS（更全、音质更好），`sources/youtube.txt` 里对应的三行已注释掉。要反过来的话，把那三行取消注释，同时删掉 `sources/podcasts.txt` 里对应的三行——两边都留着会把同样的音频下两遍。

## 依赖

`bash` 4+、`yt-dlp`、`ffmpeg`
