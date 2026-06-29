[CmdletBinding()]
param(
    [string]$VmName = "Win11-Auto",
    [string]$WindowsIsoPath = ".\win11.iso",
    [string]$SwitchName = "Default Switch",
    [string]$VmRoot = ".\out\vms",
    [string]$AnswerIsoPath = ".\out\answer.iso",
    [int64]$MemoryStartupBytes = 4GB,
    [int]$ProcessorCount = 4,
    [int64]$VhdSizeBytes = 80GB,
    [int]$ImageIndex = 6,
    [string]$ProductKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T",
    [string]$AdminUser = "admin",
    [string]$AdminPassword = "admin",
    [string]$WindowsLanguage = "zh-CN",
    [string]$InputLocale = "zh-CN",
    [string]$SystemLocale = "zh-CN",
    [string]$UserLocale = "zh-CN",
    [string]$TimeZone = "China Standard Time",
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

function New-IsoImageFromFolder {
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$DestinationIso,
        [string]$VolumeName = "AUTOUNATTEND"
    )

    if (Test-Path -LiteralPath $DestinationIso) {
        Remove-Item -LiteralPath $DestinationIso -Force
    }

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 1
    $fsi.VolumeName = $VolumeName
    $fsi.Root.AddTree($SourceFolder, $false)

    Ensure-ComIStreamFileWriter
    $result = $fsi.CreateResultImage()
    [ComIStreamFileWriter]::WriteToFile($result.ImageStream, $DestinationIso)
}

function ConvertTo-UnattendPlainText {
    param([Parameter(Mandatory)][string]$Value)
    [Security.SecurityElement]::Escape($Value)
}

Assert-Administrator

$WindowsIsoPath = Resolve-FullPath $WindowsIsoPath
$VmRoot = Resolve-FullPath $VmRoot
$AnswerIsoPath = Resolve-FullPath $AnswerIsoPath
$answerRoot = Join-Path (Split-Path -Parent $AnswerIsoPath) "answer-files"
$vmPath = Join-Path $VmRoot $VmName
$vhdPath = Join-Path $vmPath "$VmName.vhdx"
$escapedUser = ConvertTo-UnattendPlainText $AdminUser
$escapedPassword = ConvertTo-UnattendPlainText $AdminPassword

if (-not (Test-Path -LiteralPath $WindowsIsoPath)) {
    throw "Windows ISO was not found: $WindowsIsoPath"
}

if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw "Hyper-V PowerShell module is not available. Enable Hyper-V and the management tools first."
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V switch '$SwitchName' was not found. Use -SwitchName with an existing switch."
}

if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
    throw "A VM named '$VmName' already exists. Remove it or pass a different -VmName."
}

New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
New-Item -ItemType Directory -Path $answerRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $answerRoot "init") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $answerRoot '$OEM$\$$\Setup\Scripts') -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $PSScriptRoot "templates\firstlogon.ps1") -Destination (Join-Path $answerRoot "init\firstlogon.ps1") -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "templates\firstlogon.ps1") -Destination (Join-Path $answerRoot '$OEM$\$$\Setup\Scripts\setupcomplete.ps1') -Force
Set-Content -LiteralPath (Join-Path $answerRoot '$OEM$\$$\Setup\Scripts\SetupComplete.cmd') -Encoding ASCII -Value @(
    '@echo off',
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\setupcomplete.ps1"',
    'exit /b 0'
)

$autounattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SetupUILanguage>
        <UILanguage>$WindowsLanguage</UILanguage>
      </SetupUILanguage>
      <InputLocale>$InputLocale</InputLocale>
      <SystemLocale>$SystemLocale</SystemLocale>
      <UILanguage>$WindowsLanguage</UILanguage>
      <UserLocale>$UserLocale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>100</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>16</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>FAT32</Format>
              <Label>System</Label>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>3</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
              <Letter>C</Letter>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
        <WillShowUI>OnError</WillShowUI>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/INDEX</Key>
              <Value>$ImageIndex</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <ProductKey>
          <Key>$ProductKey</Key>
          <WillShowUI>Never</WillShowUI>
        </ProductKey>
        <AcceptEula>true</AcceptEula>
        <FullName>$escapedUser</FullName>
        <Organization>Lab</Organization>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>*</ComputerName>
      <TimeZone>$TimeZone</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>$InputLocale</InputLocale>
      <SystemLocale>$SystemLocale</SystemLocale>
      <UILanguage>$WindowsLanguage</UILanguage>
      <UserLocale>$UserLocale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Private</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$escapedUser</Name>
            <DisplayName>$escapedUser</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>$escapedPassword</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$escapedUser</Username>
        <LogonCount>3</LogonCount>
        <Password>
          <Value>$escapedPassword</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
    </component>
  </settings>
</unattend>
"@

$autounattendPath = Join-Path $answerRoot "Autounattend.xml"
Set-Content -LiteralPath $autounattendPath -Value $autounattend -Encoding UTF8
[xml](Get-Content -LiteralPath $autounattendPath -Raw) | Out-Null
New-IsoImageFromFolder -SourceFolder $answerRoot -DestinationIso $AnswerIsoPath

if ($UseNoPromptIso) {
    $noPromptIsoPath = Join-Path (Split-Path -Parent $AnswerIsoPath) "win11-noprompt.iso"
    $noPromptScript = Join-Path $PSScriptRoot "New-NoPromptWindowsIso.ps1"
    if (-not (Test-Path -LiteralPath $noPromptScript)) {
        throw "No-prompt ISO script was not found: $noPromptScript"
    }

    $noPromptArgs = @{
        WindowsIsoPath = $WindowsIsoPath
        OutputIsoPath = $noPromptIsoPath
        ExtraFilesPath = $answerRoot
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

New-VHD -Path $vhdPath -SizeBytes $VhdSizeBytes -Dynamic | Out-Null
New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -VHDPath $vhdPath -Path $vmPath -SwitchName $SwitchName | Out-Null
Set-VM -Name $VmName -ProcessorCount $ProcessorCount -CheckpointType Disabled -AutomaticCheckpointsEnabled $false
Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $true -MinimumBytes 2GB -StartupBytes $MemoryStartupBytes -MaximumBytes 8GB
if ($DisableSecureBoot) {
    Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
}
else {
    Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate "MicrosoftWindows"
}

try {
    Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
    Enable-VMTPM -VMName $VmName
}
catch {
    Write-Warning "Could not enable vTPM: $($_.Exception.Message)"
}

$windowsDvd = Add-VMDvdDrive -VMName $VmName -Path $WindowsIsoPath -Passthru
$answerDvd = Add-VMDvdDrive -VMName $VmName -Path $AnswerIsoPath -Passthru
Set-VMFirmware -VMName $VmName -FirstBootDevice $windowsDvd

Write-Host "Created VM: $VmName"
Write-Host "Windows ISO: $WindowsIsoPath"
Write-Host "Answer ISO: $AnswerIsoPath"
Write-Host "Starting VM..."
Start-VM -Name $VmName
