$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $repo 'scripts\GPU-Functions.ps1')

if ((Convert-GpuQualityToCq -Quality 30) -ne 50) { throw 'GPU quality low endpoint changed' }
if ((Convert-GpuQualityToCq -Quality 95) -ne 15) { throw 'GPU quality high endpoint changed' }
$previous = 100
foreach ($quality in 30..95) {
    $cq = Convert-GpuQualityToCq -Quality $quality
    if ($cq -gt $previous) { throw 'NVENC CQ mapping is non-monotonic' }
    $previous = $cq
}
$args = Get-GpuEncodeArguments -Quality 75 -InputPath 'C:\image.png' -OutputPath 'C:\image.avif'
foreach ($token in @('av1_nvenc', '-preset p7', '-f avif', '-pix_fmt yuv420p', '-frames:v 1', '-tune hq', '-rc vbr', '-nostdin')) {
    if (-not $args.Contains($token)) { throw "GPU encoder argument missing: $token" }
}
if ($args.Contains('-preset p4')) { throw 'Old GPU p4 preset must not be used' }
# The temporary benchmark selector and multi-output generator must be gone.
foreach ($oldName in @('Get-GpuBenchmarkPreset', 'Get-GpuBatchProcessLimit', 'Get-GpuBatchEncodeArguments')) {
    if (Get-Command $oldName -CommandType Function -ErrorAction SilentlyContinue) {
        throw "Unused GPU benchmark function remains: $oldName"
    }
}
if (Get-Command Invoke-GpuEncodeBatch -CommandType Function -ErrorAction SilentlyContinue) {
    throw 'The obsolete multi-output GPU encoder still exists'
}
foreach ($path in @((Join-Path $repo 'scripts\GPU-Functions.ps1'), (Join-Path $repo 'scripts\Convert-Manga.ps1'))) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw "PowerShell parse error in $path : $($errors[0])" }
}
foreach ($batch in @('Convert-Manga.bat', 'Convert-Manga-Magazine.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $repo $batch) -PathType Leaf)) {
        throw "Missing Hybrid BAT: $batch"
    }
}
# AVIF verification must decode every page in bounded FFmpeg batches.
$verifyPaths = @(1..8 | ForEach-Object { 'C:\test\page_{0:D3}.avif' -f $_ })
$verifyArgs = Get-GpuVerifyArguments -Paths $verifyPaths
foreach ($token in @('-xerror', '-max_error_rate 0', '-f null NUL')) {
    if (-not $verifyArgs.Contains($token)) { throw "Missing FFmpeg verification option: $token" }
}
if ($verifyArgs.Contains('-c copy')) { throw 'AVIF verification must decode rather than copy streams' }
foreach ($i in 0..7) {
    if (-not $verifyArgs.Contains(('-map {0}:v:0' -f $i))) { throw "Missing decode stream $i" }
}
if ($verifyArgs.Contains('-map 8:v:0')) { throw 'Unexpected extra stream mapping' }
if (($verifyArgs.Split([string[]]@(' -i '),[StringSplitOptions]::None).Count - 1) -ne 8) {
    throw 'Each AVIF input must have a distinct -i'
}

# GPU must use one AVIF output and one input per FFmpeg process.
$singleArgs = Get-GpuEncodeArguments -Quality 75 -InputPath 'C:\imgs\001.png' -OutputPath 'C:\out\001.avif'
foreach ($token in @('-i ', '-preset p7', '-frames:v 1', '-f avif', '-nostdin')) {
    if (-not $singleArgs.Contains($token)) { throw "Missing single-image AVIF option: $token" }
}
if ($singleArgs.Contains(' -map 1:v:0')) { throw 'Single-image encoder must not map a second stream' }

$sourceText = Get-Content -LiteralPath (Join-Path $repo 'scripts\Convert-Manga.ps1') -Raw -Encoding UTF8
if ($sourceText.Contains('GPUプリセット [1-4]') -or
    $sourceText.Contains('Get-GpuBenchmarkPreset -Choice') -or
    $sourceText.Contains('-GpuBatchSize')) {
    throw 'Temporary GPU benchmark selection still exists'
}
if (-not $sourceText.Contains('$workers = $GpuWorkers') -or
    -not $sourceText.Contains('Invoke-ParallelAvif')) {
    throw 'GPU encoder must use fixed twelve-process single-image path'
}
$sampleStart = $sourceText.IndexOf('function Get-AvifSampleEstimate')
$sampleEnd = $sourceText.IndexOf('function Find-AvifQuality')
if ($sampleStart -lt 0 -or $sampleEnd -le $sampleStart -or
    -not $sourceText.Substring($sampleStart,$sampleEnd-$sampleStart).Contains('Invoke-ParallelAvif')) {
    throw 'GPU quality samples must use the same fixed GPU encoder'
}

Write-Host 'Hybrid GPU quality mapping, command arguments, PowerShell syntax and BATs: OK'
