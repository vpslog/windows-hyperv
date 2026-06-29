[CmdletBinding()]
param(
    [string]$WindowsIsoPath = ".\win11.iso",
    [string]$SwitchName = "Default Switch"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [string]$Detail = ""
    )

    if ($Passed) {
        Write-Host "[OK]   $Name $Detail" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] $Name $Detail" -ForegroundColor Red
    }
}

function Ensure-ComIStreamFileWriter {
    if ("ComIStreamFileWriter" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class ComIStreamFileWriter
{
    public static void WriteToFile(object comStream, string path)
    {
        IntPtr unknown = IntPtr.Zero;
        IntPtr streamPointer = IntPtr.Zero;
        try
        {
            unknown = Marshal.GetIUnknownForObject(comStream);
            Guid iid = typeof(IStream).GUID;
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(unknown, ref iid, out streamPointer));
            IStream stream = (IStream)Marshal.GetTypedObjectForIUnknown(streamPointer, typeof(IStream));

            System.Runtime.InteropServices.ComTypes.STATSTG stat;
            stream.Stat(out stat, 1);
            long remaining = stat.cbSize;
            byte[] buffer = new byte[2048];
            IntPtr bytesReadPointer = Marshal.AllocHGlobal(sizeof(int));
            try
            {
                using (FileStream file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    while (remaining > 0)
                    {
                        int bytesToRead = (int)Math.Min(buffer.Length, remaining);
                        Marshal.WriteInt32(bytesReadPointer, 0);
                        stream.Read(buffer, bytesToRead, bytesReadPointer);
                        int bytesRead = Marshal.ReadInt32(bytesReadPointer);
                        if (bytesRead <= 0)
                        {
                            break;
                        }
                        file.Write(buffer, 0, bytesRead);
                        remaining -= bytesRead;
                    }
                }
            }
            finally
            {
                Marshal.FreeHGlobal(bytesReadPointer);
            }
        }
        finally
        {
            if (streamPointer != IntPtr.Zero)
            {
                Marshal.Release(streamPointer);
            }
            if (unknown != IntPtr.Zero)
            {
                Marshal.Release(unknown);
            }
        }
    }
}
'@
}

function New-TestIsoImageFromFolder {
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$DestinationIso
    )

    if (Test-Path -LiteralPath $DestinationIso) {
        Remove-Item -LiteralPath $DestinationIso -Force
    }

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 1
    $fsi.VolumeName = "TESTISO"
    $fsi.Root.AddTree($SourceFolder, $false)

    Ensure-ComIStreamFileWriter
    $result = $fsi.CreateResultImage()
    [ComIStreamFileWriter]::WriteToFile($result.ImageStream, $DestinationIso)
}

function Test-WindowsIsoContent {
    param([Parameter(Mandatory)][string]$ImagePath)

    $diskImage = $null
    $mountedHere = $false
    try {
        $diskImage = Mount-DiskImage -ImagePath $ImagePath -PassThru
        $mountedHere = $true
        Start-Sleep -Milliseconds 500
        $volume = $diskImage | Get-Volume
        if (-not $volume -or -not $volume.DriveLetter) {
            Write-CheckResult -Name "ISO mount drive letter" -Passed $false
            return $false
        }

        $driveRoot = "$($volume.DriveLetter):\"
        $uefiBoot = Join-Path $driveRoot "efi\boot\bootx64.efi"
        $biosBoot = Join-Path $driveRoot "boot\etfsboot.com"
        $wimPath = Join-Path $driveRoot "sources\install.wim"
        $esdPath = Join-Path $driveRoot "sources\install.esd"

        $hasUefiBoot = Test-Path -LiteralPath $uefiBoot
        $hasBiosBoot = Test-Path -LiteralPath $biosBoot
        $hasInstallImage = (Test-Path -LiteralPath $wimPath) -or (Test-Path -LiteralPath $esdPath)

        Write-CheckResult -Name "ISO UEFI boot file" -Passed $hasUefiBoot -Detail "efi\boot\bootx64.efi"
        Write-CheckResult -Name "ISO BIOS boot file" -Passed $hasBiosBoot -Detail "boot\etfsboot.com"
        Write-CheckResult -Name "ISO install image" -Passed $hasInstallImage -Detail "sources\install.wim/esd"

        if ($hasInstallImage) {
            $installImagePath = $wimPath
            if (-not (Test-Path -LiteralPath $installImagePath)) {
                $installImagePath = $esdPath
            }

            try {
                $images = Get-WindowsImage -ImagePath $installImagePath | Select-Object ImageIndex, ImageName
                Write-Host "Windows image indexes:" -ForegroundColor Cyan
                $images | Format-Table -AutoSize
            }
            catch {
                Write-CheckResult -Name "Read Windows image indexes" -Passed $false -Detail $_.Exception.Message
                return $false
            }
        }

        return ($hasUefiBoot -and $hasInstallImage)
    }
    catch {
        Write-CheckResult -Name "Inspect Windows ISO content" -Passed $false -Detail $_.Exception.Message
        return $false
    }
    finally {
        if ($mountedHere) {
            Dismount-DiskImage -ImagePath $ImagePath -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

$failed = $false
$WindowsIsoPath = Resolve-FullPath $WindowsIsoPath

$isAdmin = Test-Administrator
Write-CheckResult -Name "Administrator" -Passed $isAdmin
$failed = $failed -or (-not $isAdmin)

$isoExists = Test-Path -LiteralPath $WindowsIsoPath
Write-CheckResult -Name "Windows ISO" -Passed $isoExists -Detail $WindowsIsoPath
$failed = $failed -or (-not $isoExists)

if ($isoExists) {
    $isoContentOk = Test-WindowsIsoContent -ImagePath $WindowsIsoPath
    $failed = $failed -or (-not $isoContentOk)
}

$hasHyperV = [bool](Get-Command New-VM -ErrorAction SilentlyContinue)
Write-CheckResult -Name "Hyper-V PowerShell module" -Passed $hasHyperV
$failed = $failed -or (-not $hasHyperV)

$switchExists = $false
if ($hasHyperV) {
    $switchExists = [bool](Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)
}
Write-CheckResult -Name "Hyper-V virtual switch" -Passed $switchExists -Detail $SwitchName
$failed = $failed -or (-not $switchExists)

$imapiOk = $false
$tempRoot = Join-Path $env:TEMP ("win11-hyperv-prereq-" + [guid]::NewGuid().ToString("N"))
$testIso = Join-Path $tempRoot "test.iso"
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tempRoot "hello.txt") -Value "iso test" -Encoding ASCII
    New-TestIsoImageFromFolder -SourceFolder $tempRoot -DestinationIso $testIso
    $imapiOk = (Test-Path -LiteralPath $testIso) -and ((Get-Item -LiteralPath $testIso).Length -gt 0)
    Write-CheckResult -Name "Answer ISO generation" -Passed $imapiOk
}
catch {
    Write-CheckResult -Name "Answer ISO generation" -Passed $false -Detail $_.Exception.Message
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$failed = $failed -or (-not $imapiOk)

if ($failed) {
    throw "Prerequisite check failed. Fix the FAIL items above first."
}

Write-Host "Prerequisite check passed. You can run .\scripts\New-Win11HyperV.ps1." -ForegroundColor Green
