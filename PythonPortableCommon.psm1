Set-StrictMode -Version Latest

function ConvertTo-PortableRelativePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SystemDriveRoot
    )

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [System.IO.Path]::GetFullPath($SystemDriveRoot).TrimEnd('\')
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside system drive root: $full"
    }

    $relative = $full.Substring($root.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relative)) {
        throw "Refusing to map system drive root itself."
    }
    return $relative
}

function Join-PortablePath {
    param([Parameter(Mandatory)][string[]]$Parts)

    $current = $Parts[0]
    for ($i = 1; $i -lt $Parts.Count; $i++) {
        $current = Join-Path -Path $current -ChildPath $Parts[$i]
    }
    return $current
}

function Test-PathIsOnDrive {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DriveLetter
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.StartsWith("$DriveLetter`:\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-PortableTarget {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [switch]$AllowNonFDriveForTests
    )

    if (-not $AllowNonFDriveForTests -and -not (Test-PathIsOnDrive -Path $TargetRoot -DriveLetter 'F')) {
        throw "TargetRoot must be on F: unless -AllowNonFDriveForTests is used. TargetRoot: $TargetRoot"
    }

    if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
    }

    $probe = Join-Path $TargetRoot ".write-test-$([Guid]::NewGuid().ToString('n')).tmp"
    try {
        Set-Content -LiteralPath $probe -Value 'ok' -Encoding ASCII -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
    } catch {
        throw "TargetRoot is not writable: $TargetRoot. $($_.Exception.Message)"
    }
}

