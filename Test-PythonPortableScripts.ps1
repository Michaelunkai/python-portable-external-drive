[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PassCount = 0

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        throw "ASSERT FAILED: $Message"
    }
    $script:PassCount++
}

function New-TestRoot {
    $root = Join-Path $env:TEMP "python-portable-test-$([Guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    [pscustomobject]@{
        Root = $root
        C = Join-Path $root 'C'
        FTarget = Join-Path $root 'F\backup\windowsapps\AppsBackups\python'
        Profile = Join-Path $root 'C\Users\micha'
    }
}

function New-FakePythonTree {
    param([Parameter(Mandatory)]$Fixture)

    $install = Join-Path $Fixture.Profile 'AppData\Local\Programs\Python\Python313'
    $roaming = Join-Path $Fixture.Profile 'AppData\Roaming\Python\Python313\site-packages'
    New-Item -ItemType Directory -Path $install,$roaming -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $install 'python.cmd') -Value '@echo Python 3.13.0-test' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $install 'Lib.py') -Value 'print("fake")' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $roaming 'package.txt') -Value 'package' -Encoding ASCII
}

function New-FakeEmbeddableZip {
    param([Parameter(Mandatory)]$Fixture)

    $zipRoot = Join-Path $Fixture.Root 'ziproot'
    New-Item -ItemType Directory -Path $zipRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $zipRoot 'python.cmd') -Value '@echo Python 3.14.0-embedded-test' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $zipRoot 'python314._pth') -Value @('python314.zip', '.', '#import site') -Encoding ASCII
    $zip = Join-Path $Fixture.Root 'python-embed.zip'
    Compress-Archive -Path (Join-Path $zipRoot '*') -DestinationPath $zip -Force
    return $zip
}

function Quote-ProcessArgument {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"','\"') + '"'
    }
    return $Value
}

