[CmdletBinding()]
param(
    [string]$TargetRoot = 'F:\backup\windowsapps\AppsBackups\python',
    [string]$EmbeddedPythonZip,
    [switch]$DownloadIfMissing,
    [switch]$RemoveStorePythonPackages,
    [UInt64]$AllowedRemnantBytes = 0,

    # Test harness only. Do not use these for real migration.
    [string]$SystemDriveRoot = 'C:\',
    [string]$UserProfileRoot = $env:USERPROFILE,
    [switch]$TestMode,
    [switch]$AllowNonFDriveForTests,
    [switch]$SkipProcessCheck,
    [switch]$StopBlockingPythonProcesses,
    [switch]$PreserveBlockingPythonProcesses,
    [string]$ProcessPathRootForTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'PythonPortableCommon.psm1'
Import-Module $modulePath -Force

try {
    $shouldStopBlockingPythonProcesses = (-not $PreserveBlockingPythonProcesses) -or $StopBlockingPythonProcesses
    Invoke-PortablePythonMigration `
        -TargetRoot $TargetRoot `
        -SystemDriveRoot $SystemDriveRoot `
        -UserProfileRoot $UserProfileRoot `
        -EmbeddedPythonZip $EmbeddedPythonZip `
        -DownloadIfMissing:$DownloadIfMissing `
        -RemoveStorePythonPackages:$RemoveStorePythonPackages `
        -AllowedRemnantBytes $AllowedRemnantBytes `
        -TestMode:$TestMode `
        -AllowNonFDriveForTests:$AllowNonFDriveForTests `
        -SkipProcessCheck:$SkipProcessCheck `
        -StopBlockingPythonProcesses:$shouldStopBlockingPythonProcesses `
        -ProcessPathRootForTests $ProcessPathRootForTests
} catch {
    Write-Host $_.Exception.Message
    exit 1
}