function Get-PortablePythonContext {
    param(
        [string]$TargetRoot = 'F:\backup\windowsapps\AppsBackups\python',
        [string]$SystemDriveRoot = 'C:\',
        [string]$UserProfileRoot = $env:USERPROFILE,
        [switch]$TestMode,
        [switch]$AllowNonFDriveForTests
    )

    $target = [System.IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
    $system = [System.IO.Path]::GetFullPath($SystemDriveRoot).TrimEnd('\')
    $profile = [System.IO.Path]::GetFullPath($UserProfileRoot).TrimEnd('\')

    [pscustomobject]@{
        TargetRoot = $target
        SystemDriveRoot = $system
        UserProfileRoot = $profile
        TestMode = [bool]$TestMode
        AllowNonFDriveForTests = [bool]$AllowNonFDriveForTests
        BinRoot = Join-Path $target 'bin'
        MigratedRoot = Join-Path $target 'migrated'
        RuntimeRoot = Join-Path $target 'runtime'
        ConfigRoot = Join-Path $target 'config'
        PipRoot = Join-Path $target 'pip'
        PipCacheRoot = Join-Path $target 'pip-cache'
        UserBaseRoot = Join-Path $target 'userbase'
        PyCacheRoot = Join-Path $target 'pycache'
        ManifestPath = Join-Path $target 'python-portable-migration-manifest.json'
        TestEnvironmentPath = Join-Path $target 'test-env.json'
    }
}

function Get-DirectorySizeBytes {
    param([Parameter(Mandatory)][string]$Path)

    $total = [UInt64]0
    if (-not (Test-Path -LiteralPath $Path)) {
        return $total
    }
    Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $total += [UInt64]$_.Length
    }
    return $total
}

function Get-PythonProcessSnapshot {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match '^(python|pythonw|py|pip|idle|jupyter|ipython)$' } |
        Select-Object Id, ProcessName, Path
}

function Assert-NoPythonProcesses {
    param([switch]$SkipProcessCheck)

    if ($SkipProcessCheck) {
        return
    }
    $running = @(Get-PythonProcessSnapshot)
    if ($running.Count -gt 0) {
        $lines = $running | ForEach-Object { "$($_.ProcessName) pid=$($_.Id) path=$($_.Path)" }
        throw "Python-related processes are running. Stop them before migration:`n$($lines -join "`n")"
    }
}

function Get-PythonDiscovery {
    param([Parameter(Mandatory)]$Context)

    $profile = $Context.UserProfileRoot
    $system = $Context.SystemDriveRoot
    $knownCandidates = New-Object System.Collections.Generic.List[string]
    $knownUnsupported = New-Object System.Collections.Generic.List[string]

    $knownRelativeCandidates = @(
        'Users\micha\AppData\Local\Programs\Python',
        'Users\micha\AppData\Roaming\Python',
        'Users\micha\AppData\Local\Python',
        'Users\micha\AppData\Local\pip',
        'Users\micha\AppData\Roaming\pip',
        'Users\micha\AppData\Local\pypa',
        'Users\micha\AppData\Roaming\pypa',
        'ProgramData\Python',
        'ProgramData\pip'
    )

    foreach ($rel in $knownRelativeCandidates) {
        $path = Join-Path $system $rel
        if (Test-Path -LiteralPath $path) {
            $knownCandidates.Add($path)
        }
    }

    $derivedProfileCandidates = @(
        (Join-Path $profile 'AppData\Local\Programs\Python'),
        (Join-Path $profile 'AppData\Roaming\Python'),
        (Join-Path $profile 'AppData\Local\Python'),
        (Join-Path $profile 'AppData\Local\pip'),
        (Join-Path $profile 'AppData\Roaming\pip'),
        (Join-Path $profile 'pip'),
        (Join-Path $profile '.cache\pip')
    )
    foreach ($path in $derivedProfileCandidates) {
        if (Test-Path -LiteralPath $path) {
            $knownCandidates.Add($path)
        }
    }

    $knownRelativeUnsupported = @(
        'Program Files\WindowsApps\PythonSoftwareFoundation.Python*',
        'Program Files\WindowsApps\PythonSoftwareFoundation.PythonLauncher*',
        'Users\micha\AppData\Local\Packages\PythonSoftwareFoundation.Python*',
        'ProgramData\Packages\PythonSoftwareFoundation.Python*'
    )
    foreach ($pattern in $knownRelativeUnsupported) {
        $parent = Split-Path -Path (Join-Path $system $pattern) -Parent
        $leaf = Split-Path -Path $pattern -Leaf
        if (Test-Path -LiteralPath $parent) {
            Get-ChildItem -LiteralPath $parent -Directory -Force -Filter $leaf -ErrorAction SilentlyContinue |
                ForEach-Object { $knownUnsupported.Add($_.FullName) }
        }
    }

    $scanRoots = @(
        (Join-Path $system 'Program Files'),
        (Join-Path $system 'Program Files (x86)'),
        (Join-Path $system 'ProgramData'),
        (Join-Path $profile 'AppData\Local'),
        (Join-Path $profile 'AppData\Roaming')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }

    $knownSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $knownCandidates) {
        [void]$knownSet.Add(([System.IO.Path]::GetFullPath($candidate).TrimEnd('\')))
    }
    $unsupportedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $knownUnsupported) {
        [void]$unsupportedSet.Add(([System.IO.Path]::GetFullPath($candidate).TrimEnd('\')))
    }

    $suspicious = New-Object System.Collections.Generic.List[string]
    foreach ($root in $scanRoots) {
        Get-ChildItem -LiteralPath $root -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match '(?i)python|pip|pypa' -and
                -not $knownSet.Contains($_.FullName.TrimEnd('\')) -and
                -not $unsupportedSet.Contains($_.FullName.TrimEnd('\'))
            } |
            ForEach-Object { $suspicious.Add($_.FullName) }
    }

    $candidateObjects = $knownCandidates |
        Sort-Object -Unique |
        Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object {
            [pscustomobject]@{
                Path = [System.IO.Path]::GetFullPath($_).TrimEnd('\')
                Bytes = Get-DirectorySizeBytes -Path $_
                Classification = 'MovableKnownPythonData'
            }
        }

    $unsupportedObjects = $knownUnsupported |
        Sort-Object -Unique |
        Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object {
            [pscustomobject]@{
                Path = [System.IO.Path]::GetFullPath($_).TrimEnd('\')
                Bytes = Get-DirectorySizeBytes -Path $_
                Classification = 'UnsupportedWindowsStoreOrPackagePython'
            }
        }

    $suspiciousObjects = $suspicious |
        Sort-Object -Unique |
        Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object {
            [pscustomobject]@{
                Path = [System.IO.Path]::GetFullPath($_).TrimEnd('\')
                Bytes = Get-DirectorySizeBytes -Path $_
                Classification = 'SuspiciousUnclassifiedPythonPath'
            }
        }

    [pscustomobject]@{
        Candidates = @($candidateObjects)
        Unsupported = @($unsupportedObjects)
        Suspicious = @($suspiciousObjects)
    }
}

function New-PortablePythonManifest {
    param([Parameter(Mandatory)]$Context)

    [ordered]@{
        Schema = 'python-portable-migration-v1'
        CreatedAt = (Get-Date).ToString('o')
        TargetRoot = $Context.TargetRoot
        SystemDriveRoot = $Context.SystemDriveRoot
        UserProfileRoot = $Context.UserProfileRoot
        TestMode = $Context.TestMode
        MovedItems = @()
        CreatedItems = @()
        EnvironmentChanges = @()
        PathEntriesRemoved = @()
        RemovedUnsupportedItems = @()
        UnsupportedRemnants = @()
        Verification = @()
    }
}

function Add-ManifestArrayItem {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)]$Value
    )
    $Manifest[$Key] = @($Manifest[$Key]) + @($Value)
}

function Save-PortablePythonManifest {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory)][string]$Path
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-PortablePythonManifest {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Manifest not found: $Path"
    }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Move-PythonCandidateToTarget {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory)][string]$OriginalPath
    )

    $relative = ConvertTo-PortableRelativePath -Path $OriginalPath -SystemDriveRoot $Context.SystemDriveRoot
    $destination = Join-PortablePath @($Context.MigratedRoot, 'C', $relative)
    $destinationParent = Split-Path -Path $destination -Parent
    if (-not (Test-Path -LiteralPath $destinationParent)) {
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    }

    if (Test-Path -LiteralPath $destination) {
        throw "Destination already exists; refusing to overwrite: $destination"
    }

    Move-Item -LiteralPath $OriginalPath -Destination $destination -Force -ErrorAction Stop
    Add-ManifestArrayItem -Manifest $Manifest -Key 'MovedItems' -Value ([ordered]@{
        OriginalPath = $OriginalPath
        ExternalPath = $destination
        Type = 'Directory'
    })
}

function Find-PortablePythonCommand {
    param([Parameter(Mandatory)]$Context)

    $roots = @($Context.MigratedRoot, $Context.RuntimeRoot)
    $patterns = if ($Context.TestMode) { @('python.cmd', 'python.exe') } else { @('python.exe') }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        foreach ($pattern in $patterns) {
            $found = Get-ChildItem -LiteralPath $root -Recurse -Force -File -Filter $pattern -ErrorAction SilentlyContinue |
                Sort-Object FullName |
                Select-Object -First 1
            if ($found) {
                return $found.FullName
            }
        }
    }
    return $null
}

function Get-ExternalPythonPathEntries {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$PythonCommand
    )

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($Context.BinRoot, (Split-Path -Path $PythonCommand -Parent))) {
        if ($path -and -not $entries.Contains($path)) {
            $entries.Add($path)
        }
    }

    $searchRoots = @($Context.MigratedRoot, $Context.RuntimeRoot) | Where-Object { Test-Path -LiteralPath $_ }
    foreach ($root in $searchRoots) {
        Get-ChildItem -LiteralPath $root -Directory -Recurse -Force -Filter 'Scripts' -ErrorAction SilentlyContinue |
            ForEach-Object {
                if (-not $entries.Contains($_.FullName)) {
                    $entries.Add($_.FullName)
                }
            }
    }
    return @($entries)
}

function Get-CDrivePythonEnvironmentEntries {
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Name = 'Path',
        [string]$Scope = 'User'
    )

    $value = Get-PortableEnvironmentValue -Context $Context -Name $Name -Scope $Scope
    if ([string]::IsNullOrWhiteSpace($value)) {
        return @()
    }
    $system = $Context.SystemDriveRoot.TrimEnd('\')
    @($value -split ';' | Where-Object {
        $expanded = [Environment]::ExpandEnvironmentVariables($_)
        $expanded.StartsWith($system, [System.StringComparison]::OrdinalIgnoreCase) -and $expanded -match '(?i)python|pip|pypa'
    })
}

function Assert-NoBlockingMachinePythonEnvironment {
    param([Parameter(Mandatory)]$Context)

    if ($Context.TestMode) {
        return
    }

    $blocking = @()
    foreach ($name in @('Path','PYTHONPATH','PYTHONHOME','PYTHONUSERBASE','PYTHONPYCACHEPREFIX','PIP_CACHE_DIR','PIP_CONFIG_FILE')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Machine')
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        $expanded = [Environment]::ExpandEnvironmentVariables($value)
        if ($expanded.StartsWith($Context.SystemDriveRoot.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) -and $expanded -match '(?i)python|pip|pypa') {
            $blocking += "$name=$value"
        }
        if ($name -eq 'Path') {
            $blocking += @(Get-CDrivePythonEnvironmentEntries -Context $Context -Name $name -Scope 'Machine' | ForEach-Object { "Path entry=$_" })
        }
    }

    if ($blocking.Count -gt 0) {
        throw "Machine-level Python environment entries still point at C:. Remove or migrate them explicitly, then rerun:`n$($blocking -join "`n")"
    }
}

function Resolve-LatestEmbeddablePythonUri {
    $page = Invoke-WebRequest -Uri 'https://www.python.org/downloads/windows/' -UseBasicParsing -ErrorAction Stop
    $matches = [regex]::Matches($page.Content, 'https://www\.python\.org/ftp/python/([0-9]+\.[0-9]+\.[0-9]+)/python-\1-embed-amd64\.zip')
    if ($matches.Count -eq 0) {
        throw 'Could not find a python.org embeddable amd64 zip link.'
    }
    $items = foreach ($m in $matches) {
        [pscustomobject]@{ Version = [version]$m.Groups[1].Value; Uri = $m.Value }
    }
    ($items | Sort-Object Version -Descending | Select-Object -First 1).Uri
}

function Install-FreshPortablePython {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [string]$EmbeddedPythonZip,
        [switch]$DownloadIfMissing
    )

    $runtime = Join-Path $Context.RuntimeRoot 'python'
    if (-not (Test-Path -LiteralPath $runtime)) {
        New-Item -ItemType Directory -Path $runtime -Force | Out-Null
        Add-ManifestArrayItem -Manifest $Manifest -Key 'CreatedItems' -Value $runtime
    }

    $zipPath = $EmbeddedPythonZip
    if ([string]::IsNullOrWhiteSpace($zipPath)) {
        if (-not $DownloadIfMissing) {
            throw 'No existing Python was found. Provide -EmbeddedPythonZip or use -DownloadIfMissing to bootstrap a portable Python runtime.'
        }
        if ($Context.TestMode) {
            throw 'TestMode requires -EmbeddedPythonZip; it will not download.'
        }
        $uri = Resolve-LatestEmbeddablePythonUri
        $zipPath = Join-Path $Context.TargetRoot 'downloads\python-embed-amd64.zip'
        New-Item -ItemType Directory -Path (Split-Path -Path $zipPath -Parent) -Force | Out-Null
        Invoke-WebRequest -Uri $uri -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        Add-ManifestArrayItem -Manifest $Manifest -Key 'CreatedItems' -Value $zipPath
    }

    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
        throw "Embedded Python zip not found: $zipPath"
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $runtime -Force
    $pth = Get-ChildItem -LiteralPath $runtime -Filter 'python*._pth' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pth) {
        $content = Get-Content -LiteralPath $pth.FullName
        $content = $content | ForEach-Object { if ($_ -eq '#import site') { 'import site' } else { $_ } }
        Set-Content -LiteralPath $pth.FullName -Value $content -Encoding ASCII
    }

    Add-ManifestArrayItem -Manifest $Manifest -Key 'CreatedItems' -Value $runtime
}

