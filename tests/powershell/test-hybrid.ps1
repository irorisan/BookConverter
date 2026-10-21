$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repo 'scripts/GPU-Functions.ps1')
. (Join-Path $repo 'scripts/Hybrid-Functions.ps1')
function Test-AvifOutput { param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw 'Missing output' }
    if ((Get-Item -LiteralPath $Path).Length -ne 16) { throw 'Bad mock output' }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('HybridTest_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $exe = Join-Path $temp 'mock.exe'
    if ($env:BOOKCONV_MOCK_EXE) { $exe = $env:BOOKCONV_MOCK_EXE }
    else {
        Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public class HybridMock {
 public static int Main(string[] args) {
  string dest = args[args.Length-1];
  bool gpu = Array.IndexOf(args, "av1_nvenc") >= 0;
  string fail = Environment.GetEnvironmentVariable("HYBRID_FAIL");
  if (fail == "all" || (gpu && fail == "gpu")) return 9;
  if (fail == "retry" && !gpu && !File.Exists(dest + ".retry")) {
   File.WriteAllText(dest + ".retry", "1"); return 8;
  }
  if (fail == "cancel") File.WriteAllText(Environment.GetEnvironmentVariable("HYBRID_CANCEL"), "1");
  Thread.Sleep(fail == "timeout" ? 5000 : (gpu ? 80 : 150));
  File.WriteAllBytes(dest, new byte[16]); return 0;
 }
}
'@
    }
    function New-Entries([int]$Count) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($i in 1..$Count) {
            $src = Join-Path $temp ('src{0}.png' -f $i)
            [IO.File]::WriteAllBytes($src, [byte[]]@(1,2,3))
            $list.Add([pscustomobject]@{SourcePath=$src; EntryName=('{0:D4}.avif' -f $i); Extension='.png'; Length=3L; NeedsConversion=$true})
        }
        return ,$list
    }
    $entries = New-Entries 250
    $original = @($entries | ForEach-Object { $_.SourcePath })
    $stats = Invoke-HybridEncode -Entries $entries.ToArray() -FFmpeg $exe -Avifenc $exe -GpuQuality 75 -CpuQuality 80 -GpuWorkers 12 -CpuWorkers 4 -TempDir (Join-Path $temp 'out')
    if ($stats.GpuPages + $stats.CpuPages -ne 250 -or $stats.CpuPages -le 0) { throw 'Lost pages or no CPU work' }
    if ($stats.PeakGpu -ne 12 -or $stats.PeakCpu -ne 4 -or $stats.PeakTotal -ne 16) { throw 'Incorrect concurrency' }
    if (@($entries.SourcePath | Select-Object -Unique).Count -ne 250) { throw 'Duplicate outputs' }
    for ($i=0; $i -lt 250; $i++) {
        if ($entries[$i].EntryName -ne ('{0:D4}.avif' -f ($i+1))) { throw 'Order changed' }
        Test-AvifOutput $entries[$i].SourcePath
        if ((Get-Item -LiteralPath $original[$i]).Length -ne 3) { throw 'Source modified' }
    }
    $env:HYBRID_FAIL = 'gpu'
    $stats = Invoke-HybridEncode -Entries (New-Entries 20).ToArray() -FFmpeg $exe -Avifenc $exe -GpuQuality 75 -CpuQuality 80 -GpuWorkers 12 -CpuWorkers 4 -TempDir (Join-Path $temp 'fallback')
    if ($stats.CpuPages -ne 20 -or $stats.Errors -le 0 -or $stats.Retries -le 0) { throw 'No GPU fallback' }
    $env:HYBRID_FAIL = 'retry'
    $stats = Invoke-HybridEncode -Entries (New-Entries 4).ToArray() -FFmpeg $exe -Avifenc $exe -GpuQuality 75 -CpuQuality 80 -GpuWorkers 0 -CpuWorkers 4 -TempDir (Join-Path $temp 'retry')
    if ($stats.Retries -ne 4 -or $stats.CpuPages -ne 4) { throw 'CPU retry failed' }
    foreach ($scenario in @('all','cancel','timeout')) {
        $env:HYBRID_FAIL = $scenario
        $cancel = Join-Path $temp 'cancel.flag'
        $env:HYBRID_CANCEL = $cancel
        $dir = Join-Path $temp $scenario
        $caught = $false
        try {
            Invoke-HybridEncode -Entries (New-Entries 20).ToArray() -FFmpeg $exe -Avifenc $exe -GpuQuality 75 -CpuQuality 80 -GpuWorkers 12 -CpuWorkers 4 -TempDir $dir -CancelFile $cancel -TimeoutSeconds 1 | Out-Null
        } catch { $caught = $true }
        if (-not $caught) { throw "Did not reject $scenario" }
        if (Test-Path -LiteralPath $dir) { throw "Failed work not cleaned: $scenario" }
        Remove-Item -LiteralPath $cancel -ErrorAction SilentlyContinue
    }
    Remove-Item Env:HYBRID_FAIL -ErrorAction SilentlyContinue
    $stats = Invoke-HybridEncode -Entries (New-Entries 30).ToArray() -FFmpeg $exe -Avifenc $exe -GpuQuality 75 -CpuQuality 80 -GpuWorkers 12 -CpuWorkers 0 -TempDir (Join-Path $temp 'gpu')
    if ($stats.GpuPages -ne 30 -or $stats.CpuPages -ne 0 -or $stats.PeakGpu -gt 12) { throw 'GPU regression' }
    Write-Host 'PASS: 250 pages, limits, overlap, order, fallback, retries, cancellation, timeout, GPU mode'
} finally {
    Remove-Item Env:HYBRID_FAIL -ErrorAction SilentlyContinue
    Remove-Item Env:HYBRID_CANCEL -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
