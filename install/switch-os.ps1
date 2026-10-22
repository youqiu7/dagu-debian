#requires -Version 5
<#
.SYNOPSIS
  dagu 双系统一键互切（Android a 槽 <-> Debian b 槽）
.DESCRIPTION
  槽位元数据存在 ABL 私有区，Linux/Android 都读不到，只能通过 fastboot set_active 切换。
  本脚本自动识别设备当前所处状态（Android 运行中 / Debian 运行中 / fastboot / recovery），
  一路把设备带到 fastboot、切槽、重启。
.EXAMPLE
  .\switch-os.ps1 -To debian
  .\switch-os.ps1 -To android
  .\switch-os.ps1 -Status
#>
param(
    [ValidateSet("android", "debian")]
    [string]$To,
    [switch]$Status,
    [string]$Fastboot = "F:\小米刷机\dagu移植debian\new-chat-1\platform-tools\platform-tools\fastboot.exe",
    [string]$Adb      = "F:\小米刷机\dagu移植debian\new-chat-1\platform-tools\platform-tools\adb.exe",
    [string]$DebianIp = "192.168.10.125",
    [string]$SshKey   = "$env:USERPROFILE\.ssh\dagu_key"
)

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

$slotFor = @{ android = "a"; debian = "b" }
$labelFor = @{ a = "Android（原厂 a 槽）"; b = "Debian b 槽" }

function Get-FastbootDevices {
    $out = & $Fastboot devices 2>&1
    return ($out | Where-Object { $_ -match 'fastboot' })
}
function Get-AdbDevices {
    $out = & $Adb devices 2>&1
    return ($out | Where-Object { $_ -match '\s(device|recovery)\s*$' })
}
function Get-CurrentSlot {
    $out = & $Fastboot getvar current-slot 2>&1
    $line = $out | Where-Object { $_ -match 'current-slot' }
    if ($line -match ':\s*([ab])') { return $Matches[1] }
    return $null
}
function Wait-Fastboot([int]$TimeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Get-FastbootDevices) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

# ---------------------------------------------------------------- 状态
function Show-Status {
    Say "fastboot"
    $fb = Get-FastbootDevices
    if ($fb) { $fb | ForEach-Object { Write-Host "    $_" } } else { Write-Host "    (none)" }

    Say "adb"
    $ad = Get-AdbDevices
    if ($ad) { $ad | ForEach-Object { Write-Host "    $_" } } else { Write-Host "    (none)" }

    Say "Debian (SSH $DebianIp)"
    $ok = $false
    try {
        $r = & ssh -i $SshKey -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "root@$DebianIp" "uname -r" 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host "    在线, 内核 $($r | Select-Object -First 1)"; $ok = $true }
    } catch {}
    if (-not $ok) { Write-Host "    (不可达)" }

    if ($fb) {
        $slot = Get-CurrentSlot
        if ($slot) { Say "当前槽位: $slot — $($labelFor[$slot])" }
    }
}

if ($Status -or -not $To) { Show-Status; exit 0 }

$target = $slotFor[$To]
Say "目标: $To（$($labelFor[$target])），当前槽位将切换为 $target"

# ---------------------------------------------------------------- 1. 把设备带到 fastboot
$fb = Get-FastbootDevices
if (-not $fb) {
    $ad = Get-AdbDevices
    if ($ad) {
        $state = ($ad | Select-Object -First 1) -split '\s+' | Where-Object { $_ -in @('device','recovery') } | Select-Object -First 1
        Say "adb 设备处于 $state，重启到 bootloader"
        & $Adb reboot bootloader | Out-Null
    } else {
        # 试试 Debian 的 SSH
        Say "尝试通过 Debian SSH 重启到 bootloader"
        try {
            & ssh -i $SshKey -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "root@$DebianIp" "sync; systemctl reboot bootloader" 2>&1 | Out-Null
        } catch {}
        if ($LASTEXITCODE -ne 0) {
            Warn "无法自动让设备进入 fastboot。"
            Warn "请在设备上：长按电源 10 秒关机 → 按住【音量下 + 电源】直到出现 fastboot 界面"
            if (-not (Wait-Fastboot 180)) { Fail "等待 fastboot 超时" }
        }
    }
    if (-not (Wait-Fastboot 90)) { Fail "设备没有进入 fastboot" }
}
Say "fastboot 已就绪"

# ---------------------------------------------------------------- 2. 切槽
$cur = Get-CurrentSlot
Say "当前槽位: $cur"
if ($cur -eq $target) {
    Say "已经是 $target 槽，无需切换，直接重启"
} else {
    & $Fastboot set_active $target 2>&1 | ForEach-Object { Write-Host "    $_" }
    $after = Get-CurrentSlot
    if ($after -ne $target) { Fail "set_active 失败（仍是 $after）" }
    Say "槽位已切换: $cur -> $after"
}

# ---------------------------------------------------------------- 3. 重启并等目标系统
& $Fastboot reboot | Out-Null
Say "已重启，等待系统启动..."

if ($To -eq "debian") {
    $deadline = (Get-Date).AddSeconds(150)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        try {
            $r = & ssh -i $SshKey -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=4 "root@$DebianIp" "uname -r" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host ""
                Say "Debian 已启动: $($r | Select-Object -First 1)"
                Write-Host "    SSH: ssh -i $SshKey root@$DebianIp" -ForegroundColor Green
                exit 0
            }
        } catch {}
        # IP 可能变了，试试另外两个
        foreach ($ip in @("192.168.10.240", "192.168.10.123")) {
            if ($ip -eq $DebianIp) { continue }
            try {
                $r = & ssh -i $SshKey -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=3 "root@$ip" "uname -r" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Say "Debian 已启动（IP 变为 $ip）: $($r | Select-Object -First 1)"
                    Write-Host "    SSH: ssh -i $SshKey root@$ip" -ForegroundColor Green
                    exit 0
                }
            } catch {}
        }
    }
    Warn "150 秒内没等到 Debian。串口 COM4 通常能看到启动日志。"
    Warn "如果设备卡住：长按电源 10 秒 → 音量下+电源 进 fastboot，然后重跑本脚本。"
} else {
    Start-Sleep -Seconds 20
    $ad = Get-AdbDevices
    if ($ad) {
        Say "Android 已启动（adb 可见）"
        $ad | ForEach-Object { Write-Host "    $_" }
    } else {
        Say "已切换到 Android 槽。adb 需要开启 USB 调试才能被本机发现。"
    }
}
