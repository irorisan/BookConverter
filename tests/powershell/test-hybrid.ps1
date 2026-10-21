$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repo 'scripts/GPU-Functions.ps1')
. (Join-Path $repo 'scripts/Hybrid-Functions.ps1')
function Test-AvifOutput { param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw 'Missing output' }
    if ((Get-Item -LiteralPath $Path).Length -lt 16) { throw 'Bad mock output' }
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
  File.WriteAllBytes(dest, new byte[16]);
  if (Environment.GetEnvironmentVariable("HYBRID_BIG") == "1") {
   using (var stream = new FileStream(dest, FileMode.Open)) stream.SetLength(21*1024*1024);
  }
  return 0;
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
    $stats = Invoke-HybridEncode -Entries (New-Entries 8).ToArray() -FFmpeg (Join-Path $temp 'missing.exe') -Avifenc $exe -GpuQuality 75 -CpuQuality 95 -GpuWorkers 12 -CpuWorkers 0 -TempDir (Join-Path $temp 'launch-fallback')
    if ($stats.CpuPages -ne 8 -or $stats.PeakCpu -ne 1 -or $stats.Errors -ne 8) { throw 'GPU launch fallback must respect one CPU slot in GPU mode' }
    Remove-Item Env:HYBRID_FAIL -ErrorAction SilentlyContinue
    $webp=New-Entries 40
    foreach ($entry in $webp) { $entry.Extension='.webp' }
    $stats = Invoke-HybridEncode -Entries $webp.ToArray() -FFmpeg $exe -Avifenc $exe -Decoder $exe -GpuQuality 75 -CpuQuality 80 -GpuWorkers 12 -CpuWorkers 4 -TempDir (Join-Path $temp 'webp')
    if ($stats.GpuPages+$stats.CpuPages -ne 40 -or $stats.PeakTotal -gt 16) { throw 'WebP slot handoff failed' }
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
    # Exercise the real quality search/full-conversion connection, cache reuse,
    # ordered ZIP Store writer and hard size rejection with process mocks.
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/Convert-Manga.ps1'),[ref]$tokens,[ref]$errors)
    if ($errors) { throw $errors[0] }
    foreach ($name in @('Invoke-ParallelAvif','Get-AvifSampleEstimate','Find-AvifQuality','Copy-VolumeEntries','Invoke-AutoSizeAvif')) {
        $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        . ([scriptblock]::Create($node.Extent.Text))
    }
    . (Join-Path $repo 'scripts/Convert-Manga-Progress.ps1')
    . (Join-Path $repo 'scripts/Convert-Manga-Zip.ps1')
    $script:SampleDecodeCalls=0
    function Invoke-GpuVerifyAvifBatch { param([string[]]$Paths,[string]$FFmpeg,[int]$Workers,[string]$CancelFile,[int]$TimeoutSeconds)
        $script:SampleDecodeCalls++
        foreach ($path in $Paths) { Test-AvifOutput $path }
    }
    $ConversionMode='Hybrid'; $GpuWorkers=12; $CpuWorkers=4
    $script:CpuEncoder=$exe; $script:HybridCpuQuality=95
    $EncoderTimeoutSeconds=30; $CancelFile=$null
    $script:EncodePasses=[System.Collections.Generic.List[object]]::new()
    $book=Invoke-AutoSizeAvif -Entries (New-Entries 40) -Encoder $exe -Workers 12 -ScratchDir (Join-Path $temp 'auto') -OutputName 'test' -MaxTargetBytes 70MB -SampleSafetyBytes 2MB
    if (-not $book.UnderLimit -or $book.Entries.Count -ne 40) { throw 'Quality pipeline failed' }
    $samplePasses=@($script:EncodePasses | Where-Object { $_.Phase -eq 'Sample' })
    if (-not @($samplePasses | Where-Object { $_.GpuPages -gt 0 }).Count -or
        -not @($samplePasses | Where-Object { $_.CpuPages -gt 0 }).Count) { throw 'Missing GPU or CPU quality probes' }
    if ($script:SampleDecodeCalls -ne 0) { throw 'Quality search must defer full AVIF decoding to final validation' }
    $batchNode=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-MangaBatch'},$true)
    $finalVerify=@($batchNode.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-GpuVerifyAvifBatch'},$true))
    if ($finalVerify.Count -eq 0) { throw 'Final per-volume AVIF decode validation must be retained' }
    if (@($script:EncodePasses | Where-Object { $_.Phase -eq 'Full' -and $_.CpuPages -gt 0 }).Count -ne 1) { throw 'Hybrid full conversion was not selected' }
    $zip=Join-Path $temp 'output.cbz'
    Write-MangaStoredZip -Path $zip -Entries $book.Entries
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($zip)
    try {
        if ($archive.Entries.Count -ne 40) { throw 'Missing ZIP pages' }
        for ($i=0; $i -lt 40; $i++) {
            if ($archive.Entries[$i].FullName -cne $book.Entries[$i].EntryName -or $archive.Entries[$i].Length -ne 16) { throw 'Invalid ZIP order or size' }
        }
    } finally { $archive.Dispose() }
    $env:HYBRID_BIG='1'
    $caught=$false
    try {
        Invoke-AutoSizeAvif -Entries (New-Entries 4) -Encoder $exe -Workers 12 -ScratchDir (Join-Path $temp 'oversized') -OutputName 'big' -MaxTargetBytes 70MB -SampleSafetyBytes 2MB | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch 'exceeded 70MiB') { throw }
        $caught=$true
    }
    if (-not $caught) { throw 'Oversized conversion accepted' }
    Write-Host 'PASS: 250 pages, limits, overlap, order, fallback, retries, cancellation, timeout, GPU, sample decode deferred, final decode retained, quality pipeline, CBZ, 70MiB rejection'
} finally {
    Remove-Item Env:HYBRID_FAIL -ErrorAction SilentlyContinue
    Remove-Item Env:HYBRID_CANCEL -ErrorAction SilentlyContinue
    Remove-Item Env:HYBRID_BIG -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
