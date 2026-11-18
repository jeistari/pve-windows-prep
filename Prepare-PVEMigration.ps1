<#
.SYNOPSIS
    Prepares a Windows machine for migration to Proxmox VE (VirtIO SCSI boot disk + QEMU guest agent).

.DESCRIPTION
    Selectable steps (run in this order):
      Network     Record the current network configuration (static IPs are lost when the NIC
                  becomes a VirtIO adapter)
      Drivers     Install the VirtIO drivers                (virtio-win-gt-x64*.msi) and make sure
                  every driver package is in the Windows driver store
      GuestAgent  Install the QEMU guest agent              (qemu-ga-x86_64*.msi)
      BootDriver  Run load-virtio-scsi-on-boot.ps1 so vioscsi (and/or viostor) is a boot-start
                  driver - no temporary 1 GB SCSI disk / IDE-SATA first boot needed on Proxmox VE
      Verify      Check that the machine is ready for migration

    Use -Wizard for an interactive wizard where each step can be ticked on or off
    (GUI on desktop Windows, text prompts on Server Core / when no GUI is available).
    Without -Wizard all steps run, or only those given with -Steps.

    The script is idempotent: components that are already installed/configured are skipped.

    Exit codes:
      0     Success - ready for migration
      3010  Success - an installer asked for a reboot (not required for the migration itself)
      1     One or more steps failed (see log)
      2     Pre-flight check failed (unsupported OS, missing files, not elevated, bad parameter)
      1602  Cancelled in the wizard

.PARAMETER Wizard
    Show the interactive wizard to choose steps and options.

.PARAMETER Steps
    Steps to run (comma separated): Network, Drivers, GuestAgent, BootDriver, Verify. Default: all.

.PARAMETER Driver
    Which boot driver(s) to prepare: scsi (default, VirtIO SCSI), block (VirtIO Block) or both.

.PARAMETER PackagePath
    Folder containing the MSIs and load-virtio-scsi-on-boot.ps1. Defaults to the folder this
    script is in.

.PARAMETER LogPath
    Folder for the transcript, MSI logs and network snapshot. Default: %ProgramData%\PVE-Prep\Logs

.PARAMETER SkipGuestAgent
    Same as leaving GuestAgent out of -Steps (kept for compatibility).

.PARAMETER Force
    Run load-virtio-scsi-on-boot.ps1 even if the boot driver already appears to be configured.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Prepare-PVEMigration.ps1 -Wizard

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Prepare-PVEMigration.ps1 -Steps Drivers,BootDriver,Verify -Driver both
#>
[CmdletBinding()]
param(
    [switch]$Wizard,

    [string[]]$Steps = @('Network', 'Drivers', 'GuestAgent', 'BootDriver', 'Verify'),

    [ValidateSet('scsi', 'block', 'both')]
    [string]$Driver = 'scsi',

    [string]$PackagePath = '',

    [string]$LogPath = (Join-Path $env:ProgramData 'PVE-Prep\Logs'),

    [switch]$SkipGuestAgent,

    [switch]$Force,

    # Keep the window open at the end (used by the launcher and the elevated re-launch).
    [switch]$PauseAtEnd
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.4.0'   # bump on every change - printed in the console, log and wizard

# --------------------------------------------------------------------------------------------
# Self-relaunch helpers (64-bit host, elevation)
# --------------------------------------------------------------------------------------------
function Get-ForwardedArguments {
    param([hashtable]$Bound, [switch]$AddPause)
    $list = @()
    foreach ($key in $Bound.Keys) {
        $val = $Bound[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $list += "-$key" }
        } elseif ($val -is [array]) {
            $list += "-$key"
            $list += ($val -join ',')
        } else {
            $list += "-$key"
            $list += "$val"
        }
    }
    if ($AddPause -and -not $Bound.ContainsKey('PauseAtEnd')) { $list += '-PauseAtEnd' }
    return , $list
}

# Package folder: resolved here rather than as a param() default, because $PSScriptRoot can be
# empty in a param() default under Windows PowerShell 5.1 (e.g. after the elevated re-launch).
if (-not $PackagePath) {
    if ($PSScriptRoot) { $PackagePath = $PSScriptRoot }
    elseif ($PSCommandPath) { $PackagePath = Split-Path -Parent $PSCommandPath }
    elseif ($MyInvocation.MyCommand.Path) { $PackagePath = Split-Path -Parent $MyInvocation.MyCommand.Path }
}
if (-not $PackagePath -or -not (Test-Path -LiteralPath $PackagePath -PathType Container)) {
    Write-Host "Package folder not found: '$PackagePath'. Use -PackagePath <folder>." -ForegroundColor Red
    exit 2
}
$PackagePath = (Get-Item -LiteralPath $PackagePath).FullName
# Pass the resolved folder on to any re-launched (64-bit / elevated) instance.
$PSBoundParameters['PackagePath'] = $PackagePath

# 1) A 32-bit host (e.g. some deployment agents) would see redirected registry/System32 paths
#    and break driver installation - re-launch in 64-bit PowerShell.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:windir 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    Write-Host "32-bit PowerShell detected - re-launching in 64-bit PowerShell..." -ForegroundColor Yellow
    $fwd = Get-ForwardedArguments -Bound $PSBoundParameters
    & $ps64 -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath @fwd
    exit $LASTEXITCODE
}

