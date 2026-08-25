#!/usr/bin/env bash
# myip.sh — 查外网 IP，并用本地 GeoIP 库给出归属地
#
# 结果先出，数据库更新在后台跑，不挡着看 IP。
# 数据库默认用 DB-IP City Lite（免注册、月更）；配了 MaxMind license key 就用 GeoLite2。
set -uo pipefail

DB_DIR="${MYIP_DB_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/myip}"
PROVIDER="${MYIP_DB_PROVIDER:-dbip}"          # dbip | maxmind
MAXMIND_KEY="${MAXMIND_LICENSE_KEY:-}"
DO_UPDATE="${MYIP_UPDATE:-1}"
CURL_TIMEOUT="${MYIP_TIMEOUT:-5}"

usage() {
  cat <<'USAGE'
用法: myip.sh [选项]

  --no-update      本次不检查数据库更新
  --update-only    只更新数据库，不查 IP
  -h, --help

环境变量:
  MYIP_DB_DIR           数据库存放目录，默认 ~/.cache/myip
  MYIP_DB_PROVIDER      dbip（默认，免注册）或 maxmind
  MAXMIND_LICENSE_KEY   用 maxmind 时必填，去 maxmind.com 免费申请
  MYIP_UPDATE           0 = 从不自动更新
  MYIP_TIMEOUT          单次请求超时秒数，默认 5
USAGE
}

UPDATE_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-update) DO_UPDATE=0; shift ;;
    --update-only) UPDATE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; echo >&2; usage >&2; exit 1 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "缺少命令: curl" >&2; exit 1; }

# ---------------------------------------------------------------- 取外网 IP

valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  # 光靠 [0-9]+ 的正则会放行 999.999.999.999，每段都得真的 <= 255
  local IFS='.'
  for o in $ip; do
    [[ "$o" -le 255 ]] || return 1
    # 除了 "0" 本身，不允许前导零（012 在某些解析器里会被当八进制）
    [[ "$o" == "0" || "$o" != 0* ]] || return 1
  done
  return 0
}

valid_ipv6() {
  # 不做完整校验，够用即可：只有十六进制和冒号，且至少两个冒号
  [[ "$1" =~ ^[0-9A-Fa-f:]+$ && "$1" == *::* ]] && return 0
  [[ "$1" =~ ^([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}$ ]] && return 0
  return 1
}

SERVICES=(
  "https://ifconfig.me"
  "https://icanhazip.com"
  "https://ipinfo.io/ip"
  "https://api.ipify.org"
  "https://checkip.amazonaws.com"
)

IP=""
IP_SOURCE=""
IP_FAMILY=""

fetch_ip() {
  local url candidate
  for url in "${SERVICES[@]}"; do
    candidate="$(curl -s --max-time "$CURL_TIMEOUT" "$url" 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$candidate" ]] || continue
    if valid_ipv4 "$candidate"; then
      IP="$candidate"; IP_SOURCE="$url"; IP_FAMILY="IPv4"; return 0
    elif valid_ipv6 "$candidate"; then
      IP="$candidate"; IP_SOURCE="$url"; IP_FAMILY="IPv6"; return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------- 数据库

db_path() {
  case "$PROVIDER" in
    maxmind) echo "$DB_DIR/GeoLite2-City.mmdb" ;;
    *)       echo "$DB_DIR/dbip-city-lite.mmdb" ;;
  esac
}
version_path() { echo "$(db_path).version"; }

