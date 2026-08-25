# myip

查外网 IP，并用本地 GeoIP 数据库给出归属地。数据库每次运行检查更新，**更新在后台跑，不挡着先出结果**。

## 用法

```bash
./myip.sh                # 查 IP + 归属地，顺带检查数据库更新
./myip.sh --no-update    # 本次不检查更新
./myip.sh --update-only  # 只更新数据库，不查 IP
```

输出：

```
正在查询外网 IP...
外网 IP: 1.2.3.4  (IPv4)
来源:    https://ifconfig.me

归属地: 美国 / 加利福尼亚州 / 山景城 [US]
坐标:   37.386, -122.0838
时区:   America/Los_Angeles

--- 数据库更新 ---
数据库已是最新（2026-08）
```

## 执行顺序

1. 依次试各个公共服务，拿到 IP 立刻打印
2. **后台**起数据库更新
3. 用**现有**数据库立刻查归属地（不等更新下完）
4. 最后才汇报更新结果

所以数据库正在下 200MB 也不影响你第一时间看到 IP 和归属地——用的是上一版数据库，归属地信息不会因此错到哪去。

只有一种情况会等：本地**完全没有**数据库（首次运行），这时没得可查，会等下载完成。

## 数据库

默认用 [DB-IP City Lite](https://db-ip.com/db/download/ip-to-city-lite)：免注册、免 key、按月更新。文件名里带 `YYYY-MM`，所以"检查更新"就是比月份——月初新库还没发布时自动退回上个月。

也支持 MaxMind GeoLite2（2019 年起强制要 license key）：

```bash
export MYIP_DB_PROVIDER=maxmind
export MAXMIND_LICENSE_KEY=你的key      # maxmind.com 免费申请
```

MaxMind 这边先拉 `.sha256`（几十字节）比对，校验和没变就不下整包。

## 读取器

`.mmdb` 需要一个读取器，二选一：

```bash
pip install maxminddb        # 推荐，能给出城市、坐标、时区
apt install mmdb-bin         # 提供 mmdblookup，只给国家和城市
```

两个都没有时，IP 照常能查，只是归属地那部分会提示你装一个。

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `MYIP_DB_DIR` | `~/.cache/myip` | 数据库存放目录 |
| `MYIP_DB_PROVIDER` | `dbip` | `dbip` 或 `maxmind` |
| `MAXMIND_LICENSE_KEY` | — | 用 maxmind 时必填 |
| `MYIP_UPDATE` | `1` | 设 `0` 则从不自动更新 |
| `MYIP_TIMEOUT` | `5` | 单次 IP 查询超时秒数 |

## 说明

- **IPv4 校验是逐段判断的**，不是只看形状。`999.999.999.999`、`256.1.1.1`、`01.2.3.4` 都会被拒绝，继续试下一个服务
- **支持 IPv6**：机器走 v6 出网时，那些服务返回的是 IPv6 地址，同样能查
- 有服务返回 HTML 错误页（限流时常见），会被校验挡掉并自动换下一家
- 所有服务都失败时退出码为 1
- 更新失败不影响查询，旧数据库原样保留

## PowerShell 版

`Get-PublicIP.ps1` 是同一套东西的 PowerShell 实现，给 Windows 用。放进 `$PROFILE`：

```powershell
. "$HOME\.bitTools\tools\myip\Get-PublicIP.ps1"
```

```powershell
Get-PublicIP                 # 或用别名 myip
(Get-PublicIP).IP            # 只取 IP
Get-PublicIP | Format-List   # 看全部字段
Get-PublicIP -NoUpdate       # 本次不检查更新
Get-PublicIP -WaitUpdate     # 等更新跑完再返回
```

返回的是 PSCustomObject，字段：`IP` `Family` `Source` `Country` `CountryCode` `Region` `City` `Latitude` `Longitude` `TimeZone` `Database`。

和 bash 版的差别：

- **零外部依赖**。Windows 上没有 `mmdblookup`，也不该为一个 profile 函数去装 Python，所以 MMDB 解析是用纯 PowerShell 实现的（搜索树遍历 + 数据段解码）。
- **更新完全不阻塞**。用 `Start-Job` 起后台作业，函数立刻返回；更新结果留到下次调用时报告，不会卡住提示符。bash 版是在脚本结尾等一下。
- 环境变量同 bash 版，另加 `MYIP_DBIP_BASE`（换下载源 / 镜像）。数据库默认放 `%LOCALAPPDATA%\bitTools\myip`。

## 依赖

**bash 版**：`bash`、`curl`、`gzip`；MaxMind 模式另需 `tar`
读取器：`maxminddb`（pip）或 `mmdblookup`（libmaxminddb）

**PowerShell 版**：无外部依赖。PowerShell 7+ 已验证；Windows PowerShell 5.1 按兼容写法写的（未实测）
