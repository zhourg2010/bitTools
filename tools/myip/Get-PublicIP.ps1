<#
    Get-PublicIP.ps1 — 查外网 IP 并给出归属地（PowerShell 版，对应 myip.sh）

    放进 $PROFILE：
        . "$HOME\.bitTools\tools\myip\Get-PublicIP.ps1"

    设计要点：
      * 结果先出，GeoIP 数据库更新在后台跑，不挡着看 IP
      * 内置纯 PowerShell 的 MMDB 解析器，不依赖 Python / NuGet / 任何外部程序
      * 兼容 Windows PowerShell 5.1 与 PowerShell 7+

    环境变量：
      MYIP_DB_DIR         数据库目录，默认 %LOCALAPPDATA%\bitTools\myip
      MYIP_DB_PROVIDER    dbip（默认，免注册）或 maxmind
      MAXMIND_LICENSE_KEY 用 maxmind 时必填
      MYIP_DBIP_BASE      DB-IP 下载地址前缀，默认官方，可指向镜像
#>

#region ---------- MMDB 解析（纯 PowerShell，无外部依赖） ----------

function Read-MmdbValue {
    <# 按 MaxMind DB 格式解码一个值。$Offset 会被推进到该值之后。 #>
    param([byte[]]$Buf, [ref]$Offset, [int]$DataStart)

    $ctrl = $Buf[$Offset.Value]; $Offset.Value++
    $type = $ctrl -shr 5
    $size = $ctrl -band 0x1F

    if ($type -eq 1) {
        # 指针：高 2 位是长度档，低 3 位参与取值
        $ss = ($size -shr 3) -band 0x3
        $v  = $size -band 0x7
        switch ($ss) {
            0 { $p = ([int]$v -shl 8) -bor [int]$Buf[$Offset.Value]; $Offset.Value += 1 }
            1 { $p = (([int]$v -shl 16) -bor ([int]$Buf[$Offset.Value] -shl 8) -bor [int]$Buf[$Offset.Value+1]) + 2048; $Offset.Value += 2 }
            2 { $p = (([int]$v -shl 24) -bor ([int]$Buf[$Offset.Value] -shl 16) -bor ([int]$Buf[$Offset.Value+1] -shl 8) -bor [int]$Buf[$Offset.Value+2]) + 526336; $Offset.Value += 3 }
            3 { $p = ([int]$Buf[$Offset.Value] -shl 24) -bor ([int]$Buf[$Offset.Value+1] -shl 16) -bor ([int]$Buf[$Offset.Value+2] -shl 8) -bor [int]$Buf[$Offset.Value+3]; $Offset.Value += 4 }
        }
        $tmp = $DataStart + $p
        return (Read-MmdbValue -Buf $Buf -Offset ([ref]$tmp) -DataStart $DataStart)
    }

    if ($type -eq 0) { $type = 7 + [int]$Buf[$Offset.Value]; $Offset.Value++ }

    if     ($size -eq 29) { $size = 29 + [int]$Buf[$Offset.Value]; $Offset.Value += 1 }
    elseif ($size -eq 30) { $size = 285 + (([int]$Buf[$Offset.Value] -shl 8) -bor [int]$Buf[$Offset.Value+1]); $Offset.Value += 2 }
    elseif ($size -eq 31) { $size = 65821 + (([int]$Buf[$Offset.Value] -shl 16) -bor ([int]$Buf[$Offset.Value+1] -shl 8) -bor [int]$Buf[$Offset.Value+2]); $Offset.Value += 3 }

    switch ($type) {
        2 { $s = [Text.Encoding]::UTF8.GetString($Buf, $Offset.Value, $size); $Offset.Value += $size; return $s }
        3 { $b = $Buf[$Offset.Value..($Offset.Value+7)]; [Array]::Reverse($b); $Offset.Value += 8; return [BitConverter]::ToDouble([byte[]]$b, 0) }
        4 { $b = if ($size -gt 0) { $Buf[$Offset.Value..($Offset.Value+$size-1)] } else { @() }; $Offset.Value += $size; return $b }
        7 {
            $m = [ordered]@{}
            for ($i = 0; $i -lt $size; $i++) {
                $k = Read-MmdbValue -Buf $Buf -Offset $Offset -DataStart $DataStart
                $m[[string]$k] = Read-MmdbValue -Buf $Buf -Offset $Offset -DataStart $DataStart
            }
            return $m
        }
        8 {
            $n = 0
            for ($i = 0; $i -lt $size; $i++) { $n = ($n -shl 8) -bor [int]$Buf[$Offset.Value + $i] }
            $Offset.Value += $size
            if ($size -eq 4 -and $n -gt 2147483647) { $n = $n - 4294967296 }
            return [int]$n
        }
        11 {
            $a = @()
            for ($i = 0; $i -lt $size; $i++) { $a += ,(Read-MmdbValue -Buf $Buf -Offset $Offset -DataStart $DataStart) }
            return ,$a
        }
        14 { return [bool]$size }
        15 { $b = $Buf[$Offset.Value..($Offset.Value+3)]; [Array]::Reverse($b); $Offset.Value += 4; return [BitConverter]::ToSingle([byte[]]$b, 0) }
        default {
            $n = [uint64]0
            for ($i = 0; $i -lt $size; $i++) { $n = ($n -shl 8) -bor [uint64]$Buf[$Offset.Value + $i] }
            $Offset.Value += $size; return $n
        }
    }
}

