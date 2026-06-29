# Windows 11 Hyper-V 无人值守虚拟机

本目录包含一套脚本，用于在 Hyper-V 中创建 Windows 11 虚拟机，并通过无人值守应答文件自动完成安装。

默认配置：

- 虚拟机名称：`Win11-Auto`
- Windows ISO：`.\win11.iso`
- 本地用户名：`admin`
- 本地用户密码：`admin`
- 自动登录：启用，登录用户为 `admin`

请用管理员权限打开 PowerShell，然后运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Test-Win11HyperVPrereq.ps1
.\scripts\New-Win11HyperV.ps1
```

如果 ISO 不在当前目录，可以手动指定路径：

```powershell
.\scripts\New-Win11HyperV.ps1 -WindowsIsoPath "D:\iso\Win11.iso"
```

如果虚拟机已经创建失败，需要先删除旧虚拟机，或换一个新的 `-VmName`：

```powershell
Stop-VM -Name Win11-Auto -TurnOff -ErrorAction SilentlyContinue
Remove-VM -Name Win11-Auto -Force
```

如果 Hyper-V UEFI 页面显示 `The boot loader failed`，先运行预检：

```powershell
.\scripts\Test-Win11HyperVPrereq.ps1 -WindowsIsoPath ".\win11.iso"
```

重点看这几项：

- `ISO UEFI boot file` 必须为 `[OK]`，否则这个 ISO 不能作为第 2 代 UEFI 虚拟机启动盘。
- `ISO install image` 必须为 `[OK]`，否则它不是标准 Windows 安装 ISO。
- 如果上面都通过，但仍然启动失败，可能是 ISO 的启动文件不能通过安全启动校验，可以关闭 Secure Boot 重试：

```powershell
.\scripts\New-Win11HyperV.ps1 -DisableSecureBoot
```

如果虚拟机已经存在，也可以直接修复现有 VM 的启动设置并关闭 Secure Boot：

```powershell
.\scripts\Repair-Win11HyperVBoot.ps1 -VmName Win11-Auto -WindowsIsoPath ".\win11.iso" -DisableSecureBoot
```

如果仍然是 `The boot loader failed`，很可能是 Hyper-V Gen2 没接到 Windows ISO 的 `Press any key to boot from CD or DVD...`。这会影响无人值守启动。可以生成一个 no-prompt ISO：

```powershell
.\scripts\New-NoPromptWindowsIso.ps1 -WindowsIsoPath ".\win11.iso" -OutputIsoPath ".\out\win11-noprompt.iso" -ExtraFilesPath ".\out\answer-files"
.\scripts\Repair-Win11HyperVBoot.ps1 -VmName Win11-Auto -WindowsIsoPath ".\out\win11-noprompt.iso" -DisableSecureBoot
```

也可以让修复脚本自动生成并挂载 no-prompt ISO：

```powershell
.\scripts\Repair-Win11HyperVBoot.ps1 -VmName Win11-Auto -WindowsIsoPath ".\win11.iso" -UseNoPromptIso -DisableSecureBoot
```

从头创建 VM 时也可以直接使用 no-prompt ISO：

```powershell
.\scripts\New-Win11HyperV.ps1 -UseNoPromptIso
```

使用 `New-Win11HyperV.ps1 -UseNoPromptIso` 时，脚本会先生成 `Autounattend.xml`，再把它和 `init\firstlogon.ps1` 直接合进 Windows 安装 ISO 根目录。这样 Windows Setup 一启动就能读取无人值守文件，不会停在语言选择页面。

脚本会自动查找常见位置里的 `oscdimg.exe`，包括 `C:\ADK` 和 Windows Kits 目录。如果已经安装过 ADK Deployment Tools，通常不需要指定路径。

如果脚本找不到，但你知道 `oscdimg.exe` 的位置，可以手动传入：

```powershell
.\scripts\New-Win11HyperV.ps1 -UseNoPromptIso -OscdimgPath "C:\ADK\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
```

如果没有 `oscdimg.exe`，也可以让脚本只下载/提取这个工具文件到 `out\tools\oscdimg.exe`，不安装 ADK：

```powershell
.\scripts\New-Win11HyperV.ps1 -UseNoPromptIso -DownloadOscdimg
```

修复现有 VM 时也可以指定：

```powershell
.\scripts\Repair-Win11HyperVBoot.ps1 -VmName Win11-Auto -WindowsIsoPath ".\win11.iso" -UseNoPromptIso -OscdimgPath "C:\ADK\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
```

如果安装过程停在系统版本选择页面，可以先查看 ISO 内的镜像索引，再指定正确的索引重新运行：

```powershell
.\scripts\Get-WindowsIsoImageIndex.ps1 -WindowsIsoPath ".\win11.iso"
.\scripts\New-Win11HyperV.ps1 -ImageIndex 6
```

脚本会创建：

- 第 2 代 Hyper-V 虚拟机，并启用安全启动和 vTPM。
- 一个动态扩展的 VHDX 虚拟硬盘。
- `out\answer.iso`，其中包含 `Autounattend.xml` 和 `init\firstlogon.ps1`。

Windows 安装完成后，虚拟机应自动以 `admin` 用户登录，密码为 `admin`。

注意事项：

- 脚本默认使用 Hyper-V 的 `Default Switch`。如需使用其他虚拟交换机，请传入 `-SwitchName`。
- `Test-Win11HyperVPrereq.ps1` 只做预检，不会创建虚拟机。它会检查管理员权限、Hyper-V PowerShell 模块、Windows ISO、虚拟交换机，以及当前系统是否能生成无人值守 ISO。
- `admin/admin` 是为了本地实验环境方便使用而设置的弱密码。不要把该虚拟机直接暴露到不可信网络中。
- 不同版本的 Windows 11 安装流程可能略有差异。如果安装暂停，请打开虚拟机控制台，检查是否在询问磁盘、网络或系统版本选择。
