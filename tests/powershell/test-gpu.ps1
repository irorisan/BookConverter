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
foreach ($token in @('av1_nvenc', '-preset p7', '-f avif', '-pix_fmt yuv420p', '-frames:v 1', '-tune hq', '-rc vbr')) {
    if (-not $args.Contains($token)) { throw "GPU encoder argument missing: $token" }
}
if ($args.Contains('-preset p4')) { throw 'Old GPU p4 preset must not be used' }
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


# Phase 1: four independent NVENC AVIF output files per FFmpeg invocation.
$pairs = @(1..4 | ForEach-Object {
    [pscustomobject]@{
        InputPath = ('C:\imgs\{0}.png' -f $_)
        OutputPath = ('C:\out\{0}.avif' -f $_)
    }
})
$batchedArgs = Get-GpuBatchEncodeArguments -Jobs $pairs -Quality 75
foreach ($token in @('-preset p7', '-tune hq', '-rc vbr', '-frames:v 1', '-f avif')) {
    if (-not $batchedArgs.Contains($token)) { throw "Missing batch encoder option: $token" }
}
foreach ($index in 0..3) {
    if (-not $batchedArgs.Contains(('-map {0}:v:0' -f $index))) { throw "Missing batch output mapping: $index" }
}
if (($batchedArgs.Split([string[]]@(' -i '),[StringSplitOptions]::None).Count - 1) -ne 4) {
    throw 'Every input must be passed independently to batch encoder'
}
if (($batchedArgs.Split([string[]]@(' -f avif '),[StringSplitOptions]::None).Count - 1) -ne 4) {
    throw 'Each output must be a separate AVIF file'
}
if (($batchedArgs.Split([string[]]@(' -preset p7 '),[StringSplitOptions]::None).Count - 1) -ne 4) {
    throw 'Each output must use NVENC p7'
}
if ((Get-GpuBatchProcessLimit -Workers 8 -BatchSize 4) -ne 3 -or
    (Get-GpuBatchProcessLimit -Workers 1 -BatchSize 4) -ne 1) {
    throw 'GPU batching may not exceed twelve simultaneous NVENC sessions'
}

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
        if (inputs<1 || inputs>4 || maps != inputs || outputs.Count != inputs || !preset) return 16;
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
    $convertedPaths = @(Invoke-GpuEncodeBatch -Entries $images.ToArray() -FFmpeg $fakeEncoder -Quality 75 -Workers 8 -TempDir $outputDir -OutputName 'test')
    if ($convertedPaths.Count -ne 9) { throw "Expected 9 encoded pages, got $($convertedPaths.Count)" }
    foreach ($entry in $images) { Test-AvifOutput -Path $entry.SourcePath }
    $logs = @(Get-ChildItem -LiteralPath $logDir -Filter '*.txt')
    if ($logs.Count -ne 3) { throw "Expected 3 FFmpeg encoding launches for 9 pages, got $($logs.Count)" }
    $counts = @($logs | ForEach-Object {
        @((Get-Content -LiteralPath $_.FullName) | Where-Object { $_ -eq '-map' }).Count
    } | Sort-Object)
    if (($counts -join ',') -ne '1,4,4') { throw "Unexpected batch sizes: $($counts -join ',')" }


    # Temporary presets control both simultaneous FFmpeg processes and
    # independently encoded AVIF images per process.
    $presets = @(
        [pscustomobject]@{ Choice='1'; Processes=12; Images=1; Launches=12 }
        [pscustomobject]@{ Choice='2'; Processes=6; Images=2; Launches=6 }
        [pscustomobject]@{ Choice='3'; Processes=4; Images=3; Launches=4 }
        [pscustomobject]@{ Choice='4'; Processes=3; Images=4; Launches=3 }
    )
    if ($null -ne (Get-GpuBenchmarkPreset -Choice '0') -or
        $null -ne (Get-GpuBenchmarkPreset -Choice '5')) {
        throw 'Unknown GPU benchmark choice must be rejected'
    }
    foreach ($preset in $presets) {
        $actualPreset = Get-GpuBenchmarkPreset -Choice $preset.Choice
        if ($actualPreset.ProcessCount -ne $preset.Processes -or
            $actualPreset.BatchSize -ne $preset.Images) {
            throw "Wrong process/image configuration for preset $($preset.Choice)"
        }
        if ((Get-GpuBatchProcessLimit -Workers $preset.Processes -BatchSize $preset.Images) -ne $preset.Processes) {
            throw "GPU process limit does not match preset $($preset.Choice)"
        }
        $testEntries = [System.Collections.Generic.List[object]]::new()
        foreach ($number in 1..12) {
            $source = Join-Path $encodeTemp ('benchmark_{0:D2}.png' -f $number)
            [IO.File]::WriteAllBytes($source, [byte[]]@(1,2,3))
            $testEntries.Add([pscustomobject]@{
                SourcePath = $source
                EntryName = ('benchmark_{0:D2}.avif' -f $number)
                NeedsConversion = $true
                Extension = '.png'
                Length = 3L
            })
        }
        Get-ChildItem -LiteralPath $logDir -Filter '*.txt' | Remove-Item -Force
        $presetOutput = Join-Path $encodeTemp ('preset_' + $preset.Choice)
        $converted = @(Invoke-GpuEncodeBatch -Entries $testEntries.ToArray() -FFmpeg $fakeEncoder -Quality 75 -Workers $preset.Processes -BatchSize $preset.Images -TempDir $presetOutput -OutputName ('preset_' + $preset.Choice))
        if ($converted.Count -ne 12) { throw "Preset $($preset.Choice) produced only $($converted.Count) pages" }
        foreach ($entry in $testEntries) { Test-AvifOutput -Path $entry.SourcePath }
        $presetLogs = @(Get-ChildItem -LiteralPath $logDir -Filter '*.txt')
        if ($presetLogs.Count -ne $preset.Launches) {
            throw "Preset $($preset.Choice) expected $($preset.Launches) FFmpeg launches, got $($presetLogs.Count)"
        }
        $mapped = 0
        foreach ($log in $presetLogs) {
            $argsLine = @(Get-Content -LiteralPath $log.FullName)
            $inputs = @($argsLine | Where-Object { $_ -eq '-i' }).Count
            $maps = @($argsLine | Where-Object { $_ -eq '-map' }).Count
            if ($inputs -lt 1 -or $inputs -gt $preset.Images -or $inputs -ne $maps) {
                throw "Preset $($preset.Choice) has incorrect input/output mapping"
            }
            $mapped += $maps
        }
        if ($mapped -ne 12) { throw "Preset $($preset.Choice) omitted images" }
    }
    $entryCode = Get-Content -LiteralPath (Join-Path $repo 'scripts\Convert-Manga.ps1') -Raw -Encoding UTF8
    if (-not $entryCode.Contains('Get-GpuBenchmarkPreset -Choice') -or
        -not $entryCode.Contains('-GpuBatchSize $gpuBatchSize')) {
        throw 'GPU choice must reach both sample search and full conversion'
    }
    Write-Host 'GPU benchmark presets 1-4: distinct FFmpeg processes and output mappings: OK'

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
        [void](Invoke-GpuEncodeBatch -Entries $failEntries.ToArray() -FFmpeg $fakeEncoder -Quality 75 -Workers 4 -TempDir (Join-Path $encodeTemp 'failed') -OutputName 'failed')
    } catch { $failed = $true }
    if (-not $failed) { throw 'Nonzero FFmpeg exit must fail the volume, never silently fall back to CPU' }
}
finally {
    Remove-Item Env:BOOKCONV_ENCODE_LOGDIR -ErrorAction SilentlyContinue
    Remove-Item Env:BOOKCONV_ENCODE_FAIL -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $encodeTemp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'GPU encoding groups: separate AVIF outputs, 9 pages in 3 processes, failure propagation: OK'

Write-Host 'GPU quality mapping, command arguments, PowerShell syntax and BATs: OK'
