Set-StrictMode -Version 2.0

function Format-ByteSize {
    param([Int64]$Bytes)

    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-NormalizedDriveRoot {
    param([string]$Drive = $env:SystemDrive)

    if ([string]::IsNullOrWhiteSpace($Drive)) {
        throw "A drive must be supplied and env:SystemDrive is not set."
    }
    if ($Drive -notmatch '^[A-Za-z]:[\\/]?$') {
        throw "Drive must be a local drive letter such as C: or D:. Received: $Drive"
    }
    return ([IO.Path]::GetPathRoot(([IO.Path]::GetFullPath($Drive + '\'))))
}

function Get-DriveFreeBytes {
    param([Parameter(Mandatory = $true)][string]$DriveRoot)

    $disk = New-Object IO.DriveInfo($DriveRoot)
    if (-not $disk.IsReady) { throw "Drive is not ready: $DriveRoot" }
    return [Int64]$disk.AvailableFreeSpace
}

function Get-PathSizeInfo {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return [PSCustomObject]@{ Bytes = 0L; Complete = $true }
    }

    $errors = @()
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue -ErrorVariable +errors
    if ($null -eq $item) {
        return [PSCustomObject]@{ Bytes = 0L; Complete = $false }
    }
    if (-not $item.PSIsContainer) {
        return [PSCustomObject]@{ Bytes = [Int64]$item.Length; Complete = ($errors.Count -eq 0) }
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [PSCustomObject]@{ Bytes = 0L; Complete = $false }
    }

    $sum = 0L
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($item.FullName)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue -ErrorVariable +errors)
        foreach ($child in $children) {
            if ($child.PSIsContainer) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $errors += "Skipped reparse point: $($child.FullName)"
                } else {
                    $pending.Push($child.FullName)
                }
            } else {
                $sum += [Int64]$child.Length
            }
        }
    }
    return [PSCustomObject]@{ Bytes = $sum; Complete = ($errors.Count -eq 0) }
}

function Test-CurrentUserIsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-SafeCleanupTarget {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$AllowedRoot
    )

    $target = [IO.Path]::GetFullPath($LiteralPath).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\')
    $prefix = $root + '\'

    if ($target -eq $root -or -not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing target outside the allowed root: $target (root: $root)"
    }

    $cursor = $target
    while ($cursor.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing reparse-point target or ancestor: $cursor"
            }
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent.TrimEnd('\')
    }

    return $target
}

function Invoke-CleanupTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$AllowedRoot,
        [switch]$Execute
    )

    try {
        $target = Assert-SafeCleanupTarget -LiteralPath $LiteralPath -AllowedRoot $AllowedRoot
    } catch {
        return [PSCustomObject]@{ Target = $Label; Status = 'REFUSED'; Bytes = 0L; Detail = $_.Exception.Message }
    }

    if (-not (Test-Path -LiteralPath $target)) {
        return [PSCustomObject]@{ Target = $Label; Status = 'NOT_FOUND'; Bytes = 0L; Detail = $target }
    }

    $size = Get-PathSizeInfo -LiteralPath $target
    if (-not $Execute) {
        return [PSCustomObject]@{ Target = $Label; Status = 'DRY_RUN'; Bytes = $size.Bytes; Detail = $target }
    }

    try {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop -Confirm:$false
        return [PSCustomObject]@{ Target = $Label; Status = 'DELETED'; Bytes = $size.Bytes; Detail = $target }
    } catch {
        return [PSCustomObject]@{ Target = $Label; Status = 'ERROR_OR_LOCKED'; Bytes = 0L; Detail = "$target :: $($_.Exception.Message)" }
    }
}

function Write-CleanupSummary {
    param(
        [Parameter(Mandatory = $true)]$Results,
        [Parameter(Mandatory = $true)][Int64]$FreeBefore,
        [Parameter(Mandatory = $true)][Int64]$FreeAfter,
        [switch]$Execute
    )

    $reportedBytes = 0L
    foreach ($result in $Results) {
        if ($result.Status -in @('DRY_RUN', 'DELETED')) {
            $reportedBytes += [Int64]$result.Bytes
        }
    }
    Write-Host "Mode: $(if ($Execute) { 'EXECUTE' } else { 'DRY_RUN' })"
    Write-Host "Drive free before: $(Format-ByteSize $FreeBefore)"
    Write-Host "Drive free after : $(Format-ByteSize $FreeAfter)"
    Write-Host "Target bytes     : $(Format-ByteSize $reportedBytes)"
    if ($Execute) {
        Write-Host "Free-space delta : $(Format-ByteSize ($FreeAfter - $FreeBefore))"
    }
    Write-Host ''
    $Results | Select-Object Target, Status, @{Name = 'Size'; Expression = { Format-ByteSize $_.Bytes } }, Detail |
        Format-Table -AutoSize
}