function New-PortablePythonWrappers {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory)][string]$PythonCommand
    )

    New-Item -ItemType Directory -Path $Context.BinRoot -Force | Out-Null
    Add-ManifestArrayItem -Manifest $Manifest -Key 'CreatedItems' -Value $Context.BinRoot

    $pythonEscaped = $PythonCommand.Replace('%', '%%')
    $pythonWrapper = @"
@echo off
set "PYTHONHOME="
set "PYTHONUSERBASE=$($Context.UserBaseRoot)"
set "PYTHONPYCACHEPREFIX=$($Context.PyCacheRoot)"
set "PIP_CACHE_DIR=$($Context.PipCacheRoot)"
set "PIP_CONFIG_FILE=$($Context.PipRoot)\pip.ini"
"$pythonEscaped" %*
"@
    $pythonCmd = Join-Path $Context.BinRoot 'python.cmd'
    Set-Content -LiteralPath $pythonCmd -Value $pythonWrapper -Encoding ASCII
    Add-ManifestArrayItem -Manifest $Manifest -Key 'CreatedItems' -Value $pythonCmd

    $pyCmd = Join-Path $Context.BinRoot 'py.cmd'
    Set-Content -LiteralPath $pyCmd -Value $pythonWrapper -Encoding ASCII
    Add-ManifestArrayItem -Manifest $Manifest -Key 'CreatedItems' -Value $pyCmd

    $pipWrapper = @"