function Open-MmdbFile {
    param([string]$Path)
    $buf = [IO.File]::ReadAllBytes($Path)
    $marker = [byte[]]@(0xAB,0xCD,0xEF) + [Text.Encoding]::ASCII.GetBytes("MaxMind.com")
    $idx = -1
    for ($i = $buf.Length - $marker.Length; $i -ge 0; $i--) {
        $hit = $true
        for ($j = 0; $j -lt $marker.Length; $j++) { if ($buf[$i+$j] -ne $marker[$j]) { $hit = $false; break } }
        if ($hit) { $idx = $i; break }
    }
    if ($idx -lt 0) { throw "不是有效的 mmdb 文件：找不到元数据标记" }

    $off = $idx + $marker.Length
    $meta = Read-MmdbValue -Buf $buf -Offset ([ref]$off) -DataStart 0
    $recordSize = [int]$meta['record_size']
    $nodeCount  = [int]$meta['node_count']
    $treeSize   = [int]($nodeCount * $recordSize * 2 / 8)
    [PSCustomObject]@{
        Buffer     = $buf
        RecordSize = $recordSize
        NodeCount  = $nodeCount
        IpVersion  = [int]$meta['ip_version']
        BuildEpoch = [uint64]$meta['build_epoch']
        TreeSize   = $treeSize
        DataStart  = $treeSize + 16
    }
}

