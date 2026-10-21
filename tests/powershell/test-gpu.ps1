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
        File.WriteAllLines(Path.Combine(dir, Process.GetCurrentProcess().Id.ToString() + ".txt"), args);
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

    Remove-Item -LiteralPath (Join-Path $logDir '*.txt') -Force
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

Write-Host 'GPU quality mapping, command arguments, PowerShell syntax and BATs: OK'
