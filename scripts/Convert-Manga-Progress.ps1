# Display helpers kept separate to allow lightweight tests without starting conversion.
function Get-MangaProgressPercent {
    param([int]$Completed, [int]$Total)
    if ($Total -le 0) { return 0 }
    return [int][Math]::Floor(100 * ([Math]::Min($Total, [Math]::Max(0, $Completed)) / [double]$Total))
}

# Format processing time as HH:MM:SS.t (tenths of a second).
function Format-MangaElapsed {
    param([Parameter(Mandatory = $true)][TimeSpan]$Duration)
    $hours = [int][Math]::Floor($Duration.TotalHours)
    $tenths = [int][Math]::Floor($Duration.Milliseconds / 100)
    return ('{0:D2}:{1:D2}:{2:D2}.{3:D1}' -f $hours, $Duration.Minutes, $Duration.Seconds, $tenths)
}

function Write-MangaOverallProgress {
    param([int]$Completed, [int]$Total, [string]$Name = '', [switch]$Done)
    if ($Done) {
        Write-Progress -Id 1 -Activity 'BookConverter / 全体進捗' -Completed
        return
    }
    $status = '{0} / {1} 件処理済み | {2}' -f $Completed, $Total, $Name
    Write-Progress -Id 1 -Activity 'BookConverter / 全体進捗' -Status $status `
        -PercentComplete (Get-MangaProgressPercent -Completed $Completed -Total $Total)
}

function Write-MangaStage {
    param([Parameter(Mandatory = $true)][string]$Name,
          [Parameter(Mandatory = $true)][string]$Stage)
    Write-Host ('  [工程] {0}: {1}' -f $Stage, $Name) -ForegroundColor Cyan
}