# Windows C Drive Cleanup Skill

A conservative Codex skill for inspecting and cleaning a Windows system drive. It uses Windows PowerShell and .NET only; WSL, Bash, Python, and third-party modules are not required.

## Scope

- User and Windows temporary files, with age and elevation safeguards
- Crash dumps and pip cache
- Chrome and Edge caches across discovered profiles
- Optional Codex and WeChat caches
- Standard DISM component cleanup

The skill never deletes Codex worktrees, browser credentials, user documents, `hiberfil.sys`, `pagefile.sys`, or `swapfile.sys`.

## Install

Copy `skills\windows-c-drive-cleanup` into your Codex skills directory:

```powershell
$destination = "$env:USERPROFILE\.codex\skills\windows-c-drive-cleanup"
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item -Path ".\skills\windows-c-drive-cleanup\*" -Destination $destination -Recurse -Force
```

Restart Codex, then ask:

```text
Use $windows-c-drive-cleanup to scan my Windows system drive. Do not delete anything.
```

Cleanup scripts default to dry-run. Deletion requires explicit category confirmation and the `-Execute` switch. Windows Temp and DISM cleanup require an elevated PowerShell process.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or later
- Administrator privileges only for Windows Temp and DISM operations

## Test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

## License

MIT