# 2) Elevation
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ([Environment]::UserInteractive) {
        Write-Host "Administrator rights required - requesting elevation..." -ForegroundColor Yellow
        $fwd = Get-ForwardedArguments -Bound $PSBoundParameters -AddPause
        $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        foreach ($a in $fwd) {
            # A trailing backslash would escape the closing quote ("E:\" -> E:\")
            if ($a -like '-*') { $argList += $a } elseif ($a.EndsWith('\')) { $argList += "`"$a\`"" } else { $argList += "`"$a`"" }
        }
        try {
            $p = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argList -Verb RunAs -PassThru -Wait
            exit $p.ExitCode
        } catch {
            Write-Host "Elevation was cancelled or failed: $($_.Exception.Message)" -ForegroundColor Red
            exit 2
        }
    }
    Write-Host "This script must be run as Administrator (or SYSTEM)." -ForegroundColor Red
    exit 2
}

# --------------------------------------------------------------------------------------------
# Step definitions and parameter normalisation
# --------------------------------------------------------------------------------------------
$StepOrder = @('Network', 'Drivers', 'GuestAgent', 'BootDriver', 'Verify')
$StepTitles = @{
    Network    = 'Save network configuration'
    Drivers    = 'Install VirtIO drivers'
    GuestAgent = 'Install QEMU guest agent'
    BootDriver = 'Make VirtIO storage driver load at boot'
    Verify     = 'Verify migration readiness'
}
$StepDescriptions = @{
    Network    = 'Saves IP/DNS/route settings so static IPs can be re-applied to the VirtIO NIC after migration.'
    Drivers    = 'Installs the VirtIO drivers and adds them to the driver store so Windows uses them on PVE.'
    GuestAgent = 'Installs the QEMU guest agent service; it connects once the VM runs on Proxmox VE.'
    BootDriver = 'Runs load-virtio-scsi-on-boot.ps1 so Windows can boot directly from a VirtIO disk.'
    Verify     = 'Checks boot driver, guest agent and VirtIO network driver; makes no changes.'
}

# -Steps arrives as one comma-separated string when called with powershell.exe -File
$requested = @()
foreach ($s in $Steps) {
    foreach ($part in ($s -split '[,; ]')) {
        $part = $part.Trim()
        if (-not $part) { continue }
        $match = $StepOrder | Where-Object { $_ -eq $part }
        if (-not $match) {
            Write-Host "Unknown step '$part'. Valid steps: $($StepOrder -join ', ')" -ForegroundColor Red
            exit 2
        }
        if ($requested -notcontains $match) { $requested += $match }
    }
}
if ($SkipGuestAgent) { $requested = @($requested | Where-Object { $_ -ne 'GuestAgent' }) }
$Selected = @($StepOrder | Where-Object { $requested -contains $_ })


$computer = $env:COMPUTERNAME
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$transcript = $null
$transcriptStarted = $false
$script:UiMode = 'Console'      # Console | Gui
$script:Results = New-Object System.Collections.ArrayList
$script:RebootRequired = $false
$script:Failed = $false
$script:DriverInstallFailed = $false
$script:StepNo = 0

# --------------------------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------------------------
function Write-Step  { param([string]$Text) $script:StepNo++; Write-Host ""; Write-Host "=== $($script:StepNo). $Text ===" -ForegroundColor Cyan }
function Write-Info  { param([string]$Text) Write-Host "  $Text" }
function Write-Ok    { param([string]$Text) Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn  { param([string]$Text) Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Fail  { param([string]$Text) Write-Host "  [FAIL] $Text" -ForegroundColor Red }

function Add-Result {
    param([string]$Step, [ValidateSet('OK', 'SKIPPED', 'WARNING', 'FAILED')][string]$Status, [string]$Detail = '')
    [void]$script:Results.Add([PSCustomObject]@{ Step = $Step; Status = $Status; Detail = $Detail })
    if ($Status -eq 'FAILED') { $script:Failed = $true }
}

# --------------------------------------------------------------------------------------------
# Package / system state helpers
# --------------------------------------------------------------------------------------------
function Find-PackageFile {
    param([string]$Pattern, [string]$Description)
    # Looks in the package folder and its packages\ subfolder (repository layout).
    $folders = @($PackagePath, (Join-Path $PackagePath 'packages'))
    $files = @(foreach ($folder in $folders) {
                   if (Test-Path -LiteralPath $folder -PathType Container) {
                       Get-ChildItem -LiteralPath $folder -Filter $Pattern -File -ErrorAction SilentlyContinue
                   }
               }) | Sort-Object LastWriteTime -Descending
    $files = @($files)
    if ($files.Count -eq 0) { return $null }
    if ($files.Count -gt 1) {
        Write-Warn "Several $Description files found - using the newest: $($files[0].Name)"
    }
    return $files[0].FullName
}

function Get-MsiProperty {
    param([string]$Path, [string]$Property)
    if (-not $Path) { return $null }
    $installer = $null; $db = $null; $view = $null; $value = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Property'"))
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($rec) { $value = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) }
        [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
    } catch {
        $value = $null
    } finally {
        foreach ($o in @($view, $db, $installer)) {
            if ($o) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }
        }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
    return $value
}

function Get-MsiVersion {
    param([string]$Path)
    $v = $null
    $raw = Get-MsiProperty -Path $Path -Property 'ProductVersion'
    if ($raw) { [void][version]::TryParse($raw, [ref]$v) }
    return $v
}

function Get-InstalledProductVersion {
    param([string]$DisplayName)
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $found = @()
    foreach ($k in $keys) {
        $found += @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq $DisplayName })
    }
    $best = $null
    foreach ($f in $found) {
        if (-not $f.PSObject.Properties['DisplayVersion']) { continue }
        $v = $null
        if ([version]::TryParse([string]$f.DisplayVersion, [ref]$v)) {
            if (-not $best -or $v -gt $best) { $best = $v }
        }
    }
    return $best
}

function Test-DriverInStore {
    # A package in the driver store lives in FileRepository\<inf>_<arch>_<hash>\<inf>.
    # (The DriverDatabase registry key is only a fallback: not every package is visible there
    #  to an administrator, which made netkvm.inf look missing on Server 2022.)
    param([string]$InfName)
    $repo = Join-Path $env:windir 'System32\DriverStore\FileRepository'
    $dirs = @(Get-ChildItem -LiteralPath $repo -Directory -Filter "$($InfName)_*" -ErrorAction SilentlyContinue)
    foreach ($d in $dirs) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName $InfName)) { return $true }
    }
    $pkgs = @(Get-ChildItem 'HKLM:\SYSTEM\DriverDatabase\DriverPackages' -ErrorAction SilentlyContinue |
              Where-Object { $_.PSChildName -like "$($InfName)_*" })
    return ($pkgs.Count -gt 0)
}

function Get-BootDriverState {
    param([string]$Service)
    $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$Service"
    $state = [PSCustomObject]@{ Exists = $false; Start = $null; BootStart = $false; Overrides = @(); ImagePresent = $false; Ready = $false }
    if (-not (Test-Path $svcKey)) { return $state }
    $state.Exists = $true
    $props = Get-ItemProperty -Path $svcKey
    if ($props.PSObject.Properties['Start']) { $state.Start = [int]$props.Start }
    $state.BootStart = ($state.Start -eq 0)
    $ovKey = Join-Path $svcKey 'StartOverride'
    if (Test-Path $ovKey) {
        $ov = Get-ItemProperty -Path $ovKey
        foreach ($p in $ov.PSObject.Properties) {
            if ($p.Name -notlike 'PS*' -and $p.Value -ne 0) { $state.Overrides += "$($p.Name)=$($p.Value)" }
        }
    }
    $state.ImagePresent = Test-Path (Join-Path $env:windir "System32\drivers\$Service.sys")
    $state.Ready = ($state.Exists -and $state.BootStart -and $state.ImagePresent -and $state.Overrides.Count -eq 0)
    return $state
}

function Get-ServicesForDriver {
    param([string]$Choice)
    switch ($Choice) {
        'scsi'  { return , @('vioscsi') }
        'block' { return , @('viostor') }
        default { return , @('vioscsi', 'viostor') }
    }
}

function Invoke-MsiInstall {
    param([string]$MsiPath, [string]$LogName)
    $msiLog = Join-Path $LogPath $LogName
    $arguments = "/i `"$MsiPath`" /qn /norestart /l*v `"$msiLog`""
    $maxAttempts = 10
    $code = -1
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Info "msiexec.exe $arguments"
        $p = Start-Process -FilePath (Join-Path $env:windir 'System32\msiexec.exe') -ArgumentList $arguments -PassThru -WindowStyle Hidden
        [void]$p.Handle   # cache handle so ExitCode is available after exit
        $p.WaitForExit()
        $code = $p.ExitCode
        if ($code -eq 1618 -and $attempt -lt $maxAttempts) {
            Write-Warn "Another installation is in progress (1618) - waiting 30 s (attempt $attempt/$maxAttempts)..."
            Start-Sleep -Seconds 30
            continue
        }
        return $code
    }
    return $code
}

