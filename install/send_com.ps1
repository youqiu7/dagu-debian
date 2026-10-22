param(
    [string]$Name = "COM4",
    [string]$Cmd = "uname",
    [int]$Wait = 5
)
$ErrorActionPreference = "SilentlyContinue"
$p = New-Object System.IO.Ports.SerialPort $Name,115200,None,8,one
$p.ReadTimeout = 400
try { $p.Open() } catch { Write-Output "OPEN_FAIL: $($_.Exception.Message)"; exit 1 }
Start-Sleep -Milliseconds 400
$p.DiscardInBuffer()
$p.Write($Cmd + "`r`n")
$p.Write([char]13)
$end = (Get-Date).AddSeconds($Wait)
while ((Get-Date) -lt $end) {
    try { Write-Output $p.ReadLine() } catch { }
}
$p.Close()
