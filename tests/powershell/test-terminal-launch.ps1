#requires -Version 7.6
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $root 'scripts/BookConverter-TerminalLaunch.ps1')

function Assert {param([bool]$Ok,[string]$Why)if(-not $Ok){throw $Why}}
function Assert-Eq {param($Actual,$Expected,[string]$Why)if($Actual -cne $Expected){throw "$Why (expected <$Expected>, got <$Actual>)"}}

$paths=@(
    'C:\漫画\空 白.cbz',
    'D:\本\著者''の漫画&雑誌; $(throw ''INJECTION'') [v2] !^%?.epub',
    '\\server\share\日本語 トリック + 資料.cbz',
    'C:\input\(作品名) vol05.cbz'
)
$modes=@{
    Manga=@()
    Magazine=@('-Magazine')
}
$main=Join-Path $root 'scripts/Convert-Manga.ps1'
foreach($mode in @('Manga','Magazine')){
    $plan=New-BookConverterTerminalLaunch -MainScript $main -PowerShellPath 'C:\Program Files\PowerShell\7\pwsh.exe' -Mode $mode -DroppedPaths $paths
    Assert-Eq $plan.FileName 'wt.exe' 'wt executable'
    Assert-Eq $plan.Arguments[0] '-w' 'must open a dedicated window'
    Assert-Eq $plan.Arguments[1] 'new' 'new window required'
    Assert-Eq $plan.Arguments[2] 'new-tab' 'terminal tab required'
    Assert ($plan.Arguments -contains '-EncodedCommand') 'EncodedCommand prevents WT parsing file names as tab delimiters'
    $encoded=$plan.Arguments[-1]
    $decoded=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
    Assert (-not ($decoded.Contains('INJECTION'+"'"+')'))) 'Unexpected token quoting'
    Assert ($decoded.Contains("''INJECTION''")) 'Single quotes must be doubled in encoded literal'
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($decoded,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) "Encoded command parse errors in $mode"
    # No dropped path becomes a raw terminal command or a separate argument.
    Assert ($plan.Arguments.Count -lt 15) 'Dropped paths must not be forwarded raw to wt.exe'

    # Executed in a test harness, the encoded PowerShell must reconstruct every
    # literal path exactly; no PowerShell expressions from names may execute.
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('BookTermLaunch_'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    try{
        $receiver=Join-Path $temp 'receiver.ps1'
        $receiverContent=@'
param(
    [switch]$Magazine,
    [string[]]$DroppedPaths
)
[pscustomobject]@{
    Magazine=[bool]$Magazine
    Paths=@($DroppedPaths)
} | ConvertTo-Json -Depth 8 -Compress
'@
        [IO.File]::WriteAllText($receiver,$receiverContent,[Text.UTF8Encoding]::new($false))
        $testPlan=New-BookConverterTerminalLaunch -MainScript $receiver -PowerShellPath 'pwsh.exe' -Mode $mode -DroppedPaths $paths
        $actualJson=& pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $testPlan.Arguments[-1]
        Assert-Eq $LASTEXITCODE 0 'Encoded child command failed'
        $actual=$actualJson | ConvertFrom-Json
        Assert-Eq $actual.Paths.Count $paths.Count "Input argument count differs for $mode"
        for($i=0;$i -lt $paths.Count;$i++){Assert-Eq $actual.Paths[$i] $paths[$i] "Dropped path $i was modified for $mode"}
        Assert-Eq $actual.Magazine ($mode -eq 'Magazine') "Magazine mode mismatch for $mode"
    }finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
}

foreach($name in @('Convert-Manga.bat','Convert-Manga-Magazine.bat')){
    $bat=Get-Content -LiteralPath (Join-Path $root $name) -Raw -Encoding utf8
    Assert ($bat.Contains('Start-BookConverter-Terminal.ps1')) "BAT does not hand off to Windows Terminal: $name"
    Assert ($bat.Contains('%*')) "BAT lost drag-and-drop arguments: $name"
    Assert ($bat.Contains('DisableDelayedExpansion')) "BAT delayed expansion may corrupt exclamation marks: $name"
    $expectedMode=if($name -eq 'Convert-Manga-Magazine.bat'){'Magazine'}else{'Manga'}
    Assert ($bat.Contains("-Mode $expectedMode")) "Incorrect manga/magazine launcher: $name"
}
$updater=Get-Content -LiteralPath (Join-Path $root 'Update-BookConverter.bat') -Raw
Assert (-not $updater.Contains('Start-BookConverter-Terminal.ps1')) 'Updater must not be modified'
$launcher=Get-Content -LiteralPath (Join-Path $root 'scripts/Start-BookConverter-Terminal.ps1') -Raw
Assert ($launcher.Contains('Get-Command wt.exe')) 'Windows Terminal availability must be checked'
Assert ($launcher.Contains('ProcessStartInfo')) 'Launch must use argument list and not CMD string interpolation'
Write-Host 'PASS: two Hybrid BATs launched via WT, literal paths and updater unaffected'
