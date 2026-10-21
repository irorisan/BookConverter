# Display helpers kept separate to allow lightweight tests without starting conversion.
# PowerShell 7 uses Minimal by default; Classic renders parent and child bars
# together in ConsoleHost and Windows Terminal without custom cursor control.
function Initialize-MangaProgress {
    $PSStyle.Progress.View = 'Classic'
}

# A concise pure formatter makes progress truthful and easy to test without
# a real terminal. Probing measures iterations/s; encoding measures pages/s.
function Format-MangaProgressStatus {
    param(
        [string]$Activity,
        [int]$Completed,
        [int]$Total,
        [string]$Unit='枚',
        [double]$ElapsedSeconds=0,
        [int]$Width=120,
        [int]$Workers=0,
        [string]$Detail=''
    )
    $done=[Math]::Min([Math]::Max(0,$Completed),[Math]::Max(0,$Total))
    $percentage=Get-MangaProgressPercent -Completed $Completed -Total $Total
    $count='{0} / {1} {2} | {3}%' -f $done,$Total,$Unit,$percentage
    if($Width -lt 60){return $count}
    $status="$Activity | $count"
    if($Width -lt 96){return $status}
    $speed='-'
    if($ElapsedSeconds -gt 0 -and $done -gt 0){
        $speed=('{0:F2} {1}/s' -f ($done/$ElapsedSeconds),$Unit)
    }
    $milliseconds=[long][Math]::Floor([Math]::Max([double]0,$ElapsedSeconds)*1000)
    $elapsed=Format-MangaElapsed -Duration ([TimeSpan]::FromMilliseconds($milliseconds))
    $status+=' | 速度 '+$speed+' | 経過 '+$elapsed
    if($Width -ge 155){
        if($Detail){$status+=" | $Detail"}
        if($Workers -gt 0){$status+=" | 並列数 $Workers"}
    }
    return $status
}

# Width-sensitive fallback: no custom cursor movement, colors or animations.
function Get-MangaProgressWidth {
    try {
        $columns=[Console]::WindowWidth
        if($columns -gt 0){return [int]$columns}
    } catch {
        # Redirected and test hosts may have no console width.
    }
    return 120
}

# ID 2 is the active task. Its own clock resets at task transitions and closes
# after cancellation, failure or success. GPU and CPU worker threads never draw.
function Write-MangaPageProgress {
    param([int]$Completed, [int]$Total, [string]$Activity='AVIF並列変換',
          [int]$Workers=0, [string]$Unit='枚', [string]$Detail='', [switch]$Done)
    $heading='BookConverter / 現在のタスク進捗'
    if($Done){
        $script:MangaCurrentTaskClock=$null
        $script:MangaCurrentTaskName=$null
        Write-Progress -Id 2 -ParentId 1 -Activity $heading -Completed
        return
    }
    if($null -eq $script:MangaCurrentTaskClock -or
        $script:MangaCurrentTaskName -ne $Activity){
        $script:MangaCurrentTaskClock=[Diagnostics.Stopwatch]::StartNew()
        $script:MangaCurrentTaskName=$Activity
    }
    $status=Format-MangaProgressStatus -Activity $Activity -Completed $Completed -Total $Total `
        -Unit $Unit -ElapsedSeconds $script:MangaCurrentTaskClock.Elapsed.TotalSeconds `
        -Width (Get-MangaProgressWidth) -Workers $Workers -Detail $Detail
    Write-Progress -Id 2 -ParentId 1 -Activity $heading -Status $status `
        -PercentComplete (Get-MangaProgressPercent -Completed $Completed -Total $Total)
}

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
    $heading='BookConverter / 全体のタスク進捗'
    if($Done){
        $script:MangaBatchClock=$null
        Write-Progress -Id 1 -Activity $heading -Completed
        return
    }
    if($null -eq $script:MangaBatchClock){
        $script:MangaBatchClock=[Diagnostics.Stopwatch]::StartNew()
    }
    $completedCount=[Math]::Min([Math]::Max(0,$Completed),[Math]::Max(0,$Total))
    $status='{0} / {1} 件 | {2}% | 経過 {3}' -f $completedCount,$Total,
        (Get-MangaProgressPercent -Completed $Completed -Total $Total),
        (Format-MangaElapsed -Duration $script:MangaBatchClock.Elapsed)
    $width=Get-MangaProgressWidth
    if($width -lt 55){$status='{0} / {1} 件 | {2}%' -f $completedCount,$Total,(Get-MangaProgressPercent -Completed $Completed -Total $Total)}
    elseif($width -ge 80 -and $Name){
        # Keep the title visible without letting Japanese names swallow the bar.
        $maxName=[Math]::Max(0,[int][Math]::Floor(($width-$status.Length-8)/2))
        if($maxName -gt 0){
            $shown=if($Name.Length -gt $maxName){$Name.Substring(0,[Math]::Max(0,$maxName-1))+'…'}else{$Name}
            $status+=" | $shown"
        }
    }
    Write-Progress -Id 1 -Activity $heading -Status $status `
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