function Get-MmdbRecord {
    param($Db, [string]$IpString)

    $ip = $null
    if (-not [Net.IPAddress]::TryParse($IpString, [ref]$ip)) { return $null }
    $addr = $ip.GetAddressBytes()
    if ($addr.Length -eq 4 -and $Db.IpVersion -eq 6) {
        $addr = [byte[]]((,[byte]0 * 12) + $addr)       # IPv4 映射到 ::/96
    } elseif ($addr.Length -eq 16 -and $Db.IpVersion -eq 4) {
        return $null                                     # v4 库查不了 v6
    }

    # 注意：PowerShell 的 -shl 作用在 [byte] 上会保持 byte 类型并截断到 8 位，
    # 所有参与移位的字节都必须先转 [int]，否则高位会被静默丢掉。
    $buf = $Db.Buffer; $rs = $Db.RecordSize; $node = 0
    foreach ($byte in $addr) {
        for ($bit = 7; $bit -ge 0; $bit--) {
            if ($node -ge $Db.NodeCount) { break }
            $isRight = (([int]$byte -shr $bit) -band 1) -eq 1
            if ($rs -eq 24) {
                $base = $node * 6
                $node = if ($isRight) { ([int]$buf[$base+3] -shl 16) -bor ([int]$buf[$base+4] -shl 8) -bor [int]$buf[$base+5] }
                        else          { ([int]$buf[$base]   -shl 16) -bor ([int]$buf[$base+1] -shl 8) -bor [int]$buf[$base+2] }
            } elseif ($rs -eq 28) {
                $base = $node * 7
                $node = if ($isRight) { (([int]$buf[$base+3] -band 0x0F) -shl 24) -bor ([int]$buf[$base+4] -shl 16) -bor ([int]$buf[$base+5] -shl 8) -bor [int]$buf[$base+6] }
                        else          { (([int]$buf[$base+3] -shr 4) -shl 24)     -bor ([int]$buf[$base]   -shl 16) -bor ([int]$buf[$base+1] -shl 8) -bor [int]$buf[$base+2] }
            } else {
                $base = $node * 8
                $node = if ($isRight) { ([int]$buf[$base+4] -shl 24) -bor ([int]$buf[$base+5] -shl 16) -bor ([int]$buf[$base+6] -shl 8) -bor [int]$buf[$base+7] }
                        else          { ([int]$buf[$base]   -shl 24) -bor ([int]$buf[$base+1] -shl 16) -bor ([int]$buf[$base+2] -shl 8) -bor [int]$buf[$base+3] }
            }
        }
        if ($node -ge $Db.NodeCount) { break }
    }

    if ($node -le $Db.NodeCount) { return $null }   # == 表示明确无记录，< 表示树没走完
    $offset = $Db.TreeSize + ($node - $Db.NodeCount)
    return (Read-MmdbValue -Buf $buf -Offset ([ref]$offset) -DataStart $Db.DataStart)
}

#endregion

#region ---------- 数据库路径与更新 ----------

function Get-MyIPPaths {
    $dir = $env:MYIP_DB_DIR
    if (-not $dir) {
        $dir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'bitTools\myip' }
               else { Join-Path $HOME '.cache/myip' }
    }
    $provider = if ($env:MYIP_DB_PROVIDER) { $env:MYIP_DB_PROVIDER } else { 'dbip' }
    $name = if ($provider -eq 'maxmind') { 'GeoLite2-City' } else { 'dbip-city-lite' }
    [PSCustomObject]@{
        Dir      = $dir
        Provider = $provider
        Db       = Join-Path $dir "$name.mmdb"
        Version  = Join-Path $dir "$name.mmdb.version"
    }
}

$script:MyIPUpdateJobName = 'BitToolsMyIPUpdate'

function Get-MyIPUpdateScriptBlock {
    # 后台作业跑的是独立进程，拿不到当前会话的函数，所以这里必须自包含
    {
        param($Dir, $DbPath, $VersionPath, $Provider, $MaxmindKey, $DbipBase)

        function Expand-Gzip([string]$Src, [string]$Dst) {
            $in  = [IO.File]::OpenRead($Src)
            $gz  = New-Object IO.Compression.GzipStream($in, [IO.Compression.CompressionMode]::Decompress)
            $out = [IO.File]::Create($Dst)
            try { $gz.CopyTo($out) } finally { $out.Dispose(); $gz.Dispose(); $in.Dispose() }
        }

        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        $stored = if (Test-Path $VersionPath) { (Get-Content $VersionPath -Raw).Trim() } else { '' }

        if ($Provider -eq 'maxmind') {
            if (-not $MaxmindKey) { return '需要 MAXMIND_LICENSE_KEY' }
            $base = "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=$MaxmindKey"
            try { $remote = ((Invoke-WebRequest -Uri "$base&suffix=tar.gz.sha256" -UseBasicParsing -TimeoutSec 30).Content -split '\s+')[0] }
            catch { return "取校验和失败：$($_.Exception.Message)" }
            if ($remote -eq $stored -and (Test-Path $DbPath)) { return '数据库已是最新' }
            return 'MaxMind 的 tar.gz 需要手工解包，请改用 dbip 或用 myip.sh 更新'
        }

        # DB-IP 免费库按月发布，文件名里带 YYYY-MM；月初新库可能还没上线，退回上个月
        $months = @((Get-Date).ToUniversalTime().ToString('yyyy-MM'),
                    (Get-Date).ToUniversalTime().AddMonths(-1).ToString('yyyy-MM'))
        foreach ($m in $months) {
            if ($stored -eq $m -and (Test-Path $DbPath)) { return "数据库已是最新（$m）" }
            $url = "$DbipBase/dbip-city-lite-$m.mmdb.gz"
            $gz  = Join-Path $Dir ".dbip-$m.mmdb.gz"
            $new = "$DbPath.new"
            try {
                Invoke-WebRequest -Uri $url -OutFile $gz -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
            } catch { continue }
            try {
                Expand-Gzip -Src $gz -Dst $new
                if ((Get-Item $new).Length -le 0) { throw '解压结果为空' }
                Move-Item -Force $new $DbPath
                Set-Content -Path $VersionPath -Value $m -NoNewline
                Remove-Item -Force $gz -ErrorAction SilentlyContinue
                return "已更新到 $m"
            } catch {
                Remove-Item -Force $gz, $new -ErrorAction SilentlyContinue
                return "下载失败，保留原有数据库：$($_.Exception.Message)"
            }
        }
        return '未找到可用的数据库版本'
    }
}