function Install-MsiPackage {
    param([string]$Name, [string]$MsiPath, [string]$DisplayName, [string]$LogName)

    $msiVersion = Get-MsiVersion -Path $MsiPath
    $installed = Get-InstalledProductVersion -DisplayName $DisplayName

    Write-Info "Package:   $(Split-Path $MsiPath -Leaf) (version $(if ($msiVersion) { $msiVersion } else { 'unknown' }))"
    Write-Info "Installed: $(if ($installed) { $installed } else { 'no' })"

    if ($installed -and $msiVersion -and $installed -ge $msiVersion) {
        Write-Ok "$Name $installed already installed - skipping."
        Add-Result -Step "Install $Name" -Status 'SKIPPED' -Detail "Version $installed already installed"
        return $true
    }

    $code = Invoke-MsiInstall -MsiPath $MsiPath -LogName $LogName
    switch ($code) {
        0       { Write-Ok "$Name installed."; Add-Result -Step "Install $Name" -Status 'OK' -Detail 'Exit code 0'; return $true }
        3010    { Write-Ok "$Name installed (reboot requested)."; $script:RebootRequired = $true
                  Add-Result -Step "Install $Name" -Status 'OK' -Detail 'Exit code 3010 (reboot requested)'; return $true }
        1641    { Write-Ok "$Name installed (reboot initiated)."; $script:RebootRequired = $true
                  Add-Result -Step "Install $Name" -Status 'OK' -Detail 'Exit code 1641'; return $true }
        default { Write-Fail "$Name installation failed with exit code $code. See $(Join-Path $LogPath $LogName)"
                  Add-Result -Step "Install $Name" -Status 'FAILED' -Detail "msiexec exit code $code - see $LogName"; return $false }
    }
}

# --------------------------------------------------------------------------------------------
# Current state (shown in the wizard)
# --------------------------------------------------------------------------------------------
function Get-StepStatus {
    param([string]$Step)
    switch ($Step) {
        'Network' {
            return [PSCustomObject]@{ Text = 'Will be saved to the log folder.'; Done = $false; Available = $true }
        }
        'Drivers' {
            if (-not $script:VirtioMsi) { return [PSCustomObject]@{ Text = "Not available: virtio-win-gt-x64*.msi not found in $PackagePath"; Done = $false; Available = $false } }
            $pkg = Get-MsiVersion -Path $script:VirtioMsi
            $inst = Get-InstalledProductVersion -DisplayName 'Virtio-win-driver-installer'
            $done = [bool]($inst -and $pkg -and $inst -ge $pkg)
            $t = "Package $pkg - installed: $(if ($inst) { $inst } else { 'no' })$(if ($done) { ' (will be skipped)' })"
            return [PSCustomObject]@{ Text = $t; Done = $done; Available = $true }
        }
        'GuestAgent' {
            if (-not $script:QgaMsi) { return [PSCustomObject]@{ Text = "Not available: qemu-ga-x86_64*.msi not found in $PackagePath"; Done = $false; Available = $false } }
            $pkg = Get-MsiVersion -Path $script:QgaMsi
            $inst = Get-InstalledProductVersion -DisplayName 'QEMU guest agent'
            $done = [bool]($inst -and $pkg -and $inst -ge $pkg)
            $t = "Package $pkg - installed: $(if ($inst) { $inst } else { 'no' })$(if ($done) { ' (will be skipped)' })"
            return [PSCustomObject]@{ Text = $t; Done = $done; Available = $true }
        }
        'BootDriver' {
            if (-not $script:BootPs1) { return [PSCustomObject]@{ Text = "Not available: load-virtio-scsi-on-boot.ps1 not found in $PackagePath"; Done = $false; Available = $false } }
            $parts = @()
            $allReady = $true
            foreach ($svc in @('vioscsi', 'viostor')) {
                $st = Get-BootDriverState -Service $svc
                if ($st.Ready) { $parts += "$svc boot-start" } else { $parts += "$svc not configured"; if ($svc -eq 'vioscsi') { $allReady = $false } }
            }
            return [PSCustomObject]@{ Text = "Current: $($parts -join ', ')"; Done = $allReady; Available = $true }
        }
        'Verify' {
            return [PSCustomObject]@{ Text = 'Read-only check, recommended.'; Done = $false; Available = $true }
        }
    }
}

function Get-OsInfo {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $dv = ''
    if ($cv.PSObject.Properties['DisplayVersion']) { $dv = $cv.DisplayVersion } elseif ($cv.PSObject.Properties['ReleaseId']) { $dv = $cv.ReleaseId }
    return [PSCustomObject]@{ Name = $cv.ProductName; Version = $dv; Build = [int]$cv.CurrentBuildNumber }
}

function Get-ReviewText {
    param([string[]]$Chosen, [string]$DriverChoice, [bool]$ForceChoice, [string]$LogChoice)
    $os = Get-OsInfo
    $driverNames = @{ scsi = 'VirtIO SCSI (vioscsi)'; block = 'VirtIO Block (viostor)'; both = 'VirtIO SCSI + VirtIO Block' }
    $lines = @()
    $lines += "Computer    : $computer"
    $lines += "OS          : $($os.Name) $($os.Version) (build $($os.Build))"
    $lines += ''
    $lines += 'Steps:'
    foreach ($s in $StepOrder) {
        $mark = if ($Chosen -contains $s) { '[x]' } else { '[ ]' }
        $lines += "  $mark $($StepTitles[$s])"
    }
    $lines += ''
    $lines += "Boot driver : $($driverNames[$DriverChoice])"
    $lines += "Force       : $(if ($ForceChoice) { 'Yes - re-run boot driver script' } else { 'No' })"
    $lines += "Log folder  : $LogChoice"
    $lines += "Packages    : $PackagePath"

    $notes = @()
    if ($Chosen -contains 'BootDriver' -and $Chosen -notcontains 'Drivers') {
        $missingInf = @()
        foreach ($svc in (Get-ServicesForDriver $DriverChoice)) { if (-not (Test-DriverInStore "$svc.inf")) { $missingInf += "$svc.inf" } }
        if ($missingInf.Count -gt 0) {
            $notes += "The boot driver step needs the VirtIO driver(s) $($missingInf -join ', '), which are not installed yet."
            $notes += "Tick 'Install VirtIO drivers' as well, otherwise that step will fail."
        }
    }
    if ($os.Build -le 10240) { $notes += "This OS (build $($os.Build)) is older than the VirtIO driver package supports; the run will stop at the pre-flight check." }
    if ($notes.Count -gt 0) {
        $lines += ''
        $lines += 'NOTE:'
        foreach ($n in $notes) { $lines += "  $n" }
    }
    return ($lines -join "`r`n")
}