@echo off
set "PYTHONHOME="
set "PYTHONUSERBASE=$($Context.UserBaseRoot)"
set "PYTHONPYCACHEPREFIX=$($Context.PyCacheRoot)"
set "PIP_CACHE_DIR=$($Context.PipCacheRoot)"
set "PIP_CONFIG_FILE=$($Context.PipRoot)\pip.ini"
"$pythonEscaped" -m pip %*
"@
    $pipCmd = Join-Path $Context.BinRoot 'pip.cmd'
    Set-Content -LiteralPath $pipCmd -Value $pipWrapper -Encoding ASCII
    Add-ManifestArrayItem -Manifest $Manifest -Key 'CreatedItems' -Value $pipCmd

    New-Item -ItemType Directory -Path $Context.PipRoot,$Context.PipCacheRoot,$Context.UserBaseRoot,$Context.PyCacheRoot -Force | Out-Null
    foreach ($path in @($Context.PipRoot,$Context.PipCacheRoot,$Context.UserBaseRoot,$Context.PyCacheRoot)) {
        Add-ManifestArrayItem -Manifest $Manifest -Key 'CreatedItems' -Value $path
    }

    $pipIni = Join-Path $Context.PipRoot 'pip.ini'
    $pipIniContent = @"
[global]
cache-dir = $($Context.PipCacheRoot.Replace('\','/'))

[install]
user = true
"@
    Set-Content -LiteralPath $pipIni -Value $pipIniContent -Encoding ASCII
    Add-ManifestArrayItem -Manifest $Manifest -Key 'CreatedItems' -Value $pipIni
}

function Remove-UnsupportedPythonPackages {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory)]$UnsupportedItems,
        [switch]$RemoveStorePythonPackages
    )

    $blocking = @($UnsupportedItems | Where-Object { $_.Bytes -gt 0 })
    if ($blocking.Count -eq 0) {
        return
    }
    if (-not $RemoveStorePythonPackages) {
        $Manifest['UnsupportedRemnants'] = @($blocking)
        Save-PortablePythonManifest -Manifest $Manifest -Path $Context.ManifestPath
        $details = $blocking | ForEach-Object { "$($_.Classification): $($_.Path) ($($_.Bytes) bytes)" }
        throw "Unclassified or unsupported Python-related C: paths were found. Refusing to guess:`n$($details -join "`n")"
    }

    if ($Context.TestMode) {
        foreach ($item in $blocking) {
            $relative = ConvertTo-PortableRelativePath -Path $item.Path -SystemDriveRoot $Context.SystemDriveRoot
            $quarantine = Join-PortablePath @($Context.MigratedRoot, 'removed-unsupported-C', $relative)
            New-Item -ItemType Directory -Path (Split-Path -Path $quarantine -Parent) -Force | Out-Null
            Move-Item -LiteralPath $item.Path -Destination $quarantine -Force
            Add-ManifestArrayItem -Manifest $Manifest -Key 'RemovedUnsupportedItems' -Value ([ordered]@{
                OriginalPath = $item.Path
                ExternalPath = $quarantine
                Method = 'TestModeMove'
            })
        }
        return
    }

    $packages = @(Get-AppxPackage -AllUsers -Name 'PythonSoftwareFoundation.Python*' -ErrorAction SilentlyContinue)
    if ($packages.Count -eq 0) {
        $Manifest['UnsupportedRemnants'] = @($blocking)
        Save-PortablePythonManifest -Manifest $Manifest -Path $Context.ManifestPath
        $details = $blocking | ForEach-Object { "$($_.Classification): $($_.Path) ($($_.Bytes) bytes)" }
        throw "Store Python remnants exist but no removable Appx package was found:`n$($details -join "`n")"
    }
    foreach ($pkg in $packages) {
        Add-ManifestArrayItem -Manifest $Manifest -Key 'RemovedUnsupportedItems' -Value ([ordered]@{
            PackageFullName = $pkg.PackageFullName
            Name = $pkg.Name
            InstallLocation = $pkg.InstallLocation
            Method = 'Remove-AppxPackage'
        })
        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
    }
}

