[CmdletBinding()]
param(
    [string]$VmName = "Win11-Auto",
    [string]$WindowsIsoPath = ".\win11.iso",
    [string]$ExtraFilesPath = ".\out\answer-files",
    [switch]$UseNoPromptIso,
    [string]$OscdimgPath = "",
    [switch]$DownloadOscdimg,
    [switch]$DisableSecureBoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
}

Assert-Administrator

$WindowsIsoPath = Resolve-FullPath $WindowsIsoPath
if (-not (Test-Path -LiteralPath $WindowsIsoPath)) {
    throw "Windows ISO was not found: $WindowsIsoPath"
}

if ($UseNoPromptIso) {
    $noPromptIsoPath = Join-Path (Split-Path -Parent $WindowsIsoPath) "out\win11-noprompt.iso"
    $noPromptScript = Join-Path $PSScriptRoot "New-NoPromptWindowsIso.ps1"
    if (-not (Test-Path -LiteralPath $noPromptScript)) {
        throw "No-prompt ISO script was not found: $noPromptScript"
    }

    $noPromptArgs = @{
        WindowsIsoPath = $WindowsIsoPath
        OutputIsoPath = $noPromptIsoPath
    }
    $resolvedExtraFilesPath = Resolve-FullPath $ExtraFilesPath
    if (Test-Path -LiteralPath (Join-Path $resolvedExtraFilesPath "Autounattend.xml")) {
        $noPromptArgs.ExtraFilesPath = $resolvedExtraFilesPath
    }
    if ($OscdimgPath) {
        $noPromptArgs.OscdimgPath = $OscdimgPath
    }
    if ($DownloadOscdimg) {
        $noPromptArgs.DownloadOscdimg = $true
    }

    & $noPromptScript @noPromptArgs
    $WindowsIsoPath = Resolve-FullPath $noPromptIsoPath
}

$vm = Get-VM -Name $VmName -ErrorAction Stop
if ($vm.State -ne "Off") {
    Stop-VM -Name $VmName -TurnOff -Force
}

$windowsDvd = Get-VMDvdDrive -VMName $VmName | Where-Object {
    $_.Path -and ([IO.Path]::GetFullPath($_.Path) -ieq $WindowsIsoPath)
} | Select-Object -First 1

if (-not $windowsDvd) {
    $windowsDvd = Add-VMDvdDrive -VMName $VmName -Path $WindowsIsoPath -Passthru
}
else {
    Set-VMDvdDrive -VMName $VmName -ControllerNumber $windowsDvd.ControllerNumber -ControllerLocation $windowsDvd.ControllerLocation -Path $WindowsIsoPath
}

if ($DisableSecureBoot) {
    Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
}
else {
    Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate "MicrosoftWindows"
}

Set-VMFirmware -VMName $VmName -FirstBootDevice $windowsDvd

Write-Host "VM boot settings updated: $VmName"
Write-Host "Windows ISO: $WindowsIsoPath"
Write-Host "Secure Boot: $(-not $DisableSecureBoot)"
Write-Host "Current DVD drives:"
Get-VMDvdDrive -VMName $VmName | Format-Table ControllerNumber, ControllerLocation, Path -AutoSize

Write-Host "Current firmware boot order:"
(Get-VMFirmware -VMName $VmName).BootOrder | Format-Table BootType, Device, Description -AutoSize

Start-VM -Name $VmName
