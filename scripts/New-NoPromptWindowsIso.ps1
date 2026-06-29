[CmdletBinding()]
param(
    [string]$WindowsIsoPath = ".\win11.iso",
    [string]$OutputIsoPath = ".\out\win11-noprompt.iso",
    [string]$OscdimgPath = "",
    [switch]$InstallAdkDeploymentTools
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Find-Oscdimg {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        $fullPath = Resolve-FullPath $ExplicitPath
        if (Test-Path -LiteralPath $fullPath) {
            return $fullPath
        }
        throw "oscdimg.exe was not found: $fullPath"
    }

    $command = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\x86\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\x86\Oscdimg\oscdimg.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw "oscdimg.exe was not found. Install Windows ADK Deployment Tools, or pass -OscdimgPath."
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
}

function Install-AdkDeploymentTools {
    param(
        [string]$InstallPath = "$env:ProgramFiles\Windows Kits\10"
    )

    Assert-Administrator

    $downloadRoot = Join-Path $env:TEMP "win11-hyperv-adk"
    $installerPath = Join-Path $downloadRoot "adksetup.exe"
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null

    if (-not (Test-Path -LiteralPath $installerPath)) {
        $adkUrl = "https://go.microsoft.com/fwlink/?linkid=2289980"
        Write-Host "Downloading Windows ADK setup..."
        Write-Host $adkUrl
        Invoke-WebRequest -Uri $adkUrl -OutFile $installerPath -UseBasicParsing
    }

    Write-Host "Installing Windows ADK Deployment Tools..."
    $arguments = @(
        "/quiet",
        "/norestart",
        "/installpath",
        $InstallPath,
        "/features",
        "OptionId.DeploymentTools"
    )

    $process = Start-Process -FilePath $installerPath -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "ADK Deployment Tools install failed with exit code $($process.ExitCode)."
    }
}

$WindowsIsoPath = Resolve-FullPath $WindowsIsoPath
$OutputIsoPath = Resolve-FullPath $OutputIsoPath
try {
    $oscdimg = Find-Oscdimg -ExplicitPath $OscdimgPath
}
catch {
    if (-not $InstallAdkDeploymentTools) {
        throw
    }

    Install-AdkDeploymentTools
    $oscdimg = Find-Oscdimg -ExplicitPath $OscdimgPath
}

if (-not (Test-Path -LiteralPath $WindowsIsoPath)) {
    throw "Windows ISO was not found: $WindowsIsoPath"
}

New-Item -ItemType Directory -Path (Split-Path -Parent $OutputIsoPath) -Force | Out-Null
if (Test-Path -LiteralPath $OutputIsoPath) {
    Remove-Item -LiteralPath $OutputIsoPath -Force
}

$diskImage = $null
try {
    $diskImage = Mount-DiskImage -ImagePath $WindowsIsoPath -PassThru
    Start-Sleep -Milliseconds 500
    $volume = $diskImage | Get-Volume
    if (-not $volume -or -not $volume.DriveLetter) {
        throw "Mounted ISO has no drive letter."
    }

    $sourceRoot = "$($volume.DriveLetter):\"
    $biosBoot = Join-Path $sourceRoot "boot\etfsboot.com"
    $uefiNoPromptBoot = Join-Path $sourceRoot "efi\microsoft\boot\efisys_noprompt.bin"
    $uefiPromptBoot = Join-Path $sourceRoot "efi\microsoft\boot\efisys.bin"

    if (-not (Test-Path -LiteralPath $biosBoot)) {
        throw "Missing BIOS boot file: $biosBoot"
    }

    if (-not (Test-Path -LiteralPath $uefiNoPromptBoot)) {
        throw "Missing UEFI no-prompt boot file: $uefiNoPromptBoot"
    }

    if (-not (Test-Path -LiteralPath $uefiPromptBoot)) {
        throw "Missing UEFI boot file: $uefiPromptBoot"
    }

    $bootData = '2#p0,e,b"{0}"#pEF,e,b"{1}"' -f $biosBoot, $uefiNoPromptBoot
    $arguments = @(
        "-bootdata:$bootData",
        "-m",
        "-o",
        "-u2",
        "-udfver102",
        "-lWIN11_NOPROMPT",
        $sourceRoot,
        $OutputIsoPath
    )

    Write-Host "Source ISO: $WindowsIsoPath"
    Write-Host "Output ISO: $OutputIsoPath"
    Write-Host "oscdimg.exe: $oscdimg"
    Write-Host "Creating no-prompt Windows ISO..."

    & $oscdimg @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "oscdimg.exe failed with exit code $LASTEXITCODE."
    }

    if (-not (Test-Path -LiteralPath $OutputIsoPath)) {
        throw "Output ISO was not created: $OutputIsoPath"
    }

    Write-Host "Created no-prompt ISO: $OutputIsoPath"
}
finally {
    if ($diskImage) {
        Dismount-DiskImage -ImagePath $WindowsIsoPath -ErrorAction SilentlyContinue | Out-Null
    }
}
