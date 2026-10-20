# Display helpers kept separate to allow lightweight tests without starting conversion.
function Get-MangaProgressPercent {
    param([int]$Completed, [int]$Total)
    if ($Total -le 0) { return 0 }
    return [int][Math]::Floor(100 * ([Math]::Min($Total, [Math]::Max(0, $Completed)) / [double]$Total))
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