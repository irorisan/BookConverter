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
if (-not (Get-Command Invoke-GpuEncodePages -CommandType Function -ErrorAction SilentlyContinue)) {
    throw 'Expected fixed one-image-per-FFmpeg encoder'
}
foreach ($path in @((Join-Path $repo 'scripts\GPU-Functions.ps1'), (Join-Path $repo 'scripts\Convert-Manga.ps1'))) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw "PowerShell parse error in $path : $($errors[0])" }
}
foreach ($batch in @('Convert-Manga-GPU.bat', 'Convert-Manga-Magazine-GPU.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $repo $batch) -PathType Leaf)) {
        throw "Missing GPU BAT: $batch"
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

# Compile a tiny fake FFmpeg command to test real ProcessStartInfo batch scheduling
# without requiring AV1 hardware on Windows GitHub Actions.
$temp = Join-Path ([IO.Path]::GetTempPath()) ('BookConv_GpuVerifyTest_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $fakeExe = Join-Path $temp 'mock_ffmpeg.exe'
    $logDir = Join-Path $temp 'invocations'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $fakeCode = @'
using System;
using System.IO;
using System.Diagnostics;
public static class MockFfmpegVerification {
    public static int Main(string[] args) {
        string dir = Environment.GetEnvironmentVariable("BOOKCONV_VERIFY_LOGDIR");
        File.WriteAllLines(Path.Combine(dir, Guid.NewGuid().ToString("N") + ".txt"), args);
        int inputs = 0, maps = 0;
        for (int i = 0; i < args.Length; i++) {
            if (args[i] == "-i") {
                inputs++;
                if (i + 1 >= args.Length) return 10;
                if (args[i + 1].EndsWith("broken.avif", StringComparison.OrdinalIgnoreCase)) return 7;
            }
            if (args[i] == "-map") maps++;
        }
        return (inputs > 0 && inputs == maps && inputs <= 8) ? 0 : 11;
    }
}
'@
    Add-Type -TypeDefinition $fakeCode -OutputAssembly $fakeExe -OutputType ConsoleApplication -ErrorAction Stop
    $env:BOOKCONV_VERIFY_LOGDIR = $logDir

    $seventeen = @(1..17 | ForEach-Object { 'C:\test\page_{0:D3}.avif' -f $_ })
    Invoke-GpuVerifyAvifBatch -Paths $seventeen -FFmpeg $fakeExe -Workers 8
    $logs = @(Get-ChildItem -LiteralPath $logDir -Filter '*.txt')
    if ($logs.Count -ne 3) { throw "Expected 3 FFmpeg launches for 17 images, got $($logs.Count)" }
    $counts = @($logs | ForEach-Object {
        @((Get-Content -LiteralPath $_.FullName) | Where-Object { $_ -eq '-i' }).Count
    } | Sort-Object)
    if (($counts -join ',') -ne '1,8,8') { throw "Invalid batch input counts: $($counts -join ',')" }

    Get-ChildItem -LiteralPath $logDir -Filter '*.txt' | Remove-Item -Force
    $twoFifty = @(1..250 | ForEach-Object { 'C:\test\page_{0:D3}.avif' -f $_ })
    Invoke-GpuVerifyAvifBatch -Paths $twoFifty -FFmpeg $fakeExe -Workers 8
    $logs = @(Get-ChildItem -LiteralPath $logDir -Filter '*.txt')
    if ($logs.Count -ne 32) { throw "Expected 32 FFmpeg launches for 250 images, got $($logs.Count)" }
    $totalMapped = 0
    foreach ($log in $logs) {
        $line = @(Get-Content -LiteralPath $log.FullName)
        $inputCount = @($line | Where-Object { $_ -eq '-i' }).Count
        $mapCount = @($line | Where-Object { $_ -eq '-map' }).Count
        if ($inputCount -ne $mapCount) { throw 'A batch omitted input stream mapping' }
        $totalMapped += $mapCount
    }
    if ($totalMapped -ne 250) { throw "Expected 250 decoded pages, got $totalMapped" }

    $failed = $false
    try {
        Invoke-GpuVerifyAvifBatch -Paths @('C:\test\okay.avif','C:\test\broken.avif') -FFmpeg $fakeExe -Workers 8
    }
    catch {
        $failed = $true
        if ($_.Exception.Message -notmatch 'broken.avif') {
            throw "Failure must identify failed group: $($_.Exception.Message)"
        }
    }
    if (-not $failed) { throw 'Failed FFmpeg verification must reject the volume' }
}
finally {
    Remove-Item Env:BOOKCONV_VERIFY_LOGDIR -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'GPU batched decoding: all inputs mapped, 250 pages in 32 processes, failures propagated'


# GPU must use one AVIF output and one input per FFmpeg process.
$singleArgs = Get-GpuEncodeArguments -Quality 75 -InputPath 'C:\imgs\001.png' -OutputPath 'C:\out\001.avif'
foreach ($token in @('-i ', '-preset p7', '-frames:v 1', '-f avif', '-nostdin')) {
    if (-not $singleArgs.Contains($token)) { throw "Missing single-image AVIF option: $token" }
}
if ($singleArgs.Contains(' -map 1:v:0')) { throw 'Single-image encoder must not map a second stream' }

$encodeTemp = Join-Path ([IO.Path]::GetTempPath()) ('BookConv_EncodeTest_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $encodeTemp -Force | Out-Null
try {
    $fakeEncoder = Join-Path $encodeTemp 'fake_ffmpeg.exe'
    $logDir = Join-Path $encodeTemp 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $code = @'
using System;
using System.IO;
using System.Diagnostics;
using System.Collections.Generic;
public static class MockEncode {
    public static int Main(string[] args) {
        string log = Environment.GetEnvironmentVariable("BOOKCONV_ENCODE_LOGDIR");
        File.WriteAllLines(Path.Combine(log, Guid.NewGuid().ToString("N") + ".txt"), args);
        if (Environment.GetEnvironmentVariable("BOOKCONV_ENCODE_FAIL") == "1") return 15;
        int inputs = 0, maps = 0;
        var outputs = new List<string>();
        bool preset = false;
        for (int i=0; i<args.Length; i++) {
            if (args[i] == "-i") inputs++;
            if (args[i] == "-map") maps++;
            if (args[i] == "-preset" && i+1<args.Length && args[i+1] == "p7") preset = true;
            if (args[i].EndsWith(".avif", StringComparison.OrdinalIgnoreCase)) outputs.Add(args[i]);
        }
        if (inputs!=1 || maps>1 || outputs.Count != 1 || !preset) return 16;
        byte[] header = {0,0,0,16,102,116,121,112,97,118,105,102,0,0,0,0};
        foreach (string path in outputs) File.WriteAllBytes(path, header);
        return 0;
    }
}
'@
    Add-Type -TypeDefinition $code -OutputAssembly $fakeEncoder -OutputType ConsoleApplication -ErrorAction Stop
    $env:BOOKCONV_ENCODE_LOGDIR = $logDir

    # The GPU helper mutates entries in the same shape used by full-volume conversion.
    function Test-AvifOutput {
        param([string]$Path)
        if (-not [IO.File]::Exists($Path)) { throw "Missing AVIF file: $Path" }
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ([Text.Encoding]::ASCII.GetString($bytes, 4, 4) -ne 'ftyp' -or
            [Text.Encoding]::ASCII.GetString($bytes, 8, 4) -ne 'avif') { throw 'Not an AVIF header' }
    }
    $images = [System.Collections.Generic.List[object]]::new()
    1..9 | ForEach-Object {
        $inputPath = Join-Path $encodeTemp ('source_{0:D2}.png' -f $_)
        [IO.File]::WriteAllBytes($inputPath, [byte[]]@(1,2,3))
        $images.Add([pscustomobject]@{
            SourcePath = $inputPath
            EntryName = ('page_{0:D2}.avif' -f $_)
            NeedsConversion = $true
            Extension = '.png'
            Length = 3L
        })
    }
    $outputDir = Join-Path $encodeTemp 'output'
    $convertedPaths = @(Invoke-GpuEncodePages -Entries $images.ToArray() -FFmpeg $fakeEncoder -Quality 75 -TempDir $outputDir -OutputName 'test')
    if ($convertedPaths.Count -ne 9) { throw "Expected 9 encoded pages, got $($convertedPaths.Count)" }
    foreach ($entry in $images) { Test-AvifOutput -Path $entry.SourcePath }
    $logs = @(Get-ChildItem -LiteralPath $logDir -Filter '*.txt')
    if ($logs.Count -ne 9) { throw "Expected 9 FFmpeg encoding launches for 9 pages, got $($logs.Count)" }
    $counts = @($logs | ForEach-Object {
        @((Get-Content -LiteralPath $_.FullName) | Where-Object { $_ -eq '-i' }).Count
    } | Sort-Object)
    if (($counts -join ',') -ne '1,1,1,1,1,1,1,1,1') { throw "Unexpected image grouping: $($counts -join ',')" }


    # Twelve images produce twelve independent FFmpeg launches; no preset chosen.
    $twelve = [System.Collections.Generic.List[object]]::new()
    foreach ($number in 1..12) {
        $inputPath = Join-Path $encodeTemp ('fixed_{0:D2}.png' -f $number)
        [IO.File]::WriteAllBytes($inputPath, [byte[]]@(1,2,3))
        $twelve.Add([pscustomobject]@{
            SourcePath = $inputPath
            EntryName = ('fixed_{0:D2}.avif' -f $number)
            NeedsConversion = $true
            Extension = '.png'
            Length = 3L
        })
    }
    Get-ChildItem -LiteralPath $logDir -Filter '*.txt' | Remove-Item -Force
    $fixedOutput = Join-Path $encodeTemp 'fixed_12'
    $converted = @(Invoke-GpuEncodePages -Entries $twelve.ToArray() -FFmpeg $fakeEncoder -Quality 75 -TempDir $fixedOutput -OutputName 'fixed')
    if ($converted.Count -ne 12) { throw "Fixed GPU encoder produced $($converted.Count)/12 pages" }
    $fixedLogs = @(Get-ChildItem -LiteralPath $logDir -Filter '*.txt')
    if ($fixedLogs.Count -ne 12) { throw "Expected 12 independent FFmpeg launches, got $($fixedLogs.Count)" }
    foreach ($log in $fixedLogs) {
        $lines = @(Get-Content -LiteralPath $log.FullName)
        if (@($lines | Where-Object { $_ -eq '-i' }).Count -ne 1) {
            throw 'Each encoder invocation must have one input'
        }
    }
    foreach ($entry in $twelve) { Test-AvifOutput -Path $entry.SourcePath }
    $sourceText = Get-Content -LiteralPath (Join-Path $repo 'scripts\Convert-Manga.ps1') -Raw -Encoding UTF8
    if ($sourceText.Contains('GPUプリセット [1-4]') -or
        $sourceText.Contains('Get-GpuBenchmarkPreset -Choice') -or
        $sourceText.Contains('-GpuBatchSize')) {
        throw 'Temporary GPU benchmark selection still exists'
    }
    if (-not $sourceText.Contains('$workers = 12') -or
        -not $sourceText.Contains('Invoke-GpuEncodePages')) {
        throw 'GPU encoder must use fixed twelve-process single-image path'
    }
    $sampleStart = $sourceText.IndexOf('function Get-AvifSampleEstimate')
    $sampleEnd = $sourceText.IndexOf('function Find-AvifQuality')
    if ($sampleStart -lt 0 -or $sampleEnd -le $sampleStart -or
        -not $sourceText.Substring($sampleStart,$sampleEnd-$sampleStart).Contains('-GpuBatch:$GPU')) {
        throw 'GPU quality samples must use the same fixed GPU encoder'
    }
    Write-Host 'GPU fixed 12 processes / 1 image: mock FFmpeg validated for 9 and 12 pages'
    $env:BOOKCONV_ENCODE_FAIL = '1'
    $failed = $false
    $failEntries = [System.Collections.Generic.List[object]]::new()
    $failEntries.Add([pscustomobject]@{
        SourcePath = (Join-Path $encodeTemp 'source_01.png')
        EntryName = 'bad.avif'
        NeedsConversion = $true
        Extension = '.png'
        Length = 3L
    })
    try {
        [void](Invoke-GpuEncodePages -Entries $failEntries.ToArray() -FFmpeg $fakeEncoder -Quality 75 -TempDir (Join-Path $encodeTemp 'failed') -OutputName 'failed')
    } catch { $failed = $true }
    if (-not $failed) { throw 'Nonzero FFmpeg exit must fail the volume, never silently fall back to CPU' }
}
finally {
    Remove-Item Env:BOOKCONV_ENCODE_LOGDIR -ErrorAction SilentlyContinue
    Remove-Item Env:BOOKCONV_ENCODE_FAIL -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $encodeTemp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'GPU single-image encoding: 12 processes fixed, fail-closed: OK'

Write-Host 'GPU quality mapping, command arguments, PowerShell syntax and BATs: OK'
