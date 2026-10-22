$ErrorActionPreference = "SilentlyContinue"
$name = if ($args.Count -ge 1) { $args[0] } else { "COM4" }
$secs = if ($args.Count -ge 2) { [int]$args[1] } else { 8 }
$p = New-Object System.IO.Ports.SerialPort $name,115200,None,8,one
$p.ReadTimeout = 1200
try { $p.Open() } catch { Write-Output "OPEN_FAIL: $($_.Exception.Message)"; exit 1 }
$end = (Get-Date).AddSeconds($secs)
$n = 0
while ((Get-Date) -lt $end) {
    try {
        $line = $p.ReadLine()
        Write-Output $line
        $n++
    } catch { }
}
$p.Close()
Write-Output "--- lines=$n ---"
