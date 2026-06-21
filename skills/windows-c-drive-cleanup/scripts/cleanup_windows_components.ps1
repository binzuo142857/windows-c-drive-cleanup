param(
    [switch]$Execute,
    [string]$Drive = $env:SystemDrive
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Cleanup.Common.ps1')

$driveRoot = Get-NormalizedDriveRoot -Drive $Drive
if ($driveRoot -ne (Get-NormalizedDriveRoot -Drive $env:SystemDrive)) {
    throw 'DISM services the running Windows installation only; Drive must match env:SystemDrive.'
}

$before = Get-DriveFreeBytes -DriveRoot $driveRoot
Write-Host "Drive free before: $(Format-ByteSize $before)"
Write-Host ''

if (-not $Execute) {
    Write-Host 'DRY_RUN: would run DISM.exe /Online /Cleanup-Image /StartComponentCleanup'
    Write-Host 'This script never uses /ResetBase and never modifies hibernation, pagefile, swapfile, or WinSxS directly.'
    exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Administrator privileges are required to run DISM component cleanup.'
    exit 5
}

& Dism.exe /Online /Cleanup-Image /StartComponentCleanup
$exitCode = $LASTEXITCODE
$after = Get-DriveFreeBytes -DriveRoot $driveRoot
Write-Host ''
Write-Host "DISM exit code: $exitCode"
Write-Host "Drive free after : $(Format-ByteSize $after)"
Write-Host "Free-space delta : $(Format-ByteSize ($after - $before))"
exit $exitCode
