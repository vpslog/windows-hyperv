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
.\scripts\New-Win11HyperV.ps1
```

如果 ISO 不在当前目录，可以手动指定路径：

```powershell
.\scripts\New-Win11HyperV.ps1 -WindowsIsoPath "D:\iso\Win11.iso"
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
- `admin/admin` 是为了本地实验环境方便使用而设置的弱密码。不要把该虚拟机直接暴露到不可信网络中。
- 不同版本的 Windows 11 安装流程可能略有差异。如果安装暂停，请打开虚拟机控制台，检查是否在询问磁盘、网络或系统版本选择。
