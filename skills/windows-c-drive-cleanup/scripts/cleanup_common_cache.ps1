param(
    [switch]$IncludeUserTemp,
    [switch]$IncludeWindowsTemp,
    [switch]$IncludeCrashDumps,
    [switch]$IncludePipCache,
    [switch]$IncludeWeChatCache,
    [ValidateRange(1, 3650)]
    [int]$TempOlderThanDays = 7,
    [switch]$Execute,
    [string]$Drive = $env:SystemDrive,
    [string]$SystemRoot = $env:SystemRoot,
    [string]$LocalAppData = [Environment]::GetFolderPath('LocalApplicationData'),
    [string]$RoamingAppData = [Environment]::GetFolderPath('ApplicationData')
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'Cleanup.Common.ps1')

$driveRoot = Get-NormalizedDriveRoot -Drive $Drive
$before = Get-DriveFreeBytes -DriveRoot $driveRoot
$results = New-Object System.Collections.Generic.List[object]
$cutoff = (Get-Date).AddDays(-$TempOlderThanDays)

function Add-StaleTempEntries {
    param(
        [Parameter(Mandatory = $true)]$Results,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$LabelPrefix,
        [Parameter(Mandatory = $true)][DateTime]$Cutoff,
        [switch]$Execute
    )

    if (-not (Test-Path -LiteralPath $Root)) { return }
    $completedCount = 0
    $completedBytes = 0L
    foreach ($entry in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)) {
        if ($entry.LastWriteTime -ge $Cutoff) { continue }

        $scanErrors = @()
        $hasNewerContent = $false
        if ($entry.PSIsContainer -and (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
            $pending = New-Object System.Collections.Generic.Stack[string]
            $pending.Push($entry.FullName)
            while ($pending.Count -gt 0 -and -not $hasNewerContent) {
                $children = @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction SilentlyContinue -ErrorVariable +scanErrors)
                foreach ($child in $children) {
                    if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $scanErrors += "Reparse point: $($child.FullName)"
                        continue
                    }
                    if ($child.LastWriteTime -ge $Cutoff) {
                        $hasNewerContent = $true
                        break
                    }
                    if ($child.PSIsContainer) { $pending.Push($child.FullName) }
                }
            }
        }

        if ($scanErrors.Count -gt 0) {
            $Results.Add([PSCustomObject]@{
                Target = "${LabelPrefix}: $($entry.Name)"
                Status = 'SKIPPED_INCOMPLETE_SCAN'
                Bytes = 0L
                Detail = $entry.FullName
            }) | Out-Null
        } elseif (-not $hasNewerContent) {
            $result = Invoke-CleanupTarget -Label "${LabelPrefix}: $($entry.Name)" -LiteralPath $entry.FullName `
                -AllowedRoot $Root -Execute:$Execute
            if ($result.Status -in @('DRY_RUN', 'DELETED')) {
                $completedCount++
                $completedBytes += [Int64]$result.Bytes
            } else {
                $Results.Add($result) | Out-Null
            }
        }
    }

    if ($completedCount -gt 0) {
        $Results.Add([PSCustomObject]@{
            Target = "$LabelPrefix entries ($completedCount)"
            Status = if ($Execute) { 'DELETED' } else { 'DRY_RUN' }
            Bytes = $completedBytes
            Detail = $Root
        }) | Out-Null
    }
}

if ($IncludeUserTemp) {
    $tempRoot = Join-Path $LocalAppData 'Temp'
    Add-StaleTempEntries -Results $results -Root $tempRoot -LabelPrefix 'User temp' -Cutoff $cutoff -Execute:$Execute
}

if ($IncludeWindowsTemp) {
    $windowsTempRoot = Join-Path $SystemRoot 'Temp'
    if ((Get-NormalizedDriveRoot -Drive ([IO.Path]::GetPathRoot($SystemRoot))) -ne $driveRoot) {
        $results.Add([PSCustomObject]@{ Target = 'Windows temp'; Status = 'REFUSED'; Bytes = 0L; Detail = 'SystemRoot is not on the selected drive.' }) | Out-Null
    } elseif (-not (Test-CurrentUserIsAdministrator)) {
        $results.Add([PSCustomObject]@{ Target = 'Windows temp'; Status = 'SKIPPED_REQUIRES_ELEVATION'; Bytes = 0L; Detail = $windowsTempRoot }) | Out-Null
    } else {
        Add-StaleTempEntries -Results $results -Root $windowsTempRoot -LabelPrefix 'Windows temp' -Cutoff $cutoff -Execute:$Execute
    }
}

if ($IncludeCrashDumps) {
    $results.Add((Invoke-CleanupTarget -Label 'Crash dumps' -LiteralPath (Join-Path $LocalAppData 'CrashDumps') `
        -AllowedRoot $LocalAppData -Execute:$Execute)) | Out-Null
}

if ($IncludePipCache) {
    $results.Add((Invoke-CleanupTarget -Label 'pip cache' -LiteralPath (Join-Path $LocalAppData 'pip\Cache') `
        -AllowedRoot $LocalAppData -Execute:$Execute)) | Out-Null
}

if ($IncludeWeChatCache) {
    if (Get-Process -Name WeChat, Weixin, WeChatAppEx -ErrorAction SilentlyContinue) {
        $results.Add([PSCustomObject]@{ Target = 'WeChat cache targets'; Status = 'SKIPPED_RUNNING'; Bytes = 0L; Detail = 'WeChat is running.' }) | Out-Null
    } else {
        $wechatRoot = Join-Path $RoamingAppData 'Tencent\xwechat'
        foreach ($name in @('log', 'update')) {
            $results.Add((Invoke-CleanupTarget -Label "WeChat $name" -LiteralPath (Join-Path $wechatRoot $name) `
                -AllowedRoot $wechatRoot -Execute:$Execute)) | Out-Null
        }
    }
}

if ($results.Count -eq 0) {
    $results.Add([PSCustomObject]@{ Target = 'No matching targets'; Status = 'NO_OP'; Bytes = 0L; Detail = 'Select a category or no matching cache entries were found.' }) | Out-Null
}

$after = Get-DriveFreeBytes -DriveRoot $driveRoot
Write-CleanupSummary -Results $results -FreeBefore $before -FreeAfter $after -Execute:$Execute