function Start-MyIPDatabaseUpdate {
    [CmdletBinding()]
    param([switch]$Wait)

    $p = Get-MyIPPaths
    $base = if ($env:MYIP_DBIP_BASE) { $env:MYIP_DBIP_BASE } else { 'https://download.db-ip.com/free' }

    # 先收一收上次留下的作业，把结果报给用户
    $old = Get-Job -Name $script:MyIPUpdateJobName -ErrorAction SilentlyContinue
    foreach ($j in $old) {
        if ($j.State -in 'Completed','Failed','Stopped') {
            $msg = (Receive-Job $j -ErrorAction SilentlyContinue) -join '; '
            if ($msg) { Write-Host "[数据库] $msg" -ForegroundColor DarkGray }
            Remove-Job $j -Force -ErrorAction SilentlyContinue
        } else {
            return $null   # 上一个还在跑，别重复起
        }
    }

    # dbip 的「要不要更新」只是比月份，纯本地判断，命中就一次网络请求都不发
    if ($p.Provider -eq 'dbip' -and (Test-Path $p.Db) -and (Test-Path $p.Version)) {
        $stored = (Get-Content $p.Version -Raw).Trim()
        if ($stored -eq (Get-Date).ToUniversalTime().ToString('yyyy-MM')) { return $null }
    }

    $job = Start-Job -Name $script:MyIPUpdateJobName -ScriptBlock (Get-MyIPUpdateScriptBlock) `
                     -ArgumentList $p.Dir, $p.Db, $p.Version, $p.Provider, $env:MAXMIND_LICENSE_KEY, $base
    if ($Wait) {
        $null = Wait-Job $job
        $msg = (Receive-Job $job -ErrorAction SilentlyContinue) -join '; '
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return $msg
    }
    return $null
}

#endregion

#region ---------- 主函数 ----------

function Test-PublicIPCandidate {
    param([string]$Value)
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed)) { return $null }
    switch ($parsed.AddressFamily) {
        'InterNetwork' {
            # 回环比较：挡掉 01.2.3.4、1.2 这种被宽松解析的写法
            # （Windows PowerShell 5.1 底下的 .NET Framework 会把它们当合法输入）
            if ($parsed.ToString() -ne $Value) { return $null }
            return [PSCustomObject]@{ IP = $Value; Family = 'IPv4' }
        }
        'InterNetworkV6' {
            return [PSCustomObject]@{ IP = $parsed.ToString(); Family = 'IPv6' }
        }
    }
    return $null
}

function Get-PublicIP {
    <#
    .SYNOPSIS
        查询当前外网 IP，并用本地 GeoIP 数据库给出归属地。
    .DESCRIPTION
        依次尝试多个公共 IP 查询服务，返回第一个有效结果。
        拿到 IP 后立刻用现有数据库定位；数据库更新在后台作业里进行，不阻塞输出。
    .PARAMETER NoUpdate
        本次不检查数据库更新。
    .PARAMETER WaitUpdate
        等后台更新跑完再返回（首次没有数据库时总是会等）。
    .PARAMETER TimeoutSec
        单个服务的超时秒数，默认 5。
    .EXAMPLE
        Get-PublicIP
    .EXAMPLE
        (Get-PublicIP).IP
    .EXAMPLE
        Get-PublicIP | Format-List *
    #>
    [CmdletBinding()]
    param(
        [switch]$NoUpdate,
        [switch]$WaitUpdate,
        [int]$TimeoutSec = 5
    )

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    $services = @(
        "https://ifconfig.me",
        "https://icanhazip.com",
        "https://ipinfo.io/ip",
        "https://api.ipify.org",
        "https://checkip.amazonaws.com"
    )

    $found = $null
    foreach ($url in $services) {
        try {
            $resp = Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
            $text = ([string]$resp.Content).Trim()
            $cand = Test-PublicIPCandidate -Value $text
            if ($cand) { $found = $cand; $found | Add-Member -NotePropertyName Source -NotePropertyValue $url; break }
        } catch {
            continue   # 这家不行，换下一家
        }
    }

    if (-not $found) {
        Write-Error "无法获取外网 IP，请检查网络连接或防火墙设置。"
        return
    }

    $p = Get-MyIPPaths
    $hadDb = Test-Path $p.Db

    # 结果先出：更新在后台，不挡着定位
    if (-not $NoUpdate) {
        if (-not $hadDb) {
            Write-Host "首次运行，正在下载 GeoIP 数据库…" -ForegroundColor DarkGray
            $msg = Start-MyIPDatabaseUpdate -Wait
            if ($msg) { Write-Host "[数据库] $msg" -ForegroundColor DarkGray }
        } else {
            $null = Start-MyIPDatabaseUpdate -Wait:$WaitUpdate
        }
    }

    $out = [ordered]@{
        IP          = $found.IP
        Family      = $found.Family
        Source      = $found.Source
        Country     = $null
        CountryCode = $null
        Region      = $null
        City        = $null
        Latitude    = $null
        Longitude   = $null
        TimeZone    = $null
        Database    = $null
    }

    if (Test-Path $p.Db) {
        try {
            $db  = Open-MmdbFile -Path $p.Db
            $rec = Get-MmdbRecord -Db $db -IpString $found.IP
            $out.Database = if (Test-Path $p.Version) { "$($p.Provider) $((Get-Content $p.Version -Raw).Trim())" } else { $p.Provider }
            if ($rec) {
                function Get-Name($node) {
                    if (-not $node) { return $null }
                    $names = $node['names']
                    if (-not $names) { return $null }
                    if ($names['zh-CN']) { return $names['zh-CN'] }
                    return $names['en']
                }
                $out.Country     = Get-Name $rec['country']
                if (-not $out.Country) { $out.Country = Get-Name $rec['registered_country'] }
                if ($rec['country']) { $out.CountryCode = $rec['country']['iso_code'] }
                $subs = $rec['subdivisions']
                if ($subs) { $out.Region = Get-Name (@($subs)[0]) }
                $out.City = Get-Name $rec['city']
                $loc = $rec['location']
                if ($loc) {
                    $out.Latitude  = $loc['latitude']
                    $out.Longitude = $loc['longitude']
                    $out.TimeZone  = $loc['time_zone']
                }
            } else {
                Write-Verbose "数据库里没有 $($found.IP) 的记录"
            }
        } catch {
            Write-Warning "读取 GeoIP 数据库失败：$($_.Exception.Message)"
        }
    } else {
        Write-Verbose "本地还没有 GeoIP 数据库"
    }

    [PSCustomObject]$out
}

Set-Alias -Name myip -Value Get-PublicIP -Scope Global -ErrorAction SilentlyContinue

#endregion
