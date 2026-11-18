<#
.SYNOPSIS
    Updates manifest.json after you change the tool or replace an installer.

.DESCRIPTION
    - version          <- $ScriptVersion from Prepare-PVEMigration.ps1
    - packages[].sha256 <- SHA-256 of the files in packages\
    - packages[].version <- ProductVersion read from the MSI (Windows only; kept as-is elsewhere)

    New installer version: replace the .msi in packages\ (keep the file name), bump
    $ScriptVersion in Prepare-PVEMigration.ps1, run this script, commit, tag.

.EXAMPLE
    .\tools\Update-Manifest.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $root 'manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

function Get-MsiProductVersion {
    param([string]$Path)
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductVersion'"))
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        $v = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1)
        [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        foreach ($o in @($view, $db, $installer)) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }
        return $v
    } catch {
        return $null
    }
}

# Tool version from the script
$prep = Get-Content -LiteralPath (Join-Path $root 'Prepare-PVEMigration.ps1') -Raw
if ($prep -match "\`$ScriptVersion\s*=\s*'([^']+)'") {
    $manifest.version = $Matches[1]
} else {
    throw 'Could not find $ScriptVersion in Prepare-PVEMigration.ps1'
}

foreach ($pkg in $manifest.packages) {
    $file = Join-Path $root $pkg.path
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing $($pkg.path)" }
    $pkg.sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    $v = Get-MsiProductVersion -Path $file
    if ($v) { $pkg.version = $v }
    Write-Host ("{0,-24} {1,-10} {2}" -f $pkg.file, $pkg.version, $pkg.sha256)
}

$json = $manifest | ConvertTo-Json -Depth 5
# Plain UTF-8 without BOM, so the bootstrap can read it with any client
[IO.File]::WriteAllText($manifestPath, $json + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Host "manifest.json updated (version $($manifest.version))." -ForegroundColor Green
