[CmdletBinding()]
param(
    [string]$TargetRoot = 'F:\backup\windowsapps\AppsBackups\python',

    # Test harness only. Do not use these for real undo.
    [string]$SystemDriveRoot = 'C:\',
    [string]$UserProfileRoot = $env:USERPROFILE,
    [switch]$TestMode,
    [switch]$AllowNonFDriveForTests,
    [switch]$SkipProcessCheck,
    [switch]$StopBlockingPythonProcesses,
    [switch]$PreserveBlockingPythonProcesses,
    [string]$ProcessPathRootForTests,
    [switch]$AttemptStorePythonPackageReinstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'PythonPortableCommon.psm1'
Import-Module $modulePath -Force

try {
    $shouldStopBlockingPythonProcesses = (-not $PreserveBlockingPythonProcesses) -or $StopBlockingPythonProcesses
    Invoke-PortablePythonUndo `
        -TargetRoot $TargetRoot `
        -SystemDriveRoot $SystemDriveRoot `
        -UserProfileRoot $UserProfileRoot `
        -TestMode:$TestMode `
        -AllowNonFDriveForTests:$AllowNonFDriveForTests `
        -SkipProcessCheck:$SkipProcessCheck `
        -StopBlockingPythonProcesses:$shouldStopBlockingPythonProcesses `
        -ProcessPathRootForTests $ProcessPathRootForTests `
        -AttemptStorePythonPackageReinstall:$AttemptStorePythonPackageReinstall
} catch {
    Write-Host $_.Exception.Message
    exit 1
}