function Get-PortableEnvironmentValue {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        [string]$Scope = 'User'
    )
    if ($Context.TestMode) {
        if (Test-Path -LiteralPath $Context.TestEnvironmentPath) {
            $envJson = Get-Content -LiteralPath $Context.TestEnvironmentPath -Raw | ConvertFrom-Json
            $prop = $envJson.PSObject.Properties[$Name]
            if ($prop) { return [string]$prop.Value }
        }
        return $null
    }
    return [Environment]::GetEnvironmentVariable($Name, $Scope)
}

function Set-PortableEnvironmentValue {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$Value,
        [string]$Scope = 'User'
    )

    $oldValue = Get-PortableEnvironmentValue -Context $Context -Name $Name -Scope $Scope
    Add-ManifestArrayItem -Manifest $Manifest -Key 'EnvironmentChanges' -Value ([ordered]@{
        Name = $Name
        Scope = $Scope
        OldValue = $oldValue
        NewValue = $Value
        OldValueWasNull = ($null -eq $oldValue)
    })

    if ($Context.TestMode) {
        $hash = [ordered]@{}
        if (Test-Path -LiteralPath $Context.TestEnvironmentPath) {
            $existing = Get-Content -LiteralPath $Context.TestEnvironmentPath -Raw | ConvertFrom-Json
            foreach ($p in $existing.PSObject.Properties) { $hash[$p.Name] = $p.Value }
        }
        if ($null -eq $Value) {
            [void]$hash.Remove($Name)
        } else {
            $hash[$Name] = $Value
        }
        $hash | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Context.TestEnvironmentPath -Encoding UTF8
    } else {
        [Environment]::SetEnvironmentVariable($Name, $Value, $Scope)
    }
}

