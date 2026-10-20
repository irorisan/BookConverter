$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$sourceFiles = @('Convert-Manga.ps1', 'Convert-Manga-Epub.ps1', 'Convert-Manga-Progress.ps1')
foreach ($filename in $sourceFiles) {
    $file = Join-Path $root $filename
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing source: $filename" }
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "Syntax errors in ${filename}: $($parseErrors -join '; ')" }
}
if (-not (Test-Path (Join-Path $root 'Convert-Manga.bat'))) { throw 'Missing BAT' }
if (-not (Test-Path (Join-Path $root 'README.md'))) { throw 'Missing README' }
$mainSource = Get-Content -LiteralPath (Join-Path $root 'Convert-Manga.ps1') -Raw -Encoding UTF8
foreach ($needle in @('Write-MangaOverallProgress', 'Write-MangaStage',
        'Write-Progress -Id 2 -ParentId 1', '上限超過: $oversized')) {
    if (-not $mainSource.Contains($needle)) { throw "Missing progress integration: $needle" }
}

. (Join-Path $root 'Convert-Manga-Progress.ps1')

function Assert-Eq {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message : expected <$Expected> but got <$Actual>" }
}

Assert-Eq (Get-MangaProgressPercent -Completed 0 -Total 0) 0 'zero items'
Assert-Eq (Get-MangaProgressPercent -Completed 0 -Total 3) 0 'none done'
Assert-Eq (Get-MangaProgressPercent -Completed 1 -Total 4) 25 'quarter done'
Assert-Eq (Get-MangaProgressPercent -Completed 3 -Total 3) 100 'all done'
Assert-Eq (Get-MangaProgressPercent -Completed 9 -Total 4) 100 'clamp high'
Assert-Eq (Get-MangaProgressPercent -Completed -1 -Total 4) 0 'clamp low'

$script:progressCalls = [System.Collections.Generic.List[object]]::new()
function Write-Progress {
    param([int]$Id, [int]$ParentId, [string]$Activity, [string]$Status,
          [int]$PercentComplete, [switch]$Completed)
    $script:progressCalls.Add([pscustomobject]@{
        Id = $Id; ParentId = $ParentId; Activity = $Activity; Status = $Status;
        PercentComplete = $PercentComplete; Completed = [bool]$Completed
    })
}
Write-MangaOverallProgress -Completed 1 -Total 4 -Name '作品 v02.cbz'
Assert-Eq $script:progressCalls.Count 1 'one overall call'
Assert-Eq $script:progressCalls[0].Id 1 'overall id'
Assert-Eq $script:progressCalls[0].PercentComplete 25 'overall progress'
if (-not $script:progressCalls[0].Status.Contains('作品 v02.cbz')) { throw 'output name missing in overall status' }
Write-MangaOverallProgress -Completed 4 -Total 4 -Done
Assert-Eq $script:progressCalls.Count 2 'completion call'
Assert-Eq $script:progressCalls[1].Completed $true 'progress completed'

$script:hostMessages = [System.Collections.Generic.List[string]]::new()
function Write-Host {
    param([string]$Object, [ConsoleColor]$ForegroundColor)
    $script:hostMessages.Add($Object)
}
Write-MangaStage -Name '日本語作品 v12.cbz' -Stage 'CBZ検証'
Assert-Eq $script:hostMessages.Count 1 'stage log count'
if (-not $script:hostMessages[0].Contains('日本語作品 v12.cbz') -or
    -not $script:hostMessages[0].Contains('CBZ検証')) { throw 'stage status missing expected contents' }
[Console]::WriteLine('PASS: PowerShell syntax and progress helper tests')