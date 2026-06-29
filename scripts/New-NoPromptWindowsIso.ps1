[CmdletBinding()]
param(
    [string]$WindowsIsoPath = ".\win11.iso",
    [string]$OutputIsoPath = ".\out\win11-noprompt.iso",
    [string]$ExtraFilesPath = "",
    [string]$OscdimgPath = "",
    [switch]$DownloadOscdimg,
    [switch]$SkipBootWimUnattendInjection,
    [string]$OscdimgOutputPath = ".\out\tools\oscdimg.exe",
    [string[]]$OscdimgCabUrl = @(
        "https://download.microsoft.com/download/2/d/9/2d9c8902-3fcd-48a6-a22a-432b08bed61e/ADK/Installers/8ae6e3f2b02bc9aa4d16ce91ff65faf9.cab",
        "https://download.microsoft.com/download/2/d/9/2d9c8902-3fcd-48a6-a22a-432b08bed61e/ADK/Installers/bf7b6300431984daf850cc213043c7eb.cab"
    )
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
        (Resolve-FullPath ".\out\tools\oscdimg.exe"),
        "C:\ADK\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "C:\ADK\Assessment and Deployment Kit\Deployment Tools\x86\Oscdimg\oscdimg.exe",
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

    throw "oscdimg.exe was not found. Add it to PATH, install Windows ADK Deployment Tools, or pass -OscdimgPath."
}

function Expand-CabAndFindOscdimg {
    param(
        [Parameter(Mandatory)][string]$CabPath,
        [Parameter(Mandatory)][string]$ExtractRoot
    )

    if (Test-Path -LiteralPath $ExtractRoot) {
        Remove-Item -LiteralPath $ExtractRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null

    & expand.exe -F:* $CabPath $ExtractRoot | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "expand.exe failed for CAB: $CabPath"
    }

    Get-ChildItem -LiteralPath $ExtractRoot -Recurse -Filter oscdimg.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

function Save-OscdimgOnly {
    param(
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string[]]$CabUrls
    )

    $DestinationPath = Resolve-FullPath $DestinationPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $DestinationPath) -Force | Out-Null

    $localCabRoots = @(
        (Join-Path $env:TEMP "win11-hyperv-adk"),
        "C:\ProgramData\Package Cache"
    )

    foreach ($root in $localCabRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        $cabs = Get-ChildItem -LiteralPath $root -Recurse -Filter *.cab -ErrorAction SilentlyContinue
        foreach ($cab in $cabs) {
            $extractRoot = Join-Path $env:TEMP ("oscdimg-cab-" + [guid]::NewGuid().ToString("N"))
            try {
                $found = Expand-CabAndFindOscdimg -CabPath $cab.FullName -ExtractRoot $extractRoot
                if ($found) {
                    Copy-Item -LiteralPath $found.FullName -Destination $DestinationPath -Force
                    return $DestinationPath
                }
            }
            catch {
            }
            finally {
                Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $downloadRoot = Join-Path $env:TEMP "win11-hyperv-oscdimg"
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null

    foreach ($url in $CabUrls) {
        $cabPath = Join-Path $downloadRoot ([IO.Path]::GetFileName(([Uri]$url).AbsolutePath))
        Write-Host "Downloading oscdimg CAB:"
        Write-Host $url
        Invoke-WebRequest -Uri $url -OutFile $cabPath -UseBasicParsing

        $extractRoot = Join-Path $downloadRoot ([IO.Path]::GetFileNameWithoutExtension($cabPath))
        try {
            $found = Expand-CabAndFindOscdimg -CabPath $cabPath -ExtractRoot $extractRoot
            if ($found) {
                Copy-Item -LiteralPath $found.FullName -Destination $DestinationPath -Force
                return $DestinationPath
            }
        }
        finally {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    throw "Could not extract oscdimg.exe from local ADK cache or configured CAB URLs."
}

function Add-UnattendToBootWim {
    param(
        [Parameter(Mandatory)][string]$BootWimPath,
        [Parameter(Mandatory)][string]$UnattendPath,
        [Parameter(Mandatory)][string]$WorkRoot
    )

    if (-not (Test-Path -LiteralPath $BootWimPath)) {
        throw "boot.wim was not found: $BootWimPath"
    }

    $mountRoot = Join-Path $WorkRoot ("bootwim-mount-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $mountRoot -Force | Out-Null
    attrib.exe -R $BootWimPath | Out-Null

    $mounted = $false
    try {
        foreach ($index in @(1, 2)) {
            Write-Host "Injecting unattend file into boot.wim index $index..."
            $mountArgs = @(
                "/Mount-Wim",
                "/WimFile:$BootWimPath",
                "/Index:$index",
                "/MountDir:$mountRoot"
            )
            & dism.exe @mountArgs | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "dism.exe failed to mount boot.wim index $index. Exit code: $LASTEXITCODE"
            }
            $mounted = $true

            $pantherRoot = Join-Path $mountRoot "Windows\Panther"
            $pantherUnattendRoot = Join-Path $pantherRoot "Unattend"
            New-Item -ItemType Directory -Path $pantherUnattendRoot -Force | Out-Null
            Copy-Item -LiteralPath $UnattendPath -Destination (Join-Path $pantherRoot "Unattend.xml") -Force
            Copy-Item -LiteralPath $UnattendPath -Destination (Join-Path $pantherUnattendRoot "Unattend.xml") -Force

            $commitArgs = @(
                "/Unmount-Wim",
                "/MountDir:$mountRoot",
                "/Commit"
            )
            & dism.exe @commitArgs | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "dism.exe failed to commit boot.wim index $index. Exit code: $LASTEXITCODE"
            }
            $mounted = $false
        }
    }
    finally {
        if ($mounted) {
            $discardArgs = @(
                "/Unmount-Wim",
                "/MountDir:$mountRoot",
                "/Discard"
            )
            & dism.exe @discardArgs | Out-Null
        }
        Remove-Item -LiteralPath $mountRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$WindowsIsoPath = Resolve-FullPath $WindowsIsoPath
$OutputIsoPath = Resolve-FullPath $OutputIsoPath
if ($ExtraFilesPath) {
    $ExtraFilesPath = Resolve-FullPath $ExtraFilesPath
    if (-not (Test-Path -LiteralPath $ExtraFilesPath)) {
        throw "Extra files path was not found: $ExtraFilesPath"
    }
}
try {
    $oscdimg = Find-Oscdimg -ExplicitPath $OscdimgPath
}
catch {
    if (-not $DownloadOscdimg) {
        throw
    }

    $oscdimg = Save-OscdimgOnly -DestinationPath $OscdimgOutputPath -CabUrls $OscdimgCabUrl
}

if (-not (Test-Path -LiteralPath $WindowsIsoPath)) {
    throw "Windows ISO was not found: $WindowsIsoPath"
}

New-Item -ItemType Directory -Path (Split-Path -Parent $OutputIsoPath) -Force | Out-Null
if (Test-Path -LiteralPath $OutputIsoPath) {
    Remove-Item -LiteralPath $OutputIsoPath -Force
}

$diskImage = $null
$stagingRoot = $null
try {
    $diskImage = Mount-DiskImage -ImagePath $WindowsIsoPath -PassThru
    Start-Sleep -Milliseconds 500
    $volume = $diskImage | Get-Volume
    if (-not $volume -or -not $volume.DriveLetter) {
        throw "Mounted ISO has no drive letter."
    }

    $sourceRoot = "$($volume.DriveLetter):\"
    $buildRoot = $sourceRoot

    if ($ExtraFilesPath) {
        $stagingRoot = Join-Path (Split-Path -Parent $OutputIsoPath) ("iso-staging-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

        Write-Host "Copying Windows ISO files to staging folder..."
        & robocopy.exe $sourceRoot $stagingRoot /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) {
            throw "robocopy.exe failed while staging Windows ISO files. Exit code: $LASTEXITCODE"
        }

        Write-Host "Adding extra unattended files to Windows ISO root..."
        & robocopy.exe $ExtraFilesPath $stagingRoot /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) {
            throw "robocopy.exe failed while adding extra files. Exit code: $LASTEXITCODE"
        }

        $autounattendPath = Join-Path $ExtraFilesPath "Autounattend.xml"
        if (Test-Path -LiteralPath $autounattendPath) {
            $sourcesRoot = Join-Path $stagingRoot "sources"
            New-Item -ItemType Directory -Path $sourcesRoot -Force | Out-Null
            Copy-Item -LiteralPath $autounattendPath -Destination (Join-Path $sourcesRoot "Autounattend.xml") -Force

            if (-not $SkipBootWimUnattendInjection) {
                Add-UnattendToBootWim -BootWimPath (Join-Path $sourcesRoot "boot.wim") -UnattendPath $autounattendPath -WorkRoot (Split-Path -Parent $OutputIsoPath)
            }
        }

        $buildRoot = $stagingRoot
    }

    $biosBoot = Join-Path $buildRoot "boot\etfsboot.com"
    $uefiNoPromptBoot = Join-Path $buildRoot "efi\microsoft\boot\efisys_noprompt.bin"
    $uefiPromptBoot = Join-Path $buildRoot "efi\microsoft\boot\efisys.bin"

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
        $buildRoot,
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
    if ($stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
