#requires -Version 7.6
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
function Check {param([bool]$Ok,[string]$Why)if(-not $Ok){throw $Why}}
$conversionBats=@(Get-ChildItem -LiteralPath $root -File -Filter 'Convert-Manga*.bat')
Check ($conversionBats.Count -eq 2) 'Only manga and magazine converter BATs should remain'
foreach($file in @('Convert-Manga.bat','Convert-Manga-Magazine.bat')){
    $bat=Join-Path $root $file
    Check (Test-Path -LiteralPath $bat -PathType Leaf) "Missing Hybrid BAT $file"
    $src=Get-Content -LiteralPath $bat -Raw -Encoding UTF8
    Check ($src.Contains('Start-BookConverter-Terminal.ps1')) 'Keep Windows Terminal launcher'
    Check ($src.Contains('%*')) 'Keep dragged-path arguments'
    Check ($src.Contains('DisableDelayedExpansion')) 'Keep literal path safety'
}
Check (Test-Path -LiteralPath (Join-Path $root 'Update-BookConverter.bat')) 'Keep updater'
$main=Get-Content -LiteralPath (Join-Path $root 'scripts/Convert-Manga.ps1') -Raw -Encoding UTF8
$terminal=Get-Content -LiteralPath (Join-Path $root 'scripts/BookConverter-TerminalLaunch.ps1') -Raw -Encoding UTF8
$starter=Get-Content -LiteralPath (Join-Path $root 'scripts/Start-BookConverter-Terminal.ps1') -Raw -Encoding UTF8
Check ($main -notmatch "ValidateSet\('Legacy','GPU','Hybrid'\)") 'Legacy/standalone GPU mode switch is obsolete'
Check ($main -notmatch '並列数 \[1-16\]|\$autoWorkers|\$workerInput') 'Legacy CPU workers prompt must be removed'
Check ($main -notmatch '\$GPU\b|\$ConversionMode\b') 'Legacy mode flags should not survive'
Check ($main -match 'Invoke-HybridQualitySearch') 'Hybrid quality exploration must remain'
Check ($main -match 'Invoke-GpuLedHybridConversion') 'GPU-led CPU calibration/caching must remain'
Check ($main -notmatch 'avifenc\.exeでの変換に失敗しました（終了コード') 'Obsolete Legacy CPU encoder loop remains'
Check ($terminal -match "ValidateSet\('Manga','Magazine','Split'\)") 'Terminal command builder must keep two converters and separate Split utility'
Check ($starter -match "ValidateSet\('Manga','Magazine','Split'\)") 'Terminal launcher must keep two converters and separate Split utility'
Check ($terminal -notmatch "'-ConversionMode Hybrid'") 'Hybrid should be unconditional, not user-selected'
$bench=Get-Content -LiteralPath (Join-Path $root 'scripts/Benchmark-Hybrid.ps1') -Raw -Encoding UTF8
Check ($bench -notmatch "'GPU','Hybrid'|'-ConversionMode|GPU wall-time change") 'Benchmark must not compare removed GPU-only mode'
Check ($main -match 'Select-AvifVerificationSamples') 'Keep sample verification'
Check ($main -match '70MiB') 'Keep capacity refusal'
Write-Host 'PASS: Hybrid-only two BAT entrypoints, no legacy CPU/GPU mode, safety hooks retained'
