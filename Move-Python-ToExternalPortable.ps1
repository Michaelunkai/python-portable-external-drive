[CmdletBinding()]
param(
    [string]$TargetRoot = 'F:\backup\windowsapps\AppsBackups\python',
    [string]$EmbeddedPythonZip,
    [switch]$DownloadIfMissing,
    [UInt64]$AllowedRemnantBytes = 0,

    # Test harness only. Do not use these for real migration.
    [string]$SystemDriveRoot = 'C:\',
    [string]$UserProfileRoot = $env:USERPROFILE,
    [switch]$TestMode,
    [switch]$AllowNonFDriveForTests,
    [switch]$SkipProcessCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'PythonPortableCommon.psm1'
Import-Module $modulePath -Force

Invoke-PortablePythonMigration `
    -TargetRoot $TargetRoot `
    -SystemDriveRoot $SystemDriveRoot `
    -UserProfileRoot $UserProfileRoot `
    -EmbeddedPythonZip $EmbeddedPythonZip `
    -DownloadIfMissing:$DownloadIfMissing `
    -AllowedRemnantBytes $AllowedRemnantBytes `
    -TestMode:$TestMode `
    -AllowNonFDriveForTests:$AllowNonFDriveForTests `
    -SkipProcessCheck:$SkipProcessCheck
