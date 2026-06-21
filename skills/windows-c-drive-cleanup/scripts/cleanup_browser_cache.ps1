param(
    [ValidateSet('Chrome', 'Edge', 'All')]
    [string]$Browser = 'All',
    [switch]$IncludeServiceWorker,
    [switch]$Execute,
    [string]$Drive = $env:SystemDrive,
    [string]$LocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'Cleanup.Common.ps1')

function Get-BrowserProfiles {
    param([string]$UserDataRoot)

    if (-not (Test-Path -LiteralPath $UserDataRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $UserDataRoot -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq 'Default' -or $_.Name -eq 'Guest Profile' -or $_.Name -like 'Profile *'
        })
}

$driveRoot = Get-NormalizedDriveRoot -Drive $Drive
$before = Get-DriveFreeBytes -DriveRoot $driveRoot
$results = New-Object System.Collections.Generic.List[object]

$browserDefinitions = @(
    [PSCustomObject]@{ Name = 'Chrome'; Process = 'chrome'; RelativeRoot = 'Google\Chrome\User Data' },
    [PSCustomObject]@{ Name = 'Edge'; Process = 'msedge'; RelativeRoot = 'Microsoft\Edge\User Data' }
)

foreach ($definition in $browserDefinitions) {
    if ($Browser -ne 'All' -and $Browser -ne $definition.Name) { continue }

    $userDataRoot = Join-Path $LocalAppData $definition.RelativeRoot
    if (Get-Process -Name $definition.Process -ErrorAction SilentlyContinue) {
        $results.Add([PSCustomObject]@{
            Target = "$($definition.Name) cache targets"
            Status = 'SKIPPED_RUNNING'
            Bytes = 0L
            Detail = "$($definition.Process) process is running"
        }) | Out-Null
        continue
    }

    foreach ($profile in Get-BrowserProfiles -UserDataRoot $userDataRoot) {
        $profileTargets = @('Cache', 'Code Cache', 'GPUCache', 'DawnWebGPUCache')
        if ($IncludeServiceWorker) { $profileTargets += 'Service Worker' }
        foreach ($relativePath in $profileTargets) {
            $results.Add((Invoke-CleanupTarget -Label "$($definition.Name) $($profile.Name) $relativePath" `
                -LiteralPath (Join-Path $profile.FullName $relativePath) -AllowedRoot $userDataRoot -Execute:$Execute)) | Out-Null
        }
    }

    foreach ($relativePath in @('Crashpad\reports', 'GrShaderCache', 'component_crx_cache', 'extensions_crx_cache')) {
        $results.Add((Invoke-CleanupTarget -Label "$($definition.Name) $relativePath" `
            -LiteralPath (Join-Path $userDataRoot $relativePath) -AllowedRoot $userDataRoot -Execute:$Execute)) | Out-Null
    }
}

if ($results.Count -eq 0) {
    $results.Add([PSCustomObject]@{ Target = 'Browser cache targets'; Status = 'NOT_FOUND'; Bytes = 0L; Detail = 'No supported browser profiles found.' }) | Out-Null
}

$after = Get-DriveFreeBytes -DriveRoot $driveRoot
Write-CleanupSummary -Results $results -FreeBefore $before -FreeAfter $after -Execute:$Execute
