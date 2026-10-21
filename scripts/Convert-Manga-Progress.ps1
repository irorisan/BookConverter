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
# Print non-overlapping per-volume wall times after the volume has been processed.
# Sample encoding and sample verification are included only in 品質探索.
function Write-MangaTimingReport {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Stages,
        [Parameter(Mandatory = $true)][TimeSpan]$Total
    )

    Write-Host ('  [処理時間] {0}' -f $Name) -ForegroundColor Cyan
    $measuredTicks = [long]0
    foreach ($label in $Stages.Keys) {
        $duration = [TimeSpan]$Stages[$label]
        if ($duration.Ticks -le 0) { continue }
        $measuredTicks += $duration.Ticks
        Write-Host ('    {0}: {1}' -f $label, (Format-MangaElapsed -Duration $duration))
    }
    $otherTicks = [Math]::Max([long]0, $Total.Ticks - $measuredTicks)
    if ($otherTicks -gt 0) {
        Write-Host ('    その他: {0}' -f (Format-MangaElapsed -Duration ([TimeSpan]::FromTicks($otherTicks))))
    }
    Write-Host ('    合計: {0}' -f (Format-MangaElapsed -Duration $Total)) -ForegroundColor Cyan
}