function Remove-CDrivePythonPathEntries {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [string[]]$ExternalPathEntries = @($Context.BinRoot),
        [string]$Scope = 'User'
    )

    $pathValue = Get-PortableEnvironmentValue -Context $Context -Name 'Path' -Scope $Scope
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($pathValue)) {
        $entries = @($pathValue -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $system = $Context.SystemDriveRoot.TrimEnd('\')
    $kept = New-Object System.Collections.Generic.List[string]
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $entries) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry)
        if ($expanded.StartsWith($system, [System.StringComparison]::OrdinalIgnoreCase) -and $expanded -match '(?i)python|pip') {
            $removed.Add($entry)
        } else {
            $kept.Add($entry)
        }
    }
    foreach ($entry in $removed) {
        Add-ManifestArrayItem -Manifest $Manifest -Key 'PathEntriesRemoved' -Value ([ordered]@{ Scope = $Scope; Entry = $entry })
    }
    $newEntries = @($ExternalPathEntries) + @($kept | Where-Object { $ExternalPathEntries -notcontains $_ })
    Set-PortableEnvironmentValue -Context $Context -Manifest $Manifest -Name 'Path' -Value ($newEntries -join ';') -Scope $Scope
}

function Set-PortablePythonEnvironment {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory)][string]$PythonCommand,
        [string]$Scope = 'User'
    )

    $externalPathEntries = Get-ExternalPythonPathEntries -Context $Context -PythonCommand $PythonCommand
    Remove-CDrivePythonPathEntries -Context $Context -Manifest $Manifest -ExternalPathEntries $externalPathEntries -Scope $Scope
    Set-PortableEnvironmentValue -Context $Context -Manifest $Manifest -Name 'PYTHONUSERBASE' -Value $Context.UserBaseRoot -Scope $Scope
    Set-PortableEnvironmentValue -Context $Context -Manifest $Manifest -Name 'PYTHONPYCACHEPREFIX' -Value $Context.PyCacheRoot -Scope $Scope
    Set-PortableEnvironmentValue -Context $Context -Manifest $Manifest -Name 'PIP_CACHE_DIR' -Value $Context.PipCacheRoot -Scope $Scope
    Set-PortableEnvironmentValue -Context $Context -Manifest $Manifest -Name 'PIP_CONFIG_FILE' -Value (Join-Path $Context.PipRoot 'pip.ini') -Scope $Scope

    $pythonPath = Get-PortableEnvironmentValue -Context $Context -Name 'PYTHONPATH' -Scope $Scope
    if ($pythonPath) {
        $system = $Context.SystemDriveRoot.TrimEnd('\')
        $kept = @($pythonPath -split ';' | Where-Object {
            -not ([Environment]::ExpandEnvironmentVariables($_).StartsWith($system, [System.StringComparison]::OrdinalIgnoreCase) -and $_ -match '(?i)python|pip')
        })
        Set-PortableEnvironmentValue -Context $Context -Manifest $Manifest -Name 'PYTHONPATH' -Value ($kept -join ';') -Scope $Scope
    }
}

function Test-NoCDrivePythonRemnants {
    param(
        [Parameter(Mandatory)]$Context,
        [UInt64]$AllowedBytes = 0
    )

    $discovery = Get-PythonDiscovery -Context $Context
    $blocking = @($discovery.Candidates + $discovery.Unsupported + $discovery.Suspicious | Where-Object { $_.Bytes -gt $AllowedBytes })
    return [pscustomobject]@{
        Passed = ($blocking.Count -eq 0)
        Blocking = $blocking
    }
}

