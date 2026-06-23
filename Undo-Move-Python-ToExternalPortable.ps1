[CmdletBinding()]
param(
    [string]$TargetRoot = 'F:\backup\windowsapps\AppsBackups\python',

    # Test harness only. Do not use these for real undo.
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

Invoke-PortablePythonUndo `
    -TargetRoot $TargetRoot `
    -SystemDriveRoot $SystemDriveRoot `
    -UserProfileRoot $UserProfileRoot `
    -TestMode:$TestMode `
    -AllowNonFDriveForTests:$AllowNonFDriveForTests `
    -SkipProcessCheck:$SkipProcessCheck
