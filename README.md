# pve-windows-prep

Prepares Windows VMs **before** they are migrated to Proxmox VE (e.g. from VMware), so they boot
straight from a **VirtIO SCSI** disk and have the **QEMU guest agent** ready. You no longer need the
old routine of adding a temporary 1 GB SCSI disk, booting once from IDE/SATA and switching the boot disk.

It runs on one machine with a wizard, or on many machines with a PowerShell one-liner.

## Quick start

From an **elevated PowerShell** on the Windows machine:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/YOUR-GITHUB-USER/pve-windows-prep/main/install.ps1)))
```

That runs every step unattended. The first part enables TLS 1.2, which older Windows PowerShell 5.1 needs to reach GitHub. Other variations:

```powershell
# Pick the steps in a wizard
... install.ps1))) -Wizard

# Only some steps, prepare both VirtIO SCSI and VirtIO Block
... install.ps1))) -Steps Drivers,BootDriver,Verify -Driver both

# Production: pin a release (use the same tag in the URL and in -Ref)
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/YOUR-GITHUB-USER/pve-windows-prep/v1.4.0/install.ps1))) -Ref v1.4.0
```

**Without the one-liner:** download the repository (Code → Download ZIP), extract it and
double-click `Run-PVEPrep.cmd`, which opens the wizard.

## What it does

| Step (`-Steps` name) | What it does |
|---|---|
| **Save network configuration** (`Network`) | Saves IP/DNS/route settings to the log folder. The NIC becomes a new VirtIO adapter after migration, so static IPs have to be re-applied from this file. |
| **Install VirtIO drivers** (`Drivers`) | Silent install of `virtio-win-gt-x64.msi`, then makes sure every driver package is in the Windows driver store (`pnputil /add-driver`). Windows then installs the drivers automatically when the VirtIO devices appear on Proxmox. |
| **Install QEMU guest agent** (`GuestAgent`) | Silent install of `qemu-ga-x86_64.msi`. The service connects once the VM runs on Proxmox. |
| **Make VirtIO storage driver load at boot** (`BootDriver`) | Runs `load-virtio-scsi-on-boot.ps1` so `vioscsi` (and/or `viostor`) is a boot-start driver even though the device doesn't exist yet. It also removes a `StartOverride` if Windows has disabled the driver. |
| **Verify migration readiness** (`Verify`) | Read-only check: `vioscsi` has `Start=0` and its `.sys` file is present, netkvm is in the driver store, and the QEMU-GA service is set to Auto. |

Every step is idempotent: things that are already installed or configured are skipped, so the tool
can run again at any time.

**Requirements:** x64 Windows 10 1511 / Windows Server 2016 or newer (the limit of virtio-win 0.1.271), and administrator or SYSTEM rights.

## Parameters

The same options work on the one-liner (`install.ps1`) and on `Prepare-PVEMigration.ps1`.

| Parameter | Default | Meaning |
|---|---|---|
| `-Wizard` | – | Interactive wizard: GUI on desktop Windows, Y/N prompts on Server Core |
| `-Steps <list>` | all | `Network,Drivers,GuestAgent,BootDriver,Verify` |
| `-Driver scsi\|block\|both` | `scsi` | VirtIO SCSI (`vioscsi`), VirtIO Block (`viostor`) or both |
| `-LogPath <folder>` | `%ProgramData%\PVE-Prep\Logs` | Transcript, MSI logs, network snapshot. Can be a UNC share. |
| `-Force` | – | Re-run the boot driver script even if the driver is already boot-start |

`install.ps1` only:

| Parameter | Default | Meaning |
|---|---|---|
| `-Ref <branch\|tag>` | `main` | What to download. Use a release tag in production. |
| `-Repo <owner/name>` | `YOUR-GITHUB-USER/pve-windows-prep` | GitHub repository |
| `-BaseUrl <url>` | GitHub raw URL | Any other web location with the same layout (GitLab raw URL, internal web server) |
| `-PackageSource <folder>` | – | Take the `.msi` files from a local/UNC folder instead of downloading them. They are still hash-checked. |
| `-InstallPath <folder>` | `%ProgramData%\PVE-Prep\app` | Where the tool is saved (one subfolder per version) |
| `-DownloadOnly` | – | Download and verify only |

**Exit codes** (`$LASTEXITCODE` after the one-liner):

| Code | Meaning |
|---|---|
| `0` | Ready |
| `3010` | Ready, an installer requested a reboot (not needed for migration) |
| `1` | A step failed |
| `2` | Pre-flight or parameter error |
| `10` | Download or hash check failed |
| `1602` | Cancelled in the wizard |

## Running on many machines

**PowerShell remoting** (WinRM is on by default on domain-joined Windows Server). The servers need HTTPS access to GitHub:

```powershell
$servers = Get-Content .\servers.txt      # or: (Get-ADComputer -SearchBase 'OU=...' -Filter *).Name
$prep = {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/YOUR-GITHUB-USER/pve-windows-prep/v1.4.0/install.ps1))) -Ref v1.4.0
    [pscustomobject]@{ ExitCode = $LASTEXITCODE }
}
Invoke-Command -ComputerName $servers -ScriptBlock $prep -ThrottleLimit 32 |
    Select-Object PSComputerName, ExitCode | Sort-Object ExitCode | Format-Table
```

Logs stay on each server under `%ProgramData%\PVE-Prep\Logs`. A `-LogPath` on a file share hits the Kerberos "second hop" problem from a remote session, unless the share grants access to the computer accounts.

**RMM agent / scheduled task / GPO (runs as SYSTEM):**

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/YOUR-GITHUB-USER/pve-windows-prep/v1.4.0/install.ps1))) -Ref v1.4.0; exit $LASTEXITCODE"
```

For a GPO, use a Group Policy Preferences **Immediate Task** running as `NT AUTHORITY\SYSTEM` with "Apply once and do not reapply", targeted at a security group. Servers without internet access can add `-PackageSource \\domain\NETLOGON\pve-prep` for the MSIs, or run `Prepare-PVEMigration.ps1` directly from a share.

**Which machines are ready?** Every run leaves its result in `HKLM\SOFTWARE\PVE-Prep`:

```powershell
Invoke-Command -ComputerName $servers {
    Get-ItemProperty HKLM:\SOFTWARE\PVE-Prep -ErrorAction SilentlyContinue
} | Select-Object PSComputerName, Result, FailedSteps, Version, LastRun | Format-Table
```

`Result` is `Ready`, `ReadyRebootRequested`, `NotReady` or `CompletedNotVerified` (the steps ran but Verify wasn't selected).

## After migration (Proxmox VE VM settings)

- Hard disk bus: **SCSI**, SCSI controller: **VirtIO SCSI single** (or VirtIO Block if prepared with `-Driver block/both`)
- Network: **VirtIO (paravirtualized)**. Re-apply static IPs from `network-config_*.txt` in the log folder.
- Options → **QEMU Guest Agent: Enabled** (adds the virtio-serial channel the agent needs)
- Domain controllers: keep the VM Generation ID (`vmgenid`) enabled.
- Remove VMware Tools / Hyper-V integration leftovers as usual.

The Proxmox VE ESXi import (8.2+) can import directly from ESXi/vCenter and lets you choose these settings in the import dialog.

## Maintaining the repository

| Path | Purpose |
|---|---|
| `install.ps1` | Bootstrapper used by the one-liner |
| `manifest.json` | Tool version, scripts to download, installers with their SHA-256 |
| `Prepare-PVEMigration.ps1` | The tool (wizard, steps, logging, status marker) |
| `load-virtio-scsi-on-boot.ps1` | Registers the VirtIO storage driver as boot-start |
| `Run-PVEPrep.cmd` | Double-click launcher (opens the wizard) |
| `packages/` | `virtio-win-gt-x64.msi`, `qemu-ga-x86_64.msi`, virtio-win license |
| `tools/Update-Manifest.ps1` | Refreshes `manifest.json` (version, hashes, MSI versions) |

**Releasing a change:**

1. Change the scripts and bump `$ScriptVersion` in `Prepare-PVEMigration.ps1`.
2. For a new driver or agent version, replace the file in `packages/` and keep the file name.
3. Run `.\tools\Update-Manifest.ps1` on Windows, so the MSI versions are read too.
4. Commit, push and create a tag/release `vX.Y.Z`.
5. Point production one-liners at the new tag.

`raw.githubusercontent.com` caches branch content for a few minutes, so a push to `main` may take a moment to show up. Tags don't have this delay.

**Security:** whoever can push to this repository can run code as SYSTEM on every machine that uses the one-liner on `main`. Use release tags for production, protect the default branch and require 2FA. The installer hashes protect against corrupted downloads and a tampered `-PackageSource` share, but not against a compromised repository, since the hashes live in it too.

## Licenses

See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for the bundled VirtIO drivers and QEMU guest agent.