function Invoke-ChildPowerShell {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $outFile = Join-Path $env:TEMP "python-portable-child-$([Guid]::NewGuid().ToString('n')).out"
    $errFile = Join-Path $env:TEMP "python-portable-child-$([Guid]::NewGuid().ToString('n')).err"
    try {
        $process = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList (($Arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' ') `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
        $output = ''
        if (Test-Path -LiteralPath $outFile) {
            $output += (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        }
        if (Test-Path -LiteralPath $errFile) {
            $output += (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $output
        }
    } finally {
        Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MoveScript {
    param(
        [Parameter(Mandatory)]$Fixture,
    [string]$EmbeddedPythonZip,
        [switch]$DownloadIfMissing,
        [switch]$ExpectFailure,
        [switch]$RemoveStorePythonPackages,
        [switch]$EnableProcessCheck,
        [UInt64]$AllowedRemnantBytes = 0
    )

    $args = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $PSScriptRoot 'Move-Python-ToExternalPortable.ps1'),
        '-TargetRoot', $Fixture.FTarget,
        '-SystemDriveRoot', $Fixture.C,
        '-UserProfileRoot', $Fixture.Profile,
        '-TestMode',
        '-AllowNonFDriveForTests',
        '-AllowedRemnantBytes', $AllowedRemnantBytes
    )
    if (-not $EnableProcessCheck) {
        $args += '-SkipProcessCheck'
    }
    if ($EmbeddedPythonZip) {
        $args += @('-EmbeddedPythonZip', $EmbeddedPythonZip)
    }
    if ($DownloadIfMissing) {
        $args += '-DownloadIfMissing'
    }
    if ($RemoveStorePythonPackages) {
        $args += '-RemoveStorePythonPackages'
    }
    $result = Invoke-ChildPowerShell -Arguments $args
    if (-not $ExpectFailure -and $result.ExitCode -ne 0) {
        throw $result.Output
    }
    $result
}

function Invoke-UndoScript {
    param([Parameter(Mandatory)]$Fixture)
    Invoke-ChildPowerShell -Arguments @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $PSScriptRoot 'Undo-Move-Python-ToExternalPortable.ps1'),
        '-TargetRoot', $Fixture.FTarget,
        '-SystemDriveRoot', $Fixture.C,
        '-UserProfileRoot', $Fixture.Profile,
        '-TestMode',
        '-AllowNonFDriveForTests',
        '-SkipProcessCheck'
    )
}

function Test-MoveAndUndo {
    $fx = New-TestRoot
    try {
        New-FakePythonTree -Fixture $fx
        New-Item -ItemType Directory -Path $fx.FTarget -Force | Out-Null
        @{ Path = "$($fx.C)\Users\micha\AppData\Local\Programs\Python;$($fx.C)\tools" } |
            ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $fx.FTarget 'test-env.json') -Encoding UTF8

        $move = Invoke-MoveScript -Fixture $fx
        Assert-True ($move.ExitCode -eq 0) 'move script should exit 0'
        Assert-True ($move.Output -match 'Ready') 'move script should report Ready'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fx.Profile 'AppData\Local\Programs\Python'))) 'C install path should be moved'
        Assert-True (Test-Path -LiteralPath (Join-Path $fx.FTarget 'bin\python.cmd')) 'python wrapper should exist'
        Assert-True (Test-Path -LiteralPath (Join-Path $fx.FTarget 'python-portable-migration-manifest.json')) 'manifest should exist'
        $testEnv = Get-Content -LiteralPath (Join-Path $fx.FTarget 'test-env.json') -Raw | ConvertFrom-Json
        Assert-True ($testEnv.Path.StartsWith((Join-Path $fx.FTarget 'bin'))) 'PATH should start with target bin'
        Assert-True ($testEnv.Path -match [regex]::Escape((Join-Path $fx.FTarget 'migrated'))) 'PATH should include migrated external Python tree'
        Assert-True ($testEnv.PIP_CACHE_DIR -eq (Join-Path $fx.FTarget 'pip-cache')) 'PIP_CACHE_DIR should point to target'

        $undo = Invoke-UndoScript -Fixture $fx
        Assert-True ($undo.ExitCode -eq 0) 'undo should exit 0'
        Assert-True ($undo.Output -match 'Undone') 'undo should report Undone'
        Assert-True (Test-Path -LiteralPath (Join-Path $fx.Profile 'AppData\Local\Programs\Python')) 'original Python path should be restored'
        Assert-True (Test-Path -LiteralPath (Join-Path $fx.FTarget 'python-portable-migration-manifest.undone.json')) 'undo receipt should exist'

        $undoAgain = Invoke-UndoScript -Fixture $fx
        Assert-True ($undoAgain.ExitCode -eq 0) 'second undo should exit 0'
        Assert-True ($undoAgain.Output -match 'AlreadyUndone') 'second undo should be safe no-op'
    } finally {
        Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-FreshBootstrap {
    $fx = New-TestRoot
    try {
        New-Item -ItemType Directory -Path $fx.FTarget -Force | Out-Null
        $zip = New-FakeEmbeddableZip -Fixture $fx
        $move = Invoke-MoveScript -Fixture $fx -EmbeddedPythonZip $zip
        Assert-True ($move.ExitCode -eq 0) 'fresh bootstrap should exit 0'
        Assert-True ($move.Output -match 'Ready') 'fresh bootstrap should report Ready'
        Assert-True (Test-Path -LiteralPath (Join-Path $fx.FTarget 'runtime\python\python.cmd')) 'fresh runtime should be extracted'
        Assert-True (Test-Path -LiteralPath (Join-Path $fx.FTarget 'bin\pip.cmd')) 'fresh pip wrapper should exist'
    } finally {
        Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-FailClosedUnsupported {
    $fx = New-TestRoot
    try {
        New-Item -ItemType Directory -Path (Join-Path $fx.C 'Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.13_test') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $fx.C 'Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.13_test\python.exe') -Value 'fake' -Encoding ASCII
        New-Item -ItemType Directory -Path $fx.FTarget -Force | Out-Null
        $result = Invoke-MoveScript -Fixture $fx -ExpectFailure
        Assert-True ($result.ExitCode -ne 0) 'unsupported WindowsApps Python should fail closed with nonzero exit'
        Assert-True ($result.Output -match 'unsupported|Unclassified') 'unsupported failure should explain blocked path'
        Assert-True (Test-Path -LiteralPath (Join-Path $fx.FTarget 'python-portable-migration-manifest.json')) 'failed run should save manifest evidence'
    } finally {
        Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-RemoveUnsupportedInTestMode {
    $fx = New-TestRoot
    try {
        New-FakePythonTree -Fixture $fx
        $unsupported = Join-Path $fx.C 'Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.13_test'
        New-Item -ItemType Directory -Path $unsupported -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $unsupported 'python.exe') -Value 'fake' -Encoding ASCII
        New-Item -ItemType Directory -Path $fx.FTarget -Force | Out-Null
        $result = Invoke-MoveScript -Fixture $fx -RemoveStorePythonPackages
        Assert-True ($result.ExitCode -eq 0) 'RemoveStorePythonPackages test mode should succeed'
        Assert-True (-not (Test-Path -LiteralPath $unsupported)) 'unsupported path should be removed from fake C root'
        $manifest = Get-Content -LiteralPath (Join-Path $fx.FTarget 'python-portable-migration-manifest.json') -Raw | ConvertFrom-Json
        Assert-True (@($manifest.RemovedUnsupportedItems).Count -ge 1) 'manifest should record removed unsupported items'
        $undo = Invoke-UndoScript -Fixture $fx
        Assert-True ($undo.ExitCode -eq 0) 'undo after unsupported removal should exit 0'
        Assert-True (Test-Path -LiteralPath $unsupported) 'undo should restore fake unsupported path'
    } finally {
        Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-BlockingProcessOutputIsClean {
    $fx = New-TestRoot
    $started = $null
    try {
        $pythonPath = where.exe python 2>$null | Where-Object {
            $_ -and
            (Test-Path -LiteralPath $_ -PathType Leaf) -and
            ($_ -notmatch '\\WindowsApps\\')
        } | Select-Object -First 1
        if (-not $pythonPath) {
            $fallbackRoots = @(
                (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
                (Join-Path $env:APPDATA 'uv\python'),
                (Join-Path $env:LOCALAPPDATA 'uv'),
                (Join-Path $env:USERPROFILE '.codex\tools')
            )
            foreach ($root in $fallbackRoots) {
                if (Test-Path -LiteralPath $root) {
                    $pythonPath = Get-ChildItem -LiteralPath $root -Recurse -Filter python.exe -File -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty FullName -First 1
                    if ($pythonPath) { break }
                }
            }
        }
        if (-not $pythonPath) {
            return
        }
        $started = Start-Process -FilePath $pythonPath `
            -ArgumentList '-c "import time; time.sleep(60)"' `
            -WindowStyle Hidden `
            -PassThru
        Start-Sleep -Seconds 2
        New-FakePythonTree -Fixture $fx
        New-Item -ItemType Directory -Path $fx.FTarget -Force | Out-Null
        $result = Invoke-MoveScript -Fixture $fx -ExpectFailure -EnableProcessCheck
        Assert-True ($result.ExitCode -ne 0) 'blocking Python process should fail before migration'
        Assert-True ($result.Output -match 'Python-related processes are running') 'blocking process output should explain safety stop'
        Assert-True ($result.Output -match "pid=$($started.Id)") 'blocking process output should include the test-owned Python process'
        Assert-True ($result.Output -notmatch 'CategoryInfo|FullyQualifiedErrorId|At .*PythonPortableCommon') 'blocking process output should not include PowerShell stack details'
        Assert-True ($result.Output -notmatch 'Idle pid=0') 'blocking process output should not include Windows Idle process'
    } finally {
        if ($started -and -not $started.HasExited) {
            Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-MoveAndUndo
Test-FreshBootstrap
Test-FailClosedUnsupported
Test-RemoveUnsupportedInTestMode
Test-BlockingProcessOutputIsClean

"PASS: $script:PassCount assertions"
