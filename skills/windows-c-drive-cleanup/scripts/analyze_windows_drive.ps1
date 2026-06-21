param(
    [string]$Drive = $env:SystemDrive,
    [string]$UserProfile = $env:USERPROFILE,
    [string]$LocalAppData = [Environment]::GetFolderPath('LocalApplicationData'),
    [string]$RoamingAppData = [Environment]::GetFolderPath('ApplicationData'),
    [ValidateSet('Chrome', 'Edge', 'Codex', 'WeChat')]
    [string[]]$Applications = @('Chrome', 'Edge', 'Codex', 'WeChat')
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'Cleanup.Common.ps1')

function Add-Candidate {
    param($Rows, [string]$Label, [string]$Risk, [string]$Path, [string]$Note)

    $size = Get-PathSizeInfo -LiteralPath $Path
    $rows.Add([PSCustomObject]@{
        Label = $Label
        Risk = $Risk
        Size = Format-ByteSize $size.Bytes
        Complete = $size.Complete
        Exists = Test-Path -LiteralPath $Path
        Path = $Path
        Note = $Note
    }) | Out-Null
}

function Get-BrowserProfiles {
    param([string]$UserDataRoot)

    if (-not (Test-Path -LiteralPath $UserDataRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $UserDataRoot -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq 'Default' -or $_.Name -eq 'Guest Profile' -or $_.Name -like 'Profile *'
        })
}

$driveRoot = Get-NormalizedDriveRoot -Drive $Drive
$deviceId = $driveRoot.TrimEnd('\')
$disk = New-Object IO.DriveInfo($driveRoot)
if (-not $disk.IsReady) { throw "Drive is not ready: $driveRoot" }
Write-Host "$deviceId total: $(Format-ByteSize ([Int64]$disk.TotalSize))"
Write-Host "$deviceId free : $(Format-ByteSize ([Int64]$disk.AvailableFreeSpace))"
Write-Host ''

$rows = New-Object System.Collections.Generic.List[object]
Add-Candidate $rows 'User temporary files' 'low' (Join-Path $LocalAppData 'Temp') 'Clean only entries older than the requested age.'
Add-Candidate $rows 'Windows temporary files' 'medium' (Join-Path $env:SystemRoot 'Temp') 'Requires elevation; clean only stale entries.'
Add-Candidate $rows 'Crash dumps' 'low' (Join-Path $LocalAppData 'CrashDumps') 'Diagnostic dumps; keep when troubleshooting crashes.'
Add-Candidate $rows 'pip cache' 'low' (Join-Path $LocalAppData 'pip\Cache') 'Recreated by pip.'

foreach ($browser in @('Chrome', 'Edge')) {
    if ($browser -notin $Applications) { continue }
    $relativeRoot = if ($browser -eq 'Chrome') { 'Google\Chrome\User Data' } else { 'Microsoft\Edge\User Data' }
    $userDataRoot = Join-Path $LocalAppData $relativeRoot
    foreach ($profile in Get-BrowserProfiles -UserDataRoot $userDataRoot) {
        foreach ($cacheName in @('Cache', 'Code Cache', 'GPUCache')) {
            Add-Candidate $rows "$browser $($profile.Name) $cacheName" 'low' (Join-Path $profile.FullName $cacheName) 'Skip while the browser is running.'
        }
        Add-Candidate $rows "$browser $($profile.Name) Service Worker" 'medium' (Join-Path $profile.FullName 'Service Worker') 'May remove offline data and background registrations.'
    }
}

if ('WeChat' -in $Applications) {
    $wechatRoot = Join-Path $RoamingAppData 'Tencent\xwechat'
    Add-Candidate $rows 'WeChat logs' 'low' (Join-Path $wechatRoot 'log') 'Optional app target; skip while WeChat is running.'
    Add-Candidate $rows 'WeChat update cache' 'low' (Join-Path $wechatRoot 'update') 'Optional app target; version-specific path.'
}

if ('Codex' -in $Applications) {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $UserProfile '.codex' }
    Add-Candidate $rows 'Codex runtime cache' 'medium' (Join-Path $UserProfile '.cache\codex-runtimes') 'May be downloaded again; skip while Codex is active.'
    Add-Candidate $rows 'Codex temporary cache' 'medium' (Join-Path $codexHome '.tmp') 'Skip while Codex is active.'
    Add-Candidate $rows 'Codex worktrees' 'high-report-only' (Join-Path $codexHome 'worktrees') 'Never deleted by this skill.'
    Get-ChildItem -LiteralPath $UserProfile -Force -Directory -Filter '.codex_backup_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Add-Candidate $rows 'Codex old backup' 'medium' $_.FullName 'Rollback point; remove only after explicit confirmation.' }
}

Write-Host 'Candidate paths:'
$rows | Where-Object Exists | Sort-Object Risk, Label | Format-Table -AutoSize

Write-Host ''
Write-Host 'Relevant running processes:'
Get-Process chrome, msedge, Codex, WeChat, Weixin, WeChatAppEx -ErrorAction SilentlyContinue |
    Select-Object ProcessName, Id | Sort-Object ProcessName, Id | Format-Table -AutoSize

Write-Host ''
Write-Host 'System-managed files (report only; never modified by this skill):'
Get-ChildItem -LiteralPath $driveRoot -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('hiberfil.sys', 'pagefile.sys', 'swapfile.sys') } |
    Select-Object Name, @{Name = 'Size'; Expression = { Format-ByteSize ([Int64]$_.Length) } }, FullName |
    Format-Table -AutoSize