# --------------------------------------------------------------------------------------------
# Wizard - GUI
# --------------------------------------------------------------------------------------------
function Show-WizardGui {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $os = Get-OsInfo
    $font      = New-Object System.Drawing.Font('Segoe UI', 9)
    $fontBold  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $fontTitle = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $fontMono  = New-Object System.Drawing.Font('Consolas', 9)

    $state = @{ Page = 0; Result = $null }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Proxmox VE migration preparation v$ScriptVersion"
    $form.ClientSize = New-Object System.Drawing.Size(620, 500)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.Font = $font
    $form.TopMost = $true

    # Header
    $header = New-Object System.Windows.Forms.Panel
    $header.Location = New-Object System.Drawing.Point(0, 0)
    $header.Size = New-Object System.Drawing.Size(620, 64)
    $header.BackColor = [System.Drawing.Color]::White
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Location = New-Object System.Drawing.Point(16, 10)
    $lblTitle.AutoSize = $true
    $lblTitle.Font = $fontTitle
    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Location = New-Object System.Drawing.Point(18, 38)
    $lblSub.Size = New-Object System.Drawing.Size(590, 18)
    $lblSub.ForeColor = [System.Drawing.Color]::DimGray
    $header.Controls.AddRange(@($lblTitle, $lblSub))
    $sepTop = New-Object System.Windows.Forms.Label
    $sepTop.Location = New-Object System.Drawing.Point(0, 64)
    $sepTop.Size = New-Object System.Drawing.Size(620, 1)
    $sepTop.BackColor = [System.Drawing.Color]::LightGray

    # Footer
    $sepBottom = New-Object System.Windows.Forms.Label
    $sepBottom.Location = New-Object System.Drawing.Point(0, 450)
    $sepBottom.Size = New-Object System.Drawing.Size(620, 1)
    $sepBottom.BackColor = [System.Drawing.Color]::LightGray
    $lblPage = New-Object System.Windows.Forms.Label
    $lblPage.Location = New-Object System.Drawing.Point(16, 466)
    $lblPage.AutoSize = $true
    $lblPage.ForeColor = [System.Drawing.Color]::DimGray
    $btnBack = New-Object System.Windows.Forms.Button
    $btnBack.Text = '< Back'
    $btnBack.Location = New-Object System.Drawing.Point(342, 461)
    $btnBack.Size = New-Object System.Drawing.Size(84, 28)
    $btnNext = New-Object System.Windows.Forms.Button
    $btnNext.Text = 'Next >'
    $btnNext.Location = New-Object System.Drawing.Point(432, 461)
    $btnNext.Size = New-Object System.Drawing.Size(84, 28)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(522, 461)
    $btnCancel.Size = New-Object System.Drawing.Size(84, 28)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $btnCancel

    $pages = @()
    for ($i = 0; $i -lt 3; $i++) {
        $pnl = New-Object System.Windows.Forms.Panel
        $pnl.Location = New-Object System.Drawing.Point(0, 66)
        $pnl.Size = New-Object System.Drawing.Size(620, 382)
        $pnl.Visible = ($i -eq 0)
        $pages += $pnl
    }

    # ---- Page 1: steps ----
    $tips = New-Object System.Windows.Forms.ToolTip
    $checks = @{}
    $y = 14
    foreach ($s in $StepOrder) {
        $st = Get-StepStatus -Step $s
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $StepTitles[$s]
        $cb.Font = $fontBold
        $cb.Location = New-Object System.Drawing.Point(24, $y)
        $cb.AutoSize = $true
        $cb.Enabled = $st.Available
        $cb.Checked = ($st.Available -and ($Selected -contains $s))
        $checks[$s] = $cb

        $lblDesc = New-Object System.Windows.Forms.Label
        $lblDesc.Text = $StepDescriptions[$s]
        $lblDesc.Location = New-Object System.Drawing.Point(42, ($y + 22))
        $lblDesc.Size = New-Object System.Drawing.Size(560, 18)
        $lblDesc.ForeColor = [System.Drawing.Color]::DimGray

        $lblStatus = New-Object System.Windows.Forms.Label
        $lblStatus.Text = $st.Text
        $lblStatus.Location = New-Object System.Drawing.Point(42, ($y + 40))
        $lblStatus.Size = New-Object System.Drawing.Size(560, 18)
        $lblStatus.AutoEllipsis = $true
        $tips.SetToolTip($lblStatus, $st.Text)
        if (-not $st.Available) { $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick }
        elseif ($st.Done) { $lblStatus.ForeColor = [System.Drawing.Color]::ForestGreen }
        else { $lblStatus.ForeColor = [System.Drawing.Color]::SteelBlue }

        $pages[0].Controls.AddRange(@($cb, $lblDesc, $lblStatus))
        $y += 72
    }

    # ---- Page 2: options ----
    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = 'Boot disk controller that will be used on Proxmox VE'
    $grp.Location = New-Object System.Drawing.Point(24, 14)
    $grp.Size = New-Object System.Drawing.Size(570, 116)
    $rbScsi = New-Object System.Windows.Forms.RadioButton
    $rbScsi.Text = 'VirtIO SCSI (vioscsi) - recommended, use "VirtIO SCSI single" controller'
    $rbScsi.Location = New-Object System.Drawing.Point(16, 24)
    $rbScsi.Size = New-Object System.Drawing.Size(540, 22)
    $rbBlock = New-Object System.Windows.Forms.RadioButton
    $rbBlock.Text = 'VirtIO Block (viostor)'
    $rbBlock.Location = New-Object System.Drawing.Point(16, 52)
    $rbBlock.Size = New-Object System.Drawing.Size(540, 22)
    $rbBoth = New-Object System.Windows.Forms.RadioButton
    $rbBoth.Text = 'Both'
    $rbBoth.Location = New-Object System.Drawing.Point(16, 80)
    $rbBoth.Size = New-Object System.Drawing.Size(540, 22)
    switch ($Driver) { 'scsi' { $rbScsi.Checked = $true } 'block' { $rbBlock.Checked = $true } default { $rbBoth.Checked = $true } }
    $grp.Controls.AddRange(@($rbScsi, $rbBlock, $rbBoth))

    $cbForce = New-Object System.Windows.Forms.CheckBox
    $cbForce.Text = 'Re-run the boot driver script even if the driver is already boot-start (-Force)'
    $cbForce.Location = New-Object System.Drawing.Point(24, 144)
    $cbForce.Size = New-Object System.Drawing.Size(570, 22)
    $cbForce.Checked = [bool]$Force

    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = 'Log folder (transcript, MSI logs, network snapshot):'
    $lblLog.Location = New-Object System.Drawing.Point(24, 186)
    $lblLog.AutoSize = $true
    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Text = $LogPath
    $txtLog.Location = New-Object System.Drawing.Point(24, 208)
    $txtLog.Size = New-Object System.Drawing.Size(480, 24)
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse...'
    $btnBrowse.Location = New-Object System.Drawing.Point(510, 206)
    $btnBrowse.Size = New-Object System.Drawing.Size(84, 26)
    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Select the log folder'
        if (Test-Path $txtLog.Text) { $dlg.SelectedPath = $txtLog.Text }
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $txtLog.Text = $dlg.SelectedPath }
    })
    $pages[1].Controls.AddRange(@($grp, $cbForce, $lblLog, $txtLog, $btnBrowse))

    # ---- Page 3: review ----
    $lblReview = New-Object System.Windows.Forms.Label
    $lblReview.Text = 'Review the selection. Click Run to start - progress is shown in the console window.'
    $lblReview.Location = New-Object System.Drawing.Point(24, 14)
    $lblReview.Size = New-Object System.Drawing.Size(570, 18)
    $txtReview = New-Object System.Windows.Forms.TextBox
    $txtReview.Multiline = $true
    $txtReview.ReadOnly = $true
    $txtReview.ScrollBars = 'Vertical'
    $txtReview.Font = $fontMono
    $txtReview.BackColor = [System.Drawing.Color]::White
    $txtReview.Location = New-Object System.Drawing.Point(24, 38)
    $txtReview.Size = New-Object System.Drawing.Size(570, 330)
    $pages[2].Controls.AddRange(@($lblReview, $txtReview))

    # ---- Navigation ----
    $pageTitles = @('Select steps', 'Options', 'Review and run')
    $pageSubs = @(
        "Tick the steps to run on $computer ($($os.Name), build $($os.Build)).",
        'Choose the boot disk controller and where to write logs.',
        'Nothing has been changed yet.'
    )
    $getDriver = { if ($rbScsi.Checked) { 'scsi' } elseif ($rbBlock.Checked) { 'block' } else { 'both' } }
    $getChosen = { @($StepOrder | Where-Object { $checks[$_].Checked }) }
    $showPage = {
        param([int]$n)
        $state.Page = $n
        for ($i = 0; $i -lt $pages.Count; $i++) { $pages[$i].Visible = ($i -eq $n) }
        $lblTitle.Text = $pageTitles[$n]
        $lblSub.Text = $pageSubs[$n]
        $lblPage.Text = "Step $($n + 1) of $($pages.Count)"
        $btnBack.Enabled = ($n -gt 0)
        $btnNext.Text = if ($n -eq ($pages.Count - 1)) { 'Run' } else { 'Next >' }
        if ($n -eq 2) {
            $txtReview.Text = Get-ReviewText -Chosen (& $getChosen) -DriverChoice (& $getDriver) -ForceChoice $cbForce.Checked -LogChoice $txtLog.Text.Trim()
            $txtReview.SelectionStart = 0
            $txtReview.SelectionLength = 0
        }
    }

    $btnBack.Add_Click({ if ($state.Page -gt 0) { & $showPage ($state.Page - 1) } })
    $btnNext.Add_Click({
        switch ($state.Page) {
            0 {
                if (@(& $getChosen).Count -eq 0) {
                    [void][System.Windows.Forms.MessageBox]::Show($form, 'Tick at least one step.', 'Nothing selected', 'OK', 'Information')
                    return
                }
                & $showPage 1
            }
            1 {
                if (-not $txtLog.Text.Trim()) {
                    [void][System.Windows.Forms.MessageBox]::Show($form, 'Enter a log folder.', 'Log folder', 'OK', 'Information')
                    return
                }
                & $showPage 2
            }
            2 {
                $state.Result = [PSCustomObject]@{
                    Steps   = @(& $getChosen)
                    Driver  = (& $getDriver)
                    Force   = $cbForce.Checked
                    LogPath = $txtLog.Text.Trim()
                }
                $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $form.Close()
            }
        }
    })
    $form.Add_Shown({ $form.Activate(); $form.TopMost = $false })

    $form.Controls.AddRange(@($header, $sepTop) + $pages + @($sepBottom, $lblPage, $btnBack, $btnNext, $btnCancel))
    $form.AcceptButton = $btnNext
    & $showPage 0
    [void]$form.ShowDialog()
    $form.Dispose()
    return $state.Result
}

function Show-SummaryGui {
    param([int]$Code)
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Proxmox VE migration preparation - $computer"
    $form.ClientSize = New-Object System.Drawing.Size(700, 400)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.TopMost = $true

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(16, 14)
    $lbl.Size = New-Object System.Drawing.Size(670, 26)
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    switch ($Code) {
        0       { $lbl.Text = 'Ready for migration to Proxmox VE'; $lbl.ForeColor = [System.Drawing.Color]::ForestGreen }
        3010    { $lbl.Text = 'Ready for migration (an installer requested a reboot)'; $lbl.ForeColor = [System.Drawing.Color]::ForestGreen }
        default { $lbl.Text = 'Not ready - see details below and the log'; $lbl.ForeColor = [System.Drawing.Color]::Firebrick }
    }
    if ($Code -eq 0 -and $Selected -notcontains 'Verify') {
        $lbl.Text = 'Selected steps completed (verification was not run)'
    }

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines = $true
    $lv.Location = New-Object System.Drawing.Point(16, 48)
    $lv.Size = New-Object System.Drawing.Size(668, 296)
    [void]$lv.Columns.Add('Step', 220)
    [void]$lv.Columns.Add('Status', 80)
    [void]$lv.Columns.Add('Detail', 345)
    foreach ($r in $script:Results) {
        $item = New-Object System.Windows.Forms.ListViewItem($r.Step)
        [void]$item.SubItems.Add($r.Status)
        [void]$item.SubItems.Add($r.Detail)
        switch ($r.Status) {
            'OK'      { $item.ForeColor = [System.Drawing.Color]::ForestGreen }
            'FAILED'  { $item.ForeColor = [System.Drawing.Color]::Firebrick }
            'WARNING' { $item.ForeColor = [System.Drawing.Color]::DarkOrange }
            default   { $item.ForeColor = [System.Drawing.Color]::DimGray }
        }
        [void]$lv.Items.Add($item)
    }

    $btnLogs = New-Object System.Windows.Forms.Button
    $btnLogs.Text = 'Open log folder'
    $btnLogs.Location = New-Object System.Drawing.Point(16, 358)
    $btnLogs.Size = New-Object System.Drawing.Size(130, 28)
    $btnLogs.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$LogPath`"" })
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Close'
    $btnClose.Location = New-Object System.Drawing.Point(600, 358)
    $btnClose.Size = New-Object System.Drawing.Size(84, 28)
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $btnClose
    $form.CancelButton = $btnClose
    $form.Controls.AddRange(@($lbl, $lv, $btnLogs, $btnClose))
    $form.Add_Shown({ $form.Activate(); $form.TopMost = $false })
    [void]$form.ShowDialog()
    $form.Dispose()
}

# --------------------------------------------------------------------------------------------
# Wizard - console (Server Core, no GUI available)
# --------------------------------------------------------------------------------------------
function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = (Read-Host "$Prompt $hint").Trim()
        if (-not $a) { return $Default }
        if ($a -match '^(y|yes)$') { return $true }
        if ($a -match '^(n|no)$') { return $false }
    }
}

function Show-WizardConsole {
    $os = Get-OsInfo
    Write-Host ""
    Write-Host "=== Proxmox VE migration preparation v$ScriptVersion - $computer ===" -ForegroundColor Cyan
    Write-Host "    $($os.Name) $($os.Version) (build $($os.Build))"
    Write-Host "    Answer Y/N for each step. Nothing is changed until you confirm at the end."

    $chosen = @()
    $i = 0
    foreach ($s in $StepOrder) {
        $i++
        $st = Get-StepStatus -Step $s
        Write-Host ""
        Write-Host "  [$i/$($StepOrder.Count)] $($StepTitles[$s])" -ForegroundColor White
        Write-Host "        $($StepDescriptions[$s])" -ForegroundColor DarkGray
        $color = if (-not $st.Available) { 'Red' } elseif ($st.Done) { 'Green' } else { 'Gray' }
        Write-Host "        $($st.Text)" -ForegroundColor $color
        if (-not $st.Available) { continue }
        if (Read-YesNo -Prompt '        Run this step?' -Default ($Selected -contains $s)) { $chosen += $s }
    }
    if ($chosen.Count -eq 0) { Write-Host ""; Write-Host "No steps selected." -ForegroundColor Yellow; return $null }

    $drv = $Driver
    $frc = [bool]$Force
    if ($chosen -contains 'BootDriver' -or $chosen -contains 'Verify') {
        Write-Host ""
        Write-Host "  Boot disk controller on Proxmox VE:" -ForegroundColor White
        Write-Host "    1) VirtIO SCSI (vioscsi) - recommended"
        Write-Host "    2) VirtIO Block (viostor)"
        Write-Host "    3) Both"
        $def = switch ($Driver) { 'scsi' { '1' } 'block' { '2' } default { '3' } }
        do { $a = (Read-Host "    Choice [$def]").Trim(); if (-not $a) { $a = $def } } while ($a -notmatch '^[123]$')
        $drv = switch ($a) { '1' { 'scsi' } '2' { 'block' } default { 'both' } }
    }
    if ($chosen -contains 'BootDriver') {
        $frc = Read-YesNo -Prompt '    Re-run the boot driver script even if already configured?' -Default $frc
    }
    $log = (Read-Host "    Log folder [$LogPath]").Trim()
    if (-not $log) { $log = $LogPath }

    Write-Host ""
    Write-Host (Get-ReviewText -Chosen $chosen -DriverChoice $drv -ForceChoice $frc -LogChoice $log)
    Write-Host ""
    if (-not (Read-YesNo -Prompt 'Start now?' -Default $true)) { return $null }
    return [PSCustomObject]@{ Steps = $chosen; Driver = $drv; Force = $frc; LogPath = $log }
}

# --------------------------------------------------------------------------------------------
# Exit
# --------------------------------------------------------------------------------------------
function Write-StatusMarker {
    # Leaves the result of the last run on the machine, so many machines can be checked at once:
    #   Invoke-Command -ComputerName $servers { Get-ItemProperty HKLM:\SOFTWARE\PVE-Prep }
    param([int]$Code)
    try {
        $key = 'HKLM:\SOFTWARE\PVE-Prep'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        $result = switch ($Code) { 0 { 'Ready' } 3010 { 'ReadyRebootRequested' } default { 'NotReady' } }
        if (@(0, 3010) -contains $Code -and $Selected -notcontains 'Verify') { $result = 'CompletedNotVerified' }
        $failed = @($script:Results | Where-Object { $_.Status -eq 'FAILED' } | ForEach-Object { $_.Step })
        Set-ItemProperty -Path $key -Name 'Version'     -Value $ScriptVersion -Type String
        Set-ItemProperty -Path $key -Name 'LastRun'     -Value (Get-Date -Format 's') -Type String
        Set-ItemProperty -Path $key -Name 'ExitCode'    -Value $Code -Type DWord
        Set-ItemProperty -Path $key -Name 'Result'      -Value $result -Type String
        Set-ItemProperty -Path $key -Name 'FailedSteps' -Value ($failed -join '; ') -Type String
        Set-ItemProperty -Path $key -Name 'Steps'       -Value ($Selected -join ',') -Type String
        Set-ItemProperty -Path $key -Name 'Driver'      -Value $Driver -Type String
        Set-ItemProperty -Path $key -Name 'LogFile'     -Value ([string]$transcript) -Type String
        Write-Host "Status written to HKLM\SOFTWARE\PVE-Prep (Result=$result)."
    } catch {
        Write-Host "Could not write status to HKLM\SOFTWARE\PVE-Prep: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Exit-Script {
    param([int]$Code)
    if ($Code -eq 1602) {
        Write-Host "Cancelled - nothing was changed." -ForegroundColor Yellow
        if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
        exit $Code
    }
    Write-Host ""
    Write-Host "=== SUMMARY ($computer) ===" -ForegroundColor Cyan
    if ($script:Results.Count -gt 0) {
        $script:Results | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    }
    switch ($Code) {
        0    {
            if ($Selected -contains 'Verify') { Write-Host "RESULT: Ready for migration to Proxmox VE." -ForegroundColor Green }
            else { Write-Host "RESULT: Selected steps completed (verification was not run)." -ForegroundColor Green }
        }
        3010 { Write-Host "RESULT: Completed. An installer requested a reboot (optional before migrating)." -ForegroundColor Green }
        default { Write-Host "RESULT: NOT ready - review the log: $transcript" -ForegroundColor Red }
    }
    Write-Host "Logs: $LogPath"
    Write-StatusMarker -Code $Code
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    if ($script:UiMode -eq 'Gui') {
        try { Show-SummaryGui -Code $Code } catch { if ($PauseAtEnd) { Read-Host "Press Enter to close" | Out-Null } }
    } elseif ($PauseAtEnd -and [Environment]::UserInteractive) {
        Write-Host ""; Read-Host "Press Enter to close" | Out-Null
    }
    exit $Code
}

# --------------------------------------------------------------------------------------------
# Locate package files
# --------------------------------------------------------------------------------------------
$script:VirtioMsi = Find-PackageFile -Pattern 'virtio-win-gt-x64*.msi' -Description 'VirtIO driver MSI'
$script:QgaMsi    = Find-PackageFile -Pattern 'qemu-ga-x86_64*.msi'    -Description 'QEMU guest agent MSI'
$script:BootPs1   = Find-PackageFile -Pattern 'load-virtio-scsi-on-boot*.ps1' -Description 'boot driver script'

# --------------------------------------------------------------------------------------------
# Wizard
# --------------------------------------------------------------------------------------------
if ($Wizard) {
    if (-not [Environment]::UserInteractive) {
        Write-Host "-Wizard ignored: no interactive session. Running steps: $($Selected -join ', ')" -ForegroundColor Yellow
    } else {
        $choice = $null
        $guiOk = $false
        $instType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).InstallationType
        if ($instType -ne 'Server Core') {
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                $guiOk = $true
            } catch { $guiOk = $false }
        }

        if ($guiOk) {
            try {
                $choice = Show-WizardGui
                $script:UiMode = 'Gui'
            } catch {
                Write-Host "GUI wizard could not be shown ($($_.Exception.Message)) - using console wizard." -ForegroundColor Yellow
                $choice = Show-WizardConsole
            }
        } else {
            $choice = Show-WizardConsole
        }
        if (-not $choice) { Exit-Script 1602 }

        $Selected = @($StepOrder | Where-Object { $choice.Steps -contains $_ })
        $Driver = $choice.Driver
        $Force = [switch][bool]$choice.Force
        $LogPath = $choice.LogPath
    }
}

if ($Selected.Count -eq 0) {
    Write-Host "No steps selected - nothing to do." -ForegroundColor Yellow
    exit 2
}
$services = Get-ServicesForDriver $Driver

# --------------------------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------------------------
try {
    if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
} catch {
    Write-Host "Cannot use log folder '$LogPath' - falling back to $env:windir\Temp\PVE-Prep" -ForegroundColor Yellow
    $LogPath = Join-Path $env:windir 'Temp\PVE-Prep'
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$transcript = Join-Path $LogPath "PVE-Prep_${computer}_$timestamp.log"
try { Start-Transcript -Path $transcript -Force | Out-Null; $transcriptStarted = $true } catch { }

# --------------------------------------------------------------------------------------------
# Steps
# --------------------------------------------------------------------------------------------
function Invoke-PreFlight {
    Write-Step 'Pre-flight checks'
    $os = Get-OsInfo
    Write-Info "OS:     $($os.Name) $($os.Version) (build $($os.Build))"
    Write-Info "Steps:  $($Selected -join ', ')"
    Write-Info "Driver: $Driver ($($services -join ', '))$(if ($Force) { ', -Force' })"
    Write-Info "Package folder: $PackagePath"
    Write-Info "Log folder:     $LogPath"

    if (-not [Environment]::Is64BitOperatingSystem) {
        Write-Fail '32-bit Windows is not supported by these installers (x64 only).'
        Add-Result -Step 'Pre-flight' -Status 'FAILED' -Detail '32-bit OS'
        Exit-Script 2
    }
    if ($os.Build -le 10240 -and ($Selected -contains 'Drivers' -or $Selected -contains 'BootDriver')) {
        Write-Fail "virtio-win-gt requires Windows 10 1511 / Windows Server 2016 or newer (build > 10240). This is build $($os.Build)."
        Write-Info 'For older systems use a virtio-win release that still supports them.'
        Add-Result -Step 'Pre-flight' -Status 'FAILED' -Detail "Unsupported OS build $($os.Build)"
        Exit-Script 2
    }

    $missing = @()
    if ($Selected -contains 'Drivers' -and -not $script:VirtioMsi) { $missing += 'virtio-win-gt-x64*.msi' }
    if ($Selected -contains 'GuestAgent' -and -not $script:QgaMsi) { $missing += 'qemu-ga-x86_64*.msi' }
    if ($Selected -contains 'BootDriver' -and -not $script:BootPs1) { $missing += 'load-virtio-scsi-on-boot.ps1' }
    if ($missing.Count -gt 0) {
        Write-Fail "Missing package file(s) in ${PackagePath}: $($missing -join ', ')"
        Add-Result -Step 'Pre-flight' -Status 'FAILED' -Detail "Missing: $($missing -join ', ')"
        Exit-Script 2
    }

    # Files copied from the internet / OneDrive may carry a Zone.Identifier mark.
    foreach ($f in @($script:VirtioMsi, $script:QgaMsi, $script:BootPs1)) {
        if ($f) { try { Unblock-File -Path $f -ErrorAction SilentlyContinue } catch { } }
    }
    Write-Ok 'Pre-flight checks passed.'
    Add-Result -Step 'Pre-flight' -Status 'OK' -Detail "$($os.Name) build $($os.Build)"
}

function Invoke-StepNetwork {
    Write-Step $StepTitles['Network']
    try {
        $netFile = Join-Path $LogPath "network-config_${computer}_$timestamp.txt"
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("Network configuration of $computer captured $(Get-Date)")
        [void]$sb.AppendLine('After migration the NIC becomes a new VirtIO adapter; re-apply static settings from here.')
        [void]$sb.AppendLine('')
        try {
            [void]$sb.AppendLine((Get-NetIPConfiguration -Detailed -ErrorAction Stop | Out-String -Width 200))
            [void]$sb.AppendLine('--- Static (manual) IP addresses ---')
            [void]$sb.AppendLine((Get-NetIPAddress -PrefixOrigin Manual -ErrorAction SilentlyContinue |
                Select-Object InterfaceAlias, AddressFamily, IPAddress, PrefixLength | Format-Table -AutoSize | Out-String -Width 200))
            [void]$sb.AppendLine('--- Routes ---')
            [void]$sb.AppendLine((Get-NetRoute -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0', '::/0') -or $_.Protocol -eq 'NetMgmt' } |
                Select-Object InterfaceAlias, DestinationPrefix, NextHop, RouteMetric | Format-Table -AutoSize | Out-String -Width 200))
        } catch { }
        [void]$sb.AppendLine('--- ipconfig /all ---')
        [void]$sb.AppendLine((& ipconfig.exe /all | Out-String))
        $sb.ToString() | Out-File -FilePath $netFile -Encoding UTF8
        Write-Ok "Saved to $netFile"
        Add-Result -Step 'Network snapshot' -Status 'OK' -Detail (Split-Path $netFile -Leaf)
    } catch {
        Write-Warn "Could not save network configuration: $($_.Exception.Message)"
        Add-Result -Step 'Network snapshot' -Status 'WARNING' -Detail $_.Exception.Message
    }
}

function Add-DriverToStore {
    # Stages a driver package in the Windows driver store so Plug and Play installs it
    # automatically when the matching VirtIO device appears after migration.
    param([string]$InfPath, [int]$Build)
    $pnputil = Join-Path $env:windir 'System32\pnputil.exe'
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if ($Build -ge 14393) { $out = & $pnputil /add-driver "$InfPath" 2>&1 | Out-String }
    else { $out = & $pnputil -a "$InfPath" 2>&1 | Out-String }
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    return [PSCustomObject]@{ ExitCode = $rc; Output = $out.Trim() }
}

function Invoke-StepDrivers {
    Write-Step $StepTitles['Drivers']
    $msiOk = Install-MsiPackage -Name 'VirtIO drivers' -MsiPath $script:VirtioMsi -DisplayName 'Virtio-win-driver-installer' -LogName "virtio-win-gt_${computer}_$timestamp.log"
    if (-not $msiOk) { $script:DriverInstallFailed = $true; return }

    # Make sure every package from the install folder is in the Windows driver store, so Plug
    # and Play installs it automatically when the VirtIO device appears after migration.
    # The MSI normally stages them already; pnputil /add-driver is a no-op for those
    # ("Already exists in the system") and fixes any that are missing.
    $virtioDir = Join-Path $env:ProgramFiles 'Virtio-Win'
    $build = (Get-OsInfo).Build
    $infFiles = @(Get-ChildItem -LiteralPath $virtioDir -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue)
    if ($infFiles.Count -eq 0) {
        Write-Fail "No driver packages found in $virtioDir."
        Add-Result -Step 'Stage VirtIO drivers' -Status 'FAILED' -Detail "No .inf files in $virtioDir"
        $script:DriverInstallFailed = $true
        return
    }

    Write-Info "Adding VirtIO driver packages to the driver store ($($infFiles.Count) found in $virtioDir)..."
    $staged = 0; $already = 0; $stageFailed = @()
    $confirmed = @()   # packages pnputil reported as added / already present
    foreach ($inf in $infFiles) {
        if (Test-DriverInStore -InfName $inf.Name) { $already++; $confirmed += $inf.Name; continue }
        $r = Add-DriverToStore -InfPath $inf.FullName -Build $build
        if (@(0, 3010) -contains $r.ExitCode -or (Test-DriverInStore -InfName $inf.Name)) {
            $published = ''
            if ($r.Output -match '(oem\d+\.inf)') { $published = " as $($Matches[1])" }
            Write-Ok "$($inf.Name) is in the driver store$published."
            $staged++
            $confirmed += $inf.Name
        } else {
            Write-Warn "$($inf.Name) could not be added (pnputil exit code $($r.ExitCode))."
            if ($r.Output) { $r.Output -split "`r?`n" | ForEach-Object { Write-Info "    | $_" } }
            $stageFailed += $inf.Name
        }
    }
    Write-Info "Driver store: $already already present, $staged added/confirmed by pnputil, $($stageFailed.Count) failed."

    # Required: the boot storage driver(s), network and serial (guest agent). Others are optional.
    $required = @()
    foreach ($s in $services) { $required += "$s.inf" }
    $required += 'netkvm.inf', 'vioser.inf'
    $missingRequired = @()
    foreach ($inf in $required) {
        if ($confirmed -contains $inf -or (Test-DriverInStore -InfName $inf)) { Write-Ok "$inf is in the driver store." }
        else { Write-Fail "$inf is NOT in the driver store."; $missingRequired += $inf }
    }

    if ($missingRequired.Count -gt 0) {
        Add-Result -Step 'Stage VirtIO drivers' -Status 'FAILED' -Detail "Missing: $($missingRequired -join ', ')"
    } elseif ($stageFailed.Count -gt 0) {
        Add-Result -Step 'Stage VirtIO drivers' -Status 'WARNING' -Detail "Optional not staged: $($stageFailed -join ', ')"
    } else {
        Add-Result -Step 'Stage VirtIO drivers' -Status 'OK' -Detail "All $($already + $staged) packages in the driver store"
    }

    # Only a missing storage driver blocks the boot driver step.
    foreach ($s in $services) {
        if ($missingRequired -contains "$s.inf") { $script:DriverInstallFailed = $true }
    }
}

function Invoke-StepGuestAgent {
    Write-Step $StepTitles['GuestAgent']
    $ok = Install-MsiPackage -Name 'QEMU guest agent' -MsiPath $script:QgaMsi -DisplayName 'QEMU guest agent' -LogName "qemu-ga_${computer}_$timestamp.log"
    $qga = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
    if ($qga) {
        $startMode = (Get-CimInstance Win32_Service -Filter "Name='QEMU-GA'" -ErrorAction SilentlyContinue).StartMode
        Write-Ok "QEMU-GA service present (StartMode: $startMode, Status: $($qga.Status)). It connects once the VM runs on Proxmox VE."
    } elseif ($ok) {
        Write-Fail 'QEMU-GA service not found after installation.'
        Add-Result -Step 'QEMU-GA service' -Status 'FAILED' -Detail 'Service missing'
    }
    if (-not (Test-DriverInStore -InfName 'vioser.inf')) {
        Write-Warn 'VirtIO serial driver (vioser.inf) is not installed - the agent needs it on Proxmox VE. Run the VirtIO driver step too.'
        Add-Result -Step 'QEMU guest agent prerequisite' -Status 'WARNING' -Detail 'vioser.inf not in driver store'
    }
}

function Invoke-StepBootDriver {
    Write-Step "$($StepTitles['BootDriver']) ($($services -join ', '))"
    $bootName = Split-Path $script:BootPs1 -Leaf

    if ($script:DriverInstallFailed) {
        Write-Fail 'Skipped because the VirtIO driver installation did not complete.'
        Add-Result -Step 'Boot driver configuration' -Status 'FAILED' -Detail 'VirtIO driver install failed'
        return
    }
    $missingInf = @()
    foreach ($s in $services) { if (-not (Test-DriverInStore -InfName "$s.inf")) { $missingInf += "$s.inf" } }
    if ($missingInf.Count -gt 0) {
        Write-Fail "$($missingInf -join ', ') not in the driver store - install the VirtIO drivers first (Drivers step)."
        Add-Result -Step 'Boot driver configuration' -Status 'FAILED' -Detail "Missing $($missingInf -join ', ')"
        return
    }

    $alreadyDone = $true
    foreach ($s in $services) {
        $st = Get-BootDriverState -Service $s
        if (-not ($st.Exists -and $st.BootStart -and $st.ImagePresent)) { $alreadyDone = $false }
    }

    if ($alreadyDone -and -not $Force) {
        Write-Ok "$($services -join ', ') already configured as boot-start - skipping $bootName (use -Force to re-run)."
        Add-Result -Step 'Boot driver configuration' -Status 'SKIPPED' -Detail 'Already boot-start'
    } else {
        $psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Write-Info "Running: $bootName -Driver $Driver"
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:BootPs1 -Driver $Driver 2>&1 |
            ForEach-Object { Write-Host "    | $_" }
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        if ($rc -eq 0) {
            Write-Ok "$bootName finished (exit code 0)."
            Add-Result -Step 'Boot driver configuration' -Status 'OK' -Detail "$bootName exit code 0"
        } else {
            Write-Fail "$bootName failed (exit code $rc)."
            Add-Result -Step 'Boot driver configuration' -Status 'FAILED' -Detail "$bootName exit code $rc"
            return
        }
    }

    # Windows can disable boot-start storage drivers that have no device present via a
    # StartOverride key. That would cause INACCESSIBLE_BOOT_DEVICE after migration.
    foreach ($s in $services) {
        $st = Get-BootDriverState -Service $s
        if ($st.Overrides.Count -gt 0) {
            Write-Warn "$s has StartOverride ($($st.Overrides -join ', ')) - removing it so the driver loads at boot."
            Remove-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$s\StartOverride" -Recurse -Force
            Add-Result -Step "StartOverride $s" -Status 'WARNING' -Detail 'Removed StartOverride'
        }
    }
}

function Invoke-StepVerify {
    Write-Step $StepTitles['Verify']
    foreach ($s in $services) {
        $st = Get-BootDriverState -Service $s
        if ($st.Ready) {
            Write-Ok "$s : service present, Start=0 (boot), $s.sys present."
            Add-Result -Step "Verify $s boot-start" -Status 'OK' -Detail 'Start=0, driver file present'
        } else {
            $why = @()
            if (-not $st.Exists) { $why += 'service key missing' }
            elseif (-not $st.BootStart) { $why += "Start=$($st.Start) (expected 0)" }
            if ($st.Exists -and -not $st.ImagePresent) { $why += "$s.sys missing" }
            if ($st.Overrides.Count -gt 0) { $why += "StartOverride $($st.Overrides -join ',') - run the boot driver step" }
            Write-Fail "$s : $($why -join '; ')"
            Add-Result -Step "Verify $s boot-start" -Status 'FAILED' -Detail ($why -join '; ')
        }
    }

    if (Test-DriverInStore -InfName 'netkvm.inf') {
        Write-Ok 'netkvm : VirtIO network driver is in the driver store.'
        Add-Result -Step 'Verify VirtIO network driver' -Status 'OK' -Detail 'netkvm.inf present'
    } else {
        Write-Warn 'netkvm : VirtIO network driver not installed - a VirtIO NIC will not work after migration.'
        Add-Result -Step 'Verify VirtIO network driver' -Status 'WARNING' -Detail 'netkvm.inf missing'
    }

    $qgaSvc = Get-CimInstance Win32_Service -Filter "Name='QEMU-GA'" -ErrorAction SilentlyContinue
    if ($qgaSvc -and $qgaSvc.StartMode -eq 'Auto') {
        Write-Ok 'QEMU-GA : installed, start mode Auto.'
        Add-Result -Step 'Verify QEMU guest agent' -Status 'OK' -Detail 'Service Auto'
    } elseif ($qgaSvc) {
        Write-Warn "QEMU-GA : installed but start mode is $($qgaSvc.StartMode)."
        Add-Result -Step 'Verify QEMU guest agent' -Status 'WARNING' -Detail "StartMode $($qgaSvc.StartMode)"
    } else {
        Write-Warn 'QEMU-GA : not installed (the VM boots fine, but Proxmox VE gets no guest agent).'
        Add-Result -Step 'Verify QEMU guest agent' -Status 'WARNING' -Detail 'Not installed'
    }
}

# --------------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------------
Write-Host "Proxmox VE migration preparation v$ScriptVersion - $computer - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Invoke-PreFlight
foreach ($step in $Selected) {
    switch ($step) {
        'Network'    { Invoke-StepNetwork }
        'Drivers'    { Invoke-StepDrivers }
        'GuestAgent' { Invoke-StepGuestAgent }
        'BootDriver' { Invoke-StepBootDriver }
        'Verify'     { Invoke-StepVerify }
    }
}

if ($script:Failed) { Exit-Script 1 }
if ($script:RebootRequired) { Exit-Script 3010 }
Exit-Script 0