function Invoke-PortablePythonVerification {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [UInt64]$AllowedRemnantBytes = 0
    )

    $pythonCmd = Join-Path $Context.BinRoot 'python.cmd'
    $pipCmd = Join-Path $Context.BinRoot 'pip.cmd'
    foreach ($path in @($pythonCmd,$pipCmd,(Join-Path $Context.BinRoot 'py.cmd'))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required wrapper missing: $path"
        }
    }

    $userPathEntries = @(Get-ExternalPythonPathEntries -Context $Context -PythonCommand (Find-PortablePythonCommand -Context $Context))
    foreach ($entry in $userPathEntries) {
        if (-not (Test-Path -LiteralPath $entry -PathType Container)) {
            throw "Expected external Python PATH entry missing: $entry"
        }
    }

    $remnants = Test-NoCDrivePythonRemnants -Context $Context -AllowedBytes $AllowedRemnantBytes
    if (-not $remnants.Passed) {
        $Manifest['UnsupportedRemnants'] = @($remnants.Blocking)
        $details = $remnants.Blocking | ForEach-Object { "$($_.Classification): $($_.Path) ($($_.Bytes) bytes)" }
        throw "Python-related C: remnants remain above threshold:`n$($details -join "`n")"
    }

    if ($Context.TestMode) {
        Add-ManifestArrayItem -Manifest $Manifest -Key 'Verification' -Value 'TestMode wrappers and remnant checks passed.'
        return
    }

    $version = & $pythonCmd --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Portable python wrapper failed: $version"
    }
    $pipVersion = & $pipCmd --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Portable pip wrapper failed: $pipVersion"
    }
    Add-ManifestArrayItem -Manifest $Manifest -Key 'Verification' -Value "python --version: $version"
    Add-ManifestArrayItem -Manifest $Manifest -Key 'Verification' -Value "pip --version: $pipVersion"
}

function Invoke-PortablePythonMigration {
    param(
        [string]$TargetRoot = 'F:\backup\windowsapps\AppsBackups\python',
        [string]$SystemDriveRoot = 'C:\',
        [string]$UserProfileRoot = $env:USERPROFILE,
        [string]$EmbeddedPythonZip,
        [switch]$DownloadIfMissing,
        [switch]$TestMode,
        [switch]$AllowNonFDriveForTests,
        [switch]$SkipProcessCheck,
        [switch]$RemoveStorePythonPackages,
        [UInt64]$AllowedRemnantBytes = 0
    )

    $context = Get-PortablePythonContext -TargetRoot $TargetRoot -SystemDriveRoot $SystemDriveRoot -UserProfileRoot $UserProfileRoot -TestMode:$TestMode -AllowNonFDriveForTests:$AllowNonFDriveForTests
    Assert-PortableTarget -TargetRoot $context.TargetRoot -AllowNonFDriveForTests:$AllowNonFDriveForTests
    Assert-NoPythonProcesses -SkipProcessCheck:$SkipProcessCheck

    if (Test-Path -LiteralPath $context.ManifestPath -PathType Leaf) {
        throw "Existing manifest found. Run undo first or move the old target aside: $($context.ManifestPath)"
    }

    $manifest = New-PortablePythonManifest -Context $context
    $discovery = Get-PythonDiscovery -Context $context

    if ($discovery.Suspicious.Count -gt 0) {
        $blocking = @($discovery.Suspicious | Where-Object { $_.Bytes -gt $AllowedRemnantBytes })
        if ($blocking.Count -gt 0) {
            $manifest['UnsupportedRemnants'] = @($blocking)
            Save-PortablePythonManifest -Manifest $manifest -Path $context.ManifestPath
            $details = $blocking | ForEach-Object { "$($_.Classification): $($_.Path) ($($_.Bytes) bytes)" }
            throw "Unclassified Python-related C: paths were found. Refusing to guess:`n$($details -join "`n")"
        }
    }

    Remove-UnsupportedPythonPackages -Context $context -Manifest $manifest -UnsupportedItems $discovery.Unsupported -RemoveStorePythonPackages:$RemoveStorePythonPackages
    Save-PortablePythonManifest -Manifest $manifest -Path $context.ManifestPath

    if ($discovery.Candidates.Count -eq 0) {
        Install-FreshPortablePython -Context $context -Manifest $manifest -EmbeddedPythonZip $EmbeddedPythonZip -DownloadIfMissing:$DownloadIfMissing
        Save-PortablePythonManifest -Manifest $manifest -Path $context.ManifestPath
    } else {
        foreach ($candidate in $discovery.Candidates) {
            Move-PythonCandidateToTarget -Context $context -Manifest $manifest -OriginalPath $candidate.Path
            Save-PortablePythonManifest -Manifest $manifest -Path $context.ManifestPath
        }
    }

    $pythonCommand = Find-PortablePythonCommand -Context $context
    if (-not $pythonCommand) {
        throw "No portable python command was found under target after move/bootstrap."
    }

    New-PortablePythonWrappers -Context $context -Manifest $manifest -PythonCommand $pythonCommand
    Save-PortablePythonManifest -Manifest $manifest -Path $context.ManifestPath
    Set-PortablePythonEnvironment -Context $context -Manifest $manifest -PythonCommand $pythonCommand -Scope 'User'
    Save-PortablePythonManifest -Manifest $manifest -Path $context.ManifestPath
    Assert-NoBlockingMachinePythonEnvironment -Context $context
    Invoke-PortablePythonVerification -Context $context -Manifest $manifest -AllowedRemnantBytes $AllowedRemnantBytes
    Save-PortablePythonManifest -Manifest $manifest -Path $context.ManifestPath

    [pscustomobject]@{
        Status = 'Ready'
        ManifestPath = $context.ManifestPath
        TargetRoot = $context.TargetRoot
        PythonCommand = $pythonCommand
    }
}