# DB-IP 的免费库按月发布，文件名里带 YYYY-MM，所以「检查更新」就是比月份。
# 月初新库可能还没上线，退回上个月。
dbip_update() {
  local this_month last_month url stored
  this_month="$(date -u +%Y-%m)"
  last_month="$(date -u -d '1 month ago' +%Y-%m 2>/dev/null \
                || date -u -v-1m +%Y-%m 2>/dev/null || echo "")"
  stored="$(cat "$(version_path)" 2>/dev/null || echo "")"

  for m in "$this_month" "$last_month"; do
    [[ -n "$m" ]] || continue
    if [[ "$stored" == "$m" && -s "$(db_path)" ]]; then
      echo "数据库已是最新（$m）"
      return 0
    fi
    url="https://download.db-ip.com/free/dbip-city-lite-${m}.mmdb.gz"
    if curl -sfI --max-time 15 "$url" >/dev/null 2>&1; then
      echo "发现新版本 $m，下载中…"
      local tmp="$DB_DIR/.dbip-$m.mmdb.gz"
      if curl -sf --max-time 300 -o "$tmp" "$url" \
         && gunzip -f -c "$tmp" > "$(db_path).new" \
         && [[ -s "$(db_path).new" ]]; then
        mv -f "$(db_path).new" "$(db_path)"
        printf '%s\n' "$m" > "$(version_path)"
        rm -f "$tmp"
        echo "已更新到 $m"
        return 0
      fi
      rm -f "$tmp" "$(db_path).new"
      echo "下载失败，保留原有数据库" >&2
      return 1
    fi
  done
  echo "未找到可用的数据库版本" >&2
  return 1
}

# MaxMind 提供 .sha256，先比对校验和，不同才下整包，省流量
maxmind_update() {
  if [[ -z "$MAXMIND_KEY" ]]; then
    echo "MYIP_DB_PROVIDER=maxmind 但没设 MAXMIND_LICENSE_KEY" >&2
    return 1
  fi
  local base="https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=${MAXMIND_KEY}"
  local remote stored
  remote="$(curl -sf --max-time 30 "${base}&suffix=tar.gz.sha256" 2>/dev/null | awk '{print $1}')"
  if [[ -z "$remote" ]]; then
    echo "取校验和失败（license key 是否有效？）" >&2
    return 1
  fi
  stored="$(cat "$(version_path)" 2>/dev/null || echo "")"
  if [[ "$remote" == "$stored" && -s "$(db_path)" ]]; then
    echo "数据库已是最新"
    return 0
  fi

  echo "发现新版本，下载中…"
  command -v tar >/dev/null 2>&1 || { echo "缺少命令: tar" >&2; return 1; }
  local tmp="$DB_DIR/.geolite2.tar.gz" ex="$DB_DIR/.extract"
  rm -rf "$ex"; mkdir -p "$ex"
  if curl -sf --max-time 600 -o "$tmp" "${base}&suffix=tar.gz" \
     && tar -xzf "$tmp" -C "$ex"; then
    local found
    found="$(find "$ex" -name 'GeoLite2-City.mmdb' -type f | head -1)"
    if [[ -n "$found" && -s "$found" ]]; then
      mv -f "$found" "$(db_path)"
      printf '%s\n' "$remote" > "$(version_path)"
      rm -rf "$tmp" "$ex"
      echo "已更新"
      return 0
    fi
  fi
  rm -rf "$tmp" "$ex"
  echo "下载或解包失败，保留原有数据库" >&2
  return 1
}

update_db() {
  mkdir -p "$DB_DIR"
  case "$PROVIDER" in
    maxmind) maxmind_update ;;
    dbip)    dbip_update ;;
    *)       echo "未知的 MYIP_DB_PROVIDER: $PROVIDER" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------- 查询

