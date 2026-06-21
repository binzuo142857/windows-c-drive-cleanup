param(
    [switch]$IncludeOldBackups,
    [switch]$IncludeRuntimeCache,
    [switch]$IncludeTmp,
    [switch]$Execute,
    [string]$Drive = $env:SystemDrive,
    [string]$UserProfile = $env:USERPROFILE,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $UserProfile '.codex' })
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'Cleanup.Common.ps1')

$driveRoot = Get-NormalizedDriveRoot -Drive $Drive
$before = Get-DriveFreeBytes -DriveRoot $driveRoot
$results = New-Object System.Collections.Generic.List[object]
$codexRunning = $null -ne (Get-Process -Name Codex -ErrorAction SilentlyContinue | Select-Object -First 1)

if ($IncludeOldBackups) {
    Get-ChildItem -LiteralPath $UserProfile -Force -Directory -Filter '.codex_backup_*' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $results.Add((Invoke-CleanupTarget -Label "Codex backup $($_.Name)" -LiteralPath $_.FullName `
                -AllowedRoot $UserProfile -Execute:$Execute)) | Out-Null
        }
}

if ($IncludeRuntimeCache) {
    if ($codexRunning) {
        $results.Add([PSCustomObject]@{ Target = 'Codex runtime cache'; Status = 'SKIPPED_RUNNING'; Bytes = 0L; Detail = 'Codex is running.' }) | Out-Null
    } else {
        $results.Add((Invoke-CleanupTarget -Label 'Codex runtime cache' -LiteralPath (Join-Path $UserProfile '.cache\codex-runtimes') `
            -AllowedRoot $UserProfile -Execute:$Execute)) | Out-Null
    }
}

if ($IncludeTmp) {
    if ($codexRunning) {
        $results.Add([PSCustomObject]@{ Target = 'Codex temporary cache'; Status = 'SKIPPED_RUNNING'; Bytes = 0L; Detail = 'Codex is running.' }) | Out-Null
    } else {
        $results.Add((Invoke-CleanupTarget -Label 'Codex temporary cache' -LiteralPath (Join-Path $CodexHome '.tmp') `
            -AllowedRoot $CodexHome -Execute:$Execute)) | Out-Null
    }
}

if ($results.Count -eq 0) {
    $results.Add([PSCustomObject]@{
        Target = 'No targets selected'
        Status = 'NO_OP'
        Bytes = 0L
        Detail = 'Use IncludeOldBackups, IncludeRuntimeCache, or IncludeTmp. Worktrees are report-only.'
    }) | Out-Null
}

$after = Get-DriveFreeBytes -DriveRoot $driveRoot
Write-CleanupSummary -Results $results -FreeBefore $before -FreeAfter $after -Execute:$Execute