function Restore-PortableEnvironmentChanges {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Manifest
    )

    $changes = @($Manifest.EnvironmentChanges)
    [array]::Reverse($changes)
    foreach ($change in $changes) {
        if ($Context.TestMode) {
            $hash = [ordered]@{}
            if (Test-Path -LiteralPath $Context.TestEnvironmentPath) {
                $existing = Get-Content -LiteralPath $Context.TestEnvironmentPath -Raw | ConvertFrom-Json
                foreach ($p in $existing.PSObject.Properties) { $hash[$p.Name] = $p.Value }
            }
            if ($change.OldValueWasNull) {
                [void]$hash.Remove($change.Name)
            } else {
                $hash[$change.Name] = $change.OldValue
            }
            $hash | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Context.TestEnvironmentPath -Encoding UTF8
        } else {
            $old = if ($change.OldValueWasNull) { $null } else { [string]$change.OldValue }
            [Environment]::SetEnvironmentVariable([string]$change.Name, $old, [string]$change.Scope)
        }
    }
}

function Invoke-PortablePythonUndo {
    param(
        [string]$TargetRoot = 'F:\backup\windowsapps\AppsBackups\python',
        [string]$SystemDriveRoot = 'C:\',
        [string]$UserProfileRoot = $env:USERPROFILE,
        [switch]$TestMode,
        [switch]$AllowNonFDriveForTests,
        [switch]$SkipProcessCheck,
        [switch]$AttemptStorePythonPackageReinstall
    )

    $context = Get-PortablePythonContext -TargetRoot $TargetRoot -SystemDriveRoot $SystemDriveRoot -UserProfileRoot $UserProfileRoot -TestMode:$TestMode -AllowNonFDriveForTests:$AllowNonFDriveForTests
    Assert-NoPythonProcesses -SkipProcessCheck:$SkipProcessCheck
    $undoReceipt = Join-Path $context.TargetRoot 'python-portable-migration-manifest.undone.json'
    if (-not (Test-Path -LiteralPath $context.ManifestPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $undoReceipt -PathType Leaf) {
            return [pscustomobject]@{
                Status = 'AlreadyUndone'
                TargetRoot = $context.TargetRoot
            }
        }
        throw "Manifest not found: $($context.ManifestPath)"
    }
    $manifest = Read-PortablePythonManifest -Path $context.ManifestPath

    Restore-PortableEnvironmentChanges -Context $context -Manifest $manifest

    $moved = @($manifest.MovedItems)
    [array]::Reverse($moved)
    foreach ($item in $moved) {
        if ((Test-Path -LiteralPath $item.OriginalPath) -and (Test-Path -LiteralPath $item.ExternalPath)) {
            throw "Undo would overwrite existing original path: $($item.OriginalPath)"
        }
        if (Test-Path -LiteralPath $item.ExternalPath) {
            $parent = Split-Path -Path $item.OriginalPath -Parent
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Move-Item -LiteralPath $item.ExternalPath -Destination $item.OriginalPath -Force
        }
    }

    $removedUnsupported = @($manifest.RemovedUnsupportedItems)
    [array]::Reverse($removedUnsupported)
    foreach ($item in $removedUnsupported) {
        if ($item.Method -eq 'TestModeMove' -and (Test-Path -LiteralPath $item.ExternalPath)) {
            $parent = Split-Path -Path $item.OriginalPath -Parent
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Move-Item -LiteralPath $item.ExternalPath -Destination $item.OriginalPath -Force
        } elseif ($item.Method -eq 'Remove-AppxPackage') {
            if ($AttemptStorePythonPackageReinstall) {
                $wingetId = $null
                if ($item.Name -match 'Python\.3\.([0-9]+)') {
                    $wingetId = "Python.Python.3.$($Matches[1])"
                }
                if (-not $wingetId) {
                    Write-Warning "Cannot infer winget id for removed Store package: $($item.PackageFullName)"
                } else {
                    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
                    if (-not $winget) {
                        Write-Warning "winget.exe not found; cannot reinstall removed Store package: $($item.PackageFullName)"
                    } else {
                        & $winget.Source install --id $wingetId --exact --source winget --accept-source-agreements --accept-package-agreements
                        if ($LASTEXITCODE -ne 0) {
                            Write-Warning "winget reinstall failed for $wingetId. Reinstall manually if needed."
                        }
                    }
                }
            } else {
                Write-Warning "Undo cannot reliably reinstall removed Store package automatically unless -AttemptStorePythonPackageReinstall is used: $($item.PackageFullName)."
            }
        }
    }

    $created = @($manifest.CreatedItems) | Sort-Object { $_.Length } -Descending -Unique
    foreach ($path in $created) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Copy-Item -LiteralPath $context.ManifestPath -Destination $undoReceipt -Force
    Remove-Item -LiteralPath $context.ManifestPath -Force

    [pscustomobject]@{
        Status = 'Undone'
        TargetRoot = $context.TargetRoot
    }
}

Export-ModuleMember -Function @(
    'Invoke-PortablePythonMigration',
    'Invoke-PortablePythonUndo',
    'Get-PythonDiscovery',
    'Get-PortablePythonContext',
    'Test-NoCDrivePythonRemnants',
    'Resolve-LatestEmbeddablePythonUri'
)