lookup_ip() {
  local ip="$1" db
  db="$(db_path)"
  [[ -s "$db" ]] || return 2

  if command -v python3 >/dev/null 2>&1 && python3 -c "import maxminddb" 2>/dev/null; then
    python3 - "$db" "$ip" <<'PY'
import sys
import maxminddb

db_path, ip = sys.argv[1], sys.argv[2]
try:
    with maxminddb.open_database(db_path) as reader:
        rec = reader.get(ip)
except Exception as exc:
    print(f"查询出错: {exc}", file=sys.stderr)
    sys.exit(1)

if not rec:
    print("数据库里没有这个 IP 的记录", file=sys.stderr)
    sys.exit(3)


def name(node):
    if not isinstance(node, dict):
        return ""
    names = node.get("names") or {}
    return names.get("zh-CN") or names.get("en") or ""


country = name(rec.get("country")) or name(rec.get("registered_country"))
iso = (rec.get("country") or {}).get("iso_code", "")
city = name(rec.get("city"))
subs = rec.get("subdivisions") or []
sub = name(subs[0]) if subs else ""
loc = rec.get("location") or {}

parts = [p for p in (country, sub, city) if p]
print("归属地: " + (" / ".join(parts) if parts else "未知") + (f" [{iso}]" if iso else ""))
if loc.get("latitude") is not None and loc.get("longitude") is not None:
    print(f"坐标:   {loc['latitude']}, {loc['longitude']}")
if loc.get("time_zone"):
    print(f"时区:   {loc['time_zone']}")
PY
    return $?
  fi

  if command -v mmdblookup >/dev/null 2>&1; then
    local country city
    country="$(mmdblookup --file "$db" --ip "$ip" country names en 2>/dev/null \
               | tr -d '"' | tr -d ' ' | head -1)"
    city="$(mmdblookup --file "$db" --ip "$ip" city names en 2>/dev/null \
            | tr -d '"' | tr -d ' ' | head -1)"
    if [[ -z "$country" && -z "$city" ]]; then
      echo "数据库里没有这个 IP 的记录" >&2
      return 3
    fi
    echo "归属地: ${country:-未知}${city:+ / $city}"
    return 0
  fi

  return 4
}

# ---------------------------------------------------------------- 主流程

mkdir -p "$DB_DIR"
UPDATE_LOG="$DB_DIR/.update.log"

if [[ "$UPDATE_ONLY" == "1" ]]; then
  update_db
  exit $?
fi

echo "正在查询外网 IP..."
if ! fetch_ip; then
  echo "错误：无法获取外网 IP，请检查网络连接或防火墙设置。" >&2
  exit 1
fi

# 先把结果甩出来，更新在后台悄悄跑
echo "外网 IP: $IP  ($IP_FAMILY)"
echo "来源:    $IP_SOURCE"

UPDATE_PID=""
if [[ "$DO_UPDATE" == "1" ]]; then
  : > "$UPDATE_LOG"
  update_db > "$UPDATE_LOG" 2>&1 &
  UPDATE_PID=$!
fi

echo ""
if [[ -s "$(db_path)" ]]; then
  # 已有库就立刻查，不等更新
  lookup_ip "$IP"
  case $? in
    3) : ;;
    4) echo "需要装个 mmdb 读取器才能查归属地：" >&2
       echo "  pip install maxminddb        # 或" >&2
       echo "  apt install mmdb-bin         # 提供 mmdblookup" >&2 ;;
  esac
elif [[ -n "$UPDATE_PID" ]]; then
  echo "首次运行，正在下载 GeoIP 数据库…"
  wait "$UPDATE_PID"
  UPDATE_PID=""
  cat "$UPDATE_LOG"
  echo ""
  if [[ -s "$(db_path)" ]]; then
    lookup_ip "$IP"
    [[ $? -eq 4 ]] && {
      echo "需要装个 mmdb 读取器才能查归属地：" >&2
      echo "  pip install maxminddb        # 或" >&2
      echo "  apt install mmdb-bin         # 提供 mmdblookup" >&2
    }
  fi
else
  echo "本地没有 GeoIP 数据库（更新被 --no-update 关掉了）"
fi

# 收尾：等后台更新结束再退出，否则进程会被一起带走
if [[ -n "$UPDATE_PID" ]]; then
  wait "$UPDATE_PID" 2>/dev/null || true
  if [[ -s "$UPDATE_LOG" ]]; then
    echo ""
    echo "--- 数据库更新 ---"
    cat "$UPDATE_LOG"
  fi
fi

exit 0
