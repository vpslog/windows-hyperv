[CmdletBinding()]
param(
    [string]$WindowsIsoPath = ".\win11.iso"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

$WindowsIsoPath = Resolve-FullPath $WindowsIsoPath
if (-not (Test-Path -LiteralPath $WindowsIsoPath)) {
    throw "Windows ISO was not found: $WindowsIsoPath"
}

$diskImage = Mount-DiskImage -ImagePath $WindowsIsoPath -PassThru
try {
    $volume = $diskImage | Get-Volume
    $driveRoot = "$($volume.DriveLetter):\"
    $wimPath = Join-Path $driveRoot "sources\install.wim"
    $esdPath = Join-Path $driveRoot "sources\install.esd"

    if (Test-Path -LiteralPath $wimPath) {
        Get-WindowsImage -ImagePath $wimPath | Select-Object ImageIndex, ImageName, ImageDescription
    }
    elseif (Test-Path -LiteralPath $esdPath) {
        Get-WindowsImage -ImagePath $esdPath | Select-Object ImageIndex, ImageName, ImageDescription
    }
    else {
        throw "No sources\install.wim or sources\install.esd was found in the ISO."
    }
}
finally {
    Dismount-DiskImage -ImagePath $WindowsIsoPath | Out-Null
}
