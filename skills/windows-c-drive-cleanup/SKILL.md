---
name: windows-c-drive-cleanup
description: Inspect, report, and safely clean disk space on a Windows system drive using dry-run-first Windows PowerShell scripts with no WSL dependency. Use for user or Windows temporary files, crash dumps, pip caches, Chrome or Edge caches across multiple profiles, optional Codex or WeChat caches, and DISM component cleanup with explicit confirmation and protected-system-file safeguards.
---

# Windows System Drive Cleanup

Use Windows-native PowerShell 5.1 or later. Do not require WSL, Bash, Linux paths, Python, or third-party modules. Inspect first, classify risk, obtain confirmation for exact categories, and execute only the confirmed targets.

## Workflow

1. Run the read-only inventory:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\analyze_windows_drive.ps1
   ```

   Use `-Drive`, `-UserProfile`, `-LocalAppData`, and `-RoamingAppData` only when the defaults do not describe the target Windows installation.

2. Report free space, discovered targets, incomplete size calculations, relevant running processes, and protected system files.

3. Classify and confirm exact categories:
   - Low risk: stale user Temp entries, crash dumps not needed for troubleshooting, pip cache, browser Cache/Code Cache/GPUCache, browser crash reports, optional WeChat logs/update cache.
   - Medium risk: stale Windows Temp entries, browser Service Worker data, Codex runtime/tmp cache, old Codex backups, DISM component cleanup.
   - High risk and report-only: Codex worktrees, browser credentials/profile storage, application data, user documents, and system-managed paging or hibernation files.

4. Close affected applications. Never terminate user processes automatically. Scripts skip browser, WeChat, or Codex cache targets while the corresponding application is running.

5. Run the smallest matching cleanup script without `-Execute` first. Review every target and status, then rerun with `-Execute` only after explicit confirmation.

6. Verify free space and report deleted, skipped, refused, locked, and missing targets. Treat the drive free-space delta as approximate because other programs may write concurrently.

## Commands

Common user caches:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\cleanup_common_cache.ps1 -IncludeUserTemp -IncludeCrashDumps -IncludePipCache -TempOlderThanDays 7
```

Add `-IncludeWeChatCache` only when WeChat is installed and its discovered `xwechat` paths match the user's installation.

For stale Windows Temp entries, run an elevated dry-run first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\cleanup_common_cache.ps1 -IncludeWindowsTemp -TempOlderThanDays 7
```

The script skips Windows Temp without elevation and preserves directories containing newer files, unreadable descendants, or reparse points.

Browser caches across discovered `Default`, `Guest Profile`, and `Profile *` directories:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\cleanup_browser_cache.ps1 -Browser All
```

Add `-IncludeServiceWorker` only after warning that offline data and background registrations may be removed.

Codex caches and backups:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\cleanup_codex_cache.ps1 -IncludeRuntimeCache -IncludeTmp -IncludeOldBackups
```

Codex worktrees are not accepted by any cleanup script.

Windows component cleanup:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\cleanup_windows_components.ps1
```

Execution requires elevation and explicit `-Execute`. The script uses only `DISM.exe /Online /Cleanup-Image /StartComponentCleanup` and never `/ResetBase`.

## Safety Rules

- Keep dry-run as the default. Require `-Execute` for deletion.
- Do not broaden a confirmed category during execution.
- Reject targets outside their expected cache root and reject reparse points.
- Never manually delete Windows, Program Files, ProgramData, WinSxS, application install directories, or user document folders.
- Never modify or delete `hiberfil.sys`, `pagefile.sys`, or `swapfile.sys`; report them only.
- Never delete browser Bookmarks, Cookies, Login Data, Local Storage, IndexedDB, extensions, or profile preferences.
- Never delete WeChat chat history, received files, pictures, videos, or account data.
- Never delete Codex worktrees.
- Do not run DISM against an offline or non-system drive.
