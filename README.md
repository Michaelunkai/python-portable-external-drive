# Python Portable External Drive

Fail-closed PowerShell tooling for moving a Windows Python installation and related user data from `C:` to:

```text
F:\backup\windowsapps\AppsBackups\python
```

The scripts are designed to stop rather than guess when they cannot prove a safe migration. Real migration is not performed by the test harness.

## Files

- `Move-Python-ToExternalPortable.ps1` - migration entrypoint.
- `Undo-Move-Python-ToExternalPortable.ps1` - undo entrypoint, restoring from the manifest written by the migration.
- `PythonPortableCommon.psm1` - shared implementation used by both entrypoints.
- `Test-PythonPortableScripts.ps1` - mock-only test harness using temporary fake roots.

## Verify Without Migrating

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-PythonPortableScripts.ps1
```

Expected result:

```text
PASS: 20 assertions
```

## Real Migration

Do not run this unless you intend to mutate the real machine:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Move-Python-ToExternalPortable.ps1
```

By default, the script closes blocking Python processes before migration so running interpreters do not keep C: files locked. It first asks windowed processes to close, then force-stops remaining Python-related blockers and rechecks before moving data.

If you intentionally do not want the script to close running Python jobs, use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Move-Python-ToExternalPortable.ps1 -PreserveBlockingPythonProcesses
```

With `-PreserveBlockingPythonProcesses`, the script fails before migration if any Python process is still running. The script also fails if the target is not writable, unsupported Python remnants are found, or verification cannot prove the external wrappers are usable.

If Microsoft Store Python packages are the only unsupported remnants and you want the script to remove them too, use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Move-Python-ToExternalPortable.ps1 -RemoveStorePythonPackages
```

## Undo

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Undo-Move-Python-ToExternalPortable.ps1
```

Undo reads the migration manifest from the target directory and restores the changes recorded there.

Undo uses the same default behavior and closes blocking Python processes before restore. Use `-PreserveBlockingPythonProcesses` to opt out.

If the migration removed Store Python packages and you want undo to attempt a best-effort `winget` reinstall, use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Undo-Move-Python-ToExternalPortable.ps1 -AttemptStorePythonPackageReinstall
```
