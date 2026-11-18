<#
.SYNOPSIS
    Bootstrapper for pve-windows-prep: downloads the tool and runs it.

.DESCRIPTION
    Downloads the scripts and the VirtIO / QEMU guest agent installers listed in manifest.json
    from this repository (or -BaseUrl), checks every installer against its SHA-256 hash, saves
    everything to %ProgramData%\PVE-Prep\app\<version> and runs Prepare-PVEMigration.ps1.

    Run it from an elevated PowerShell (Run as administrator) with the one-liner:

      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/YOUR-GITHUB-USER/pve-windows-prep/main/install.ps1)))

    Add parameters after the closing bracket, e.g.  ...install.ps1))) -Wizard
    The exit code of the tool is left in $LASTEXITCODE:
      0 ready, 3010 ready (reboot requested), 1 a step failed, 2 pre-flight/parameter error,
      1602 cancelled in the wizard, 10 download/verification failed.

.PARAMETER Wizard
    Open the wizard to choose the steps interactively.

.PARAMETER Steps
    Steps to run (comma separated): Network, Drivers, GuestAgent, BootDriver, Verify. Default: all.

.PARAMETER Driver
    Boot driver to prepare: scsi (default), block or both.

.PARAMETER LogPath
    Log folder. Default: %ProgramData%\PVE-Prep\Logs

.PARAMETER Force
    Re-run the boot driver script even if the driver is already boot-start.

.PARAMETER Ref
    Branch or tag to download. Use a release tag (e.g. v1.4.0) for production runs.

.PARAMETER Repo
    GitHub repository (owner/name).

.PARAMETER BaseUrl
    Download from another location instead of GitHub, e.g. a GitLab raw URL or an internal
    web server. Files are expected at <BaseUrl>/<path from manifest.json>.

.PARAMETER PackageSource
    Folder (local or UNC) that already contains the .msi files. They are copied from there
    instead of downloaded, but still checked against the hashes in manifest.json.

.PARAMETER InstallPath
    Where the tool is saved. Default: %ProgramData%\PVE-Prep\app

.PARAMETER DownloadOnly
    Download and verify, but do not run the tool.
