Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$logPath = "C:\Windows\Temp\firstlogon-init.log"
Start-Transcript -Path $logPath -Append | Out-Null

try {
    Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
    Enable-PSRemoting -Force -SkipNetworkProfileCheck

    powercfg /change monitor-timeout-ac 0
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0

    New-Item -ItemType Directory -Path "C:\init" -Force | Out-Null
    Set-Content -Path "C:\init\README.txt" -Value "Windows 11 unattended Hyper-V initialization completed." -Encoding UTF8

    Write-Host "First logon initialization completed."
}
finally {
    Stop-Transcript | Out-Null
}
