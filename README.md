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

The script fails if Python processes are running, the target is not writable, unsupported Python remnants are found, or verification cannot prove the external wrappers are usable.

If Python processes are running and you intentionally want the script to stop them before migration, use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Move-Python-ToExternalPortable.ps1 -StopBlockingPythonProcesses
```

This is opt-in because stopping live Python can interrupt editors, agents, package managers, servers, or other running tools.

If Microsoft Store Python packages are the only unsupported remnants and you want the script to remove them too, use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Move-Python-ToExternalPortable.ps1 -RemoveStorePythonPackages
```

## Undo

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Undo-Move-Python-ToExternalPortable.ps1
```

Undo reads the migration manifest from the target directory and restores the changes recorded there.

Undo also has `-StopBlockingPythonProcesses` for the same opt-in reason.

If the migration removed Store Python packages and you want undo to attempt a best-effort `winget` reinstall, use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Undo-Move-Python-ToExternalPortable.ps1 -AttemptStorePythonPackageReinstall
```
