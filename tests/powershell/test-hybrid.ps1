$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repo 'scripts/GPU-Functions.ps1')
. (Join-Path $repo 'scripts/Hybrid-Functions.ps1')
# A deterministic approximately 10% final decode sample, with both encoder backends.
$verifyEntries = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt 243; $i++) {
    $verifyEntries.Add([pscustomobject]@{
        SourcePath = ('page{0:D3}.avif' -f $i)
        EncodedBy = $(if ($i -eq 7) { 'Cpu' } else { 'Gpu' })
    })
}
$samplePaths = [string[]]@(Select-AvifVerificationSamples -Entries $verifyEntries.ToArray())
if ($samplePaths.Count -ne 27 -or @($samplePaths | Select-Object -Unique).Count -ne 27) { throw 'Incorrect sampling rate or duplicate pages' }
foreach ($i in (0..24 | ForEach-Object { $_ * 10 }) + @(242,7)) {
    if ($samplePaths -cnotcontains ('page{0:D3}.avif' -f $i)) { throw "Required sample missing: $i" }
}
if ((@($samplePaths | Where-Object { $_ -eq 'page007.avif' })).Count -ne 1) { throw 'CPU representative was not included exactly once' }
foreach ($count in @(1,2,9,10,11,20)) {
    $short = @($verifyEntries | Select-Object -First $count)
    $paths = [string[]]@(Select-AvifVerificationSamples -Entries $short)
    if ($paths[0] -cne $short[0].SourcePath -or $paths[-1] -cne $short[-1].SourcePath) { throw "Missing first/last for $count pages" }
    if (@($paths | Select-Object -Unique).Count -ne $paths.Count) { throw "Duplicate short sample for $count" }
}
$mixed = @([pscustomobject]@{SourcePath='first.jpg'; EncodedBy=''},
    [pscustomobject]@{SourcePath='already.avif'; EncodedBy=''},
    [pscustomobject]@{SourcePath='last.avif'; EncodedBy='Cpu'})
$mixedPaths = [string[]]@(Select-AvifVerificationSamples -Entries $mixed)
if ($mixedPaths.Count -ne 2 -or $mixedPaths[0] -ne 'already.avif' -or $mixedPaths[1] -ne 'last.avif') { throw 'Existing AVIF and non-AVIF filtering failed' }

# Check the real quality-search/final-validation connection without process mocks.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/Convert-Manga.ps1'),[ref]$tokens,[ref]$errors)
if ($errors) { throw $errors[0] }
$batchNode=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-MangaBatch'},$true)
$finalVerify=@($batchNode.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-CpuVerifyAvifSamples'},$true))
if ($finalVerify.Count -eq 0) { throw 'Final per-volume CPU libavif validation must be retained' }
$sampleCommands=@($batchNode.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Select-AvifVerificationSamples'},$true))
if ($sampleCommands.Count -ne 1) { throw 'Final validation must use sample selection' }
$parallelNode=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ParallelAvif'},$true)
$hybridCalls=@($parallelNode.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-HybridEncode'},$true))
if ($hybridCalls.Count -ne 1) { throw 'Experimental encoding must retain the hybrid scheduler' }
Write-Host 'PASS: deterministic AVIF samples, encoder coverage, quality/final verification integration'
