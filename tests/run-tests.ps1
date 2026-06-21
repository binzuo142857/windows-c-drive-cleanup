$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
$skillRoot = Join-Path $repoRoot 'skills\windows-c-drive-cleanup'
$scriptsRoot = Join-Path $skillRoot 'scripts'
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $failures.Add($Message) | Out-Null }
}

Write-Host 'Checking PowerShell syntax...'
foreach ($script in Get-ChildItem -LiteralPath $scriptsRoot -Filter '*.ps1' -File) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $failures.Add("Syntax error in $($script.Name): $(($errors | ForEach-Object { $_.Message }) -join '; ')") | Out-Null
    }
}

Write-Host 'Checking metadata and Windows-only boundaries...'
$skillText = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'SKILL.md')
Assert-True ($skillText -match '(?m)^name: windows-c-drive-cleanup$') 'SKILL.md name is missing or invalid.'
Assert-True ($skillText -match '(?m)^description: .+$') 'SKILL.md description is missing.'

$allText = (Get-ChildItem -LiteralPath $skillRoot -Recurse -File | ForEach-Object {
    Get-Content -Raw -LiteralPath $_.FullName
}) -join "`n"
foreach ($pattern in @('wsl\.exe', '/mnt/', '/home/', '#!/bin/', '[A-Za-z]:\\Users\\[^$%\\]+')) {
    Assert-True (-not ($allText -match $pattern)) "Forbidden machine-specific or non-Windows dependency pattern: $pattern"
}

$testRoot = Join-Path $repoRoot ('.test-tmp-' + [Guid]::NewGuid().ToString('N'))
$allowedRoot = Join-Path $testRoot 'allowed'
$outsideRoot = Join-Path $testRoot 'outside'
$junctionPath = Join-Path $allowedRoot 'junction'

try {
    New-Item -ItemType Directory -Force -Path $allowedRoot, $outsideRoot | Out-Null
    . (Join-Path $scriptsRoot 'Cleanup.Common.ps1')

    Write-Host 'Checking dry-run, execute, and path boundaries...'
    $dryRunTarget = Join-Path $allowedRoot 'dry-run'
    New-Item -ItemType Directory -Force -Path $dryRunTarget | Out-Null
    Set-Content -LiteralPath (Join-Path $dryRunTarget 'data.txt') -Value 'test'
    $dryRunResult = Invoke-CleanupTarget -Label 'dry-run' -LiteralPath $dryRunTarget -AllowedRoot $allowedRoot
    Assert-True ($dryRunResult.Status -eq 'DRY_RUN') 'Dry-run did not report DRY_RUN.'
    Assert-True (Test-Path -LiteralPath $dryRunTarget) 'Dry-run removed its target.'

    $deleteTarget = Join-Path $allowedRoot 'delete-me'
    New-Item -ItemType Directory -Force -Path $deleteTarget | Out-Null
    Set-Content -LiteralPath (Join-Path $deleteTarget 'data.txt') -Value 'test'
    $deleteResult = Invoke-CleanupTarget -Label 'delete' -LiteralPath $deleteTarget -AllowedRoot $allowedRoot -Execute
    Assert-True ($deleteResult.Status -eq 'DELETED') 'Confirmed fixture deletion failed.'
    Assert-True (-not (Test-Path -LiteralPath $deleteTarget)) 'Confirmed fixture target still exists.'

    $boundaryResult = Invoke-CleanupTarget -Label 'boundary' -LiteralPath $outsideRoot -AllowedRoot $allowedRoot -Execute
    Assert-True ($boundaryResult.Status -eq 'REFUSED') 'Outside-root deletion was not refused.'
    Assert-True (Test-Path -LiteralPath $outsideRoot) 'Outside-root fixture was removed.'

    New-Item -ItemType Junction -Path $junctionPath -Target $outsideRoot | Out-Null
    $junctionResult = Invoke-CleanupTarget -Label 'junction' -LiteralPath $junctionPath -AllowedRoot $allowedRoot -Execute
    Assert-True ($junctionResult.Status -eq 'REFUSED') 'Reparse-point deletion was not refused.'
    Assert-True (Test-Path -LiteralPath $outsideRoot) 'Junction target was removed.'

    Write-Host 'Checking stale Temp behavior...'
    $localAppData = Join-Path $testRoot 'LocalAppData'
    $tempRoot = Join-Path $localAppData 'Temp'
    $oldTree = Join-Path $tempRoot 'old-tree'
    $mixedTree = Join-Path $tempRoot 'mixed-tree'
    New-Item -ItemType Directory -Force -Path $oldTree, $mixedTree | Out-Null
    Set-Content -LiteralPath (Join-Path $oldTree 'old.txt') -Value 'old'
    Set-Content -LiteralPath (Join-Path $mixedTree 'new.txt') -Value 'new'
    (Get-Item -LiteralPath (Join-Path $oldTree 'old.txt')).LastWriteTime = (Get-Date).AddDays(-30)
    (Get-Item -LiteralPath $oldTree).LastWriteTime = (Get-Date).AddDays(-30)
    (Get-Item -LiteralPath $mixedTree).LastWriteTime = (Get-Date).AddDays(-30)

    & (Join-Path $scriptsRoot 'cleanup_common_cache.ps1') -IncludeUserTemp -TempOlderThanDays 7 `
        -LocalAppData $localAppData -RoamingAppData (Join-Path $testRoot 'RoamingAppData') -Execute *> $null
    Assert-True (-not (Test-Path -LiteralPath $oldTree)) 'Entirely stale Temp tree was not removed.'
    Assert-True (Test-Path -LiteralPath $mixedTree) 'Temp tree containing a newer file was removed.'

    Write-Host 'Checking Windows Temp dry-run behavior...'
    $fakeSystemRoot = Join-Path $testRoot 'Windows'
    $fakeWindowsTemp = Join-Path $fakeSystemRoot 'Temp'
    New-Item -ItemType Directory -Force -Path $fakeWindowsTemp | Out-Null
    $fakeWindowsTempFile = Join-Path $fakeWindowsTemp 'old.tmp'
    Set-Content -LiteralPath $fakeWindowsTempFile -Value 'old'
    (Get-Item -LiteralPath $fakeWindowsTempFile).LastWriteTime = (Get-Date).AddDays(-30)
    & (Join-Path $scriptsRoot 'cleanup_common_cache.ps1') -IncludeWindowsTemp -TempOlderThanDays 7 `
        -SystemRoot $fakeSystemRoot -LocalAppData $localAppData -RoamingAppData (Join-Path $testRoot 'RoamingAppData') *> $null
    Assert-True (Test-Path -LiteralPath $fakeWindowsTempFile) 'Windows Temp dry-run removed a file.'
} finally {
    if (Test-Path -LiteralPath $junctionPath) {
        [IO.Directory]::Delete($junctionPath)
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedRepo = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\') + '\'
        $resolvedTest = [IO.Path]::GetFullPath($testRoot)
        if ($resolvedTest.StartsWith($resolvedRepo, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host 'All tests passed.'
