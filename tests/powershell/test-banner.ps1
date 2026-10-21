#requires -Version 7.6
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $root 'scripts/Convert-Manga-Banner.ps1')

function Assert-True {param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Assert-Equal {param($Actual,$Expected,[string]$Message)if($Actual -ne $Expected){throw "$Message (expected $Expected, got $Actual)"}}

$plain=@(Get-MangaStartupBannerLines -Width 80 -EnableAnsi:$false -ModeLabel 'MANGA / GPU')
Assert-Equal $plain.Count 2 'non-ANSI banner must have two short lines'
Assert-Equal $plain[0] 'BookConverter' 'plain identity'
Assert-True ($plain[1].Contains('MANGA / GPU')) 'plain mode label'
Assert-True (-not (($plain -join '') -match '\x1B|[^\x20-\x7E]')) 'redirected/plain must use ASCII and no escape sequences'

$small=@(Get-MangaStartupBannerLines -Width 59 -EnableAnsi -ModeLabel 'MAGAZINE / CPU')
Assert-Equal $small.Count 2 'narrow terminal must use short banner'
Assert-Equal $small[0] 'BookConverter' 'compact logo'
Assert-True (-not (($small -join '') -match '\x1B|[^\x20-\x7E]')) 'narrow banner must remain ASCII'

$styled=@(Get-MangaStartupBannerLines -Width 60 -EnableAnsi -ModeLabel 'MANGA / HYBRID')
Assert-True ($styled.Count -ge 12) 'colorful ASCII art missing'
Assert-True (($styled -join '') -match '\x1B\[38;2;') 'true-color ANSI escape missing'
Assert-True (($styled -join '') -match '█') 'pixel art is missing'
Assert-True (($styled -join '') -match 'AVIF') 'caption missing'
foreach($line in $styled){
    $visible=[regex]::Replace($line,'\x1B\[[0-9;]*m','')
    Assert-True ($visible.Length -le 60) 'banner overflows 60-column terminal'
    if($line.Contains([string][char]27)){
        Assert-True ($line.EndsWith("$([char]27)[0m")) 'ANSI color is not reset at end of line'
    }
}

Assert-True (Test-MangaBannerAnsi -IsConsole -HasAnsi -Width 80) 'ANSI capable terminal must be styled'
Assert-True (-not (Test-MangaBannerAnsi -IsConsole:$false -HasAnsi -Width 80)) 'redirected output must be plain'
Assert-True (-not (Test-MangaBannerAnsi -IsConsole -HasAnsi:$false -Width 80)) 'ANSI-disabled terminal must be plain'
Assert-True (-not (Test-MangaBannerAnsi -IsConsole -HasAnsi -NoColor -Width 80)) 'NO_COLOR must turn off ANSI'
Assert-True (-not (Test-MangaBannerAnsi -IsConsole -HasAnsi -Width 59)) 'narrow terminal must be plain'

$main=Join-Path $root 'scripts/Convert-Manga.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($main,[ref]$tokens,[ref]$errors)
Assert-Equal $errors.Count 0 'main script parse errors'
$integration=(Get-Content -LiteralPath $main -Raw -Encoding UTF8)
Assert-True ($integration.Contains(". (Join-Path `$PSScriptRoot 'Convert-Manga-Banner.ps1')")) 'banner helper not imported'
$invocations=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-MangaStartupBanner'},$true))
Assert-Equal $invocations.Count 1 'banner should be invoked exactly once per process'
$batch=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-MangaBatch'},$true)
Assert-True ($invocations[0].Extent.StartOffset -lt $batch.Extent.StartOffset) 'startup banner must be outside and before reusable batch logic'
Write-Host 'PASS: terminal banner art, narrow/plain fallback, ANSI resets, modes and one-time startup'