#>
[CmdletBinding()]
param(
    [switch]$Wizard,
    [string[]]$Steps,
    [ValidateSet('scsi', 'block', 'both')]
    [string]$Driver,
    [string]$LogPath,
    [switch]$Force,

    [string]$Ref = 'main',
    [string]$Repo = 'jeistari/pve-windows-prep',
    [string]$BaseUrl = '',
    [string]$PackageSource = '',
    [string]$InstallPath = (Join-Path $env:ProgramData 'PVE-Prep\app'),
    [switch]$DownloadOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

function Write-Boot {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host "[pve-prep] $Text" -ForegroundColor $Color
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Everything below runs inside one function so 'return' ends the bootstrap without closing
# the PowerShell window it was started from.
function Invoke-PvePrepBootstrap {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Boot 'Run this from an elevated PowerShell (Run as administrator) or as SYSTEM.' 'Red'
        return 2
    }

    $base = $BaseUrl
    if (-not $base) {
        if ($Repo -like 'YOUR-GITHUB-USER/*') {
            Write-Boot "The repository is not set. Pass -Repo owner/name or edit the default in install.ps1." 'Red'
            return 2
        }
        $base = "https://raw.githubusercontent.com/$Repo/$Ref"
    }
    $base = $base.TrimEnd('/')
    Write-Boot "Source: $base"

    $wc = New-Object System.Net.WebClient
    $wc.Headers['User-Agent'] = 'pve-windows-prep-bootstrap'
    if ($wc.Proxy) { $wc.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials }

    # --- manifest ---
    try {
        $manifest = $wc.DownloadString("$base/manifest.json") | ConvertFrom-Json
    } catch {
        Write-Boot "Could not download $base/manifest.json : $($_.Exception.Message)" 'Red'
        return 10
    }
    $version = [string]$manifest.version
    $target = Join-Path $InstallPath $version
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
    Write-Boot "Version $version -> $target"

    # --- scripts ---
    foreach ($rel in $manifest.scripts) {
        $dest = Join-Path $target (Split-Path $rel -Leaf)
        try {
            $wc.DownloadFile("$base/$rel", $dest)
        } catch {
            Write-Boot "Download failed: $base/$rel : $($_.Exception.Message)" 'Red'
            return 10
        }
    }

    # --- installers (hash-checked) ---
    foreach ($pkg in $manifest.packages) {
        $dest = Join-Path $target $pkg.file
        $want = ([string]$pkg.sha256).ToLowerInvariant()

        if ((Test-Path -LiteralPath $dest) -and (Get-Sha256 $dest) -eq $want) {
            Write-Boot "$($pkg.file) $($pkg.version): already downloaded, hash OK"
            continue
        }
        try {
            if ($PackageSource) {
                $src = Join-Path $PackageSource $pkg.file
                Write-Boot "$($pkg.file) $($pkg.version): copying from $src"
                Copy-Item -LiteralPath $src -Destination $dest -Force
            } else {
                Write-Boot "$($pkg.file) $($pkg.version): downloading"
                $wc.DownloadFile("$base/$($pkg.path)", $dest)
            }
        } catch {
            Write-Boot "Could not get $($pkg.file): $($_.Exception.Message)" 'Red'
            return 10
        }
        $got = Get-Sha256 $dest
        if ($got -ne $want) {
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            Write-Boot "HASH MISMATCH for $($pkg.file) - file removed. Expected $want, got $got" 'Red'
            return 10
        }
        Write-Boot "$($pkg.file): hash OK" 'Green'
    }

    $prep = Join-Path $target 'Prepare-PVEMigration.ps1'
    if ($DownloadOnly) {
        Write-Boot "Downloaded and verified. Run: $prep" 'Green'
        return 0
    }

    # --- run the tool in 64-bit Windows PowerShell ---
    $psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $psExe = Join-Path $env:windir 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    }
    $toolArgs = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $prep, '-PackagePath', $target)
    if ($Wizard)  { $toolArgs += '-Wizard'; $toolArgs += '-PauseAtEnd' }
    if ($Steps)   { $toolArgs += '-Steps';   $toolArgs += ($Steps -join ',') }
    if ($Driver)  { $toolArgs += '-Driver';  $toolArgs += $Driver }
    if ($LogPath) { $toolArgs += '-LogPath'; $toolArgs += $LogPath }
    if ($Force)   { $toolArgs += '-Force' }

    Write-Boot "Starting Prepare-PVEMigration.ps1 $($toolArgs[6..($toolArgs.Count - 1)] -join ' ')"
    if ($Host.Name -eq 'ServerRemoteHost') {
        # Invoke-Command / Enter-PSSession: stream the tool's output back to the caller.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $psExe @toolArgs 2>&1 | Out-Host
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
    } else {
        # Local console, scheduled task, RMM agent: run in the same console (keeps colours and
        # lets the console wizard prompt normally).
        $argLine = ($toolArgs | ForEach-Object {
            if ($_ -match '\s') { '"' + $_.TrimEnd('\') + '"' } else { $_ }
        }) -join ' '
        $p = Start-Process -FilePath $psExe -ArgumentList $argLine -NoNewWindow -PassThru
        [void]$p.Handle   # cache the handle so ExitCode is available
        $p.WaitForExit()
        $rc = $p.ExitCode
    }
    return $rc
}

$rc = Invoke-PvePrepBootstrap
$global:LASTEXITCODE = $rc
$meaning = switch ($rc) {
    0       { 'ready' }
    3010    { 'ready, an installer requested a reboot' }
    1       { 'a step failed - see the log' }
    2       { 'pre-flight or parameter error' }
    10      { 'download or verification failed' }
    1602    { 'cancelled' }
    default { 'see the log' }
}
Write-Boot "Finished with exit code $rc ($meaning)." $(if (@(0, 3010) -contains $rc) { 'Green' } else { 'Yellow' })

# Started as a file (powershell.exe -File install.ps1 ...): hand the code to the caller.
# Started via the one-liner: only $LASTEXITCODE is set, so the console stays open.
if ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript') { exit $rc }
