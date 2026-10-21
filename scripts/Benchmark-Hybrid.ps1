#requires -Version 7.6
param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$ResultsDirectory,
    [ValidateRange(3,20)][int]$Repeats=3
)
$ErrorActionPreference='Stop'
if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -ne 7 -or $PSVersionTable.PSVersion.Minor -ne 6) {
    throw 'BookConverter requires PowerShell 7.6.x on Windows (pwsh.exe).'
}
$source=Get-Item -LiteralPath $InputPath
if ($source.PSIsContainer) { throw 'Benchmark requires one archive file (same immutable bytes for every run)' }
if ($source.Length -le 60MB) { throw 'Input must exceed 60MiB to measure encoding' }
if (Test-Path -LiteralPath $ResultsDirectory) { throw 'Results directory must be new' }
New-Item -ItemType Directory -Path $ResultsDirectory | Out-Null
$ResultsDirectory=(Resolve-Path -LiteralPath $ResultsDirectory).Path
$hash=(Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
$scriptPath=Join-Path $PSScriptRoot 'Convert-Manga.ps1'
. (Join-Path $PSScriptRoot 'GPU-Functions.ps1')
$ffmpeg=Find-FFmpegNvenc
$avifenc=Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/avifenc.exe'
if (-not (Test-Path -LiteralPath $avifenc)) { $avifenc=Join-Path (Split-Path -Parent $PSScriptRoot) 'avifenc.exe' }
if (-not (Test-Path -LiteralPath $avifenc)) {
    $cmd=Get-Command avifenc.exe -ErrorAction Stop
    $avifenc=$cmd.Source
}
$metadata=[ordered]@{Input=$source.FullName; SHA256=$hash; Repeats=$Repeats;
    PowerShell=$PSVersionTable.PSVersion.ToString(); FFmpeg=$ffmpeg; Avifenc=$avifenc;
    FFmpegVersion=(& $ffmpeg -version 2>&1 | Out-String);
    AvifencVersion=(& $avifenc --version 2>&1 | Out-String);
    GPU=(& nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv 2>&1 | Out-String)}
$metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'environment.json') -Encoding UTF8
$rows=[System.Collections.Generic.List[object]]::new()
for ($round=1; $round -le $Repeats; $round++) {
    # Alternate order to reduce systematic cache/thermal bias. No warmup excluded silently.
    $modes=if ($round % 2) { @('GPU','Hybrid') } else { @('Hybrid','GPU') }
    foreach ($mode in $modes) {
        $runDir=Join-Path $ResultsDirectory ("$round-$mode")
        New-Item -ItemType Directory -Path $runDir | Out-Null
        $copy=Join-Path $runDir $source.Name
        Copy-Item -LiteralPath $source.FullName -Destination $copy
        if ((Get-FileHash -LiteralPath $copy).Hash -ne $hash) { throw 'Input copy hash mismatch' }
        $metrics=Join-Path $runDir 'metrics'
        # Magazine mode removes title prompts; configured modes remove worker prompts.
        # EOF ends the normal continuous-input loop after one volume.
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=Join-Path $PSHOME 'pwsh.exe'
        $psi.Arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Magazine -ConversionMode {1} -GpuWorkers 12 -CpuWorkers 4 -ReportDirectory "{2}" "{3}"' -f $scriptPath,$mode,$metrics,$copy
        $psi.UseShellExecute=$false; $psi.RedirectStandardInput=$true
        $p=New-Object Diagnostics.Process; $p.StartInfo=$psi
        try {
            [void]$p.Start(); $p.StandardInput.Close(); $p.WaitForExit()
            if ($p.ExitCode -ne 0) { throw 'Converter process failed' }
        } finally { $p.Dispose() }
        $files=@(Get-ChildItem -LiteralPath $metrics -Filter '*.json')
        if ($files.Count -ne 1) { throw 'Expected one volume report' }
        $report=Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
        if ($report.Status -ne 'Success' -or $report.FinalBytes -gt 70MB) { throw 'Invalid or oversized benchmark result' }
        if (@($report.Passes | Where-Object { $_.Errors -gt 0 }).Count) { throw 'Fallback/retry run cannot be a clean performance comparison' }
        $rows.Add([pscustomobject]@{Round=$round; Mode=$mode; Seconds=$report.TotalSeconds;
            Bytes=$report.FinalBytes; GpuQuality=$report.GpuQuality; CpuQuality=$report.CpuQuality})
        $rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'runs.json') -Encoding UTF8
        # Keep all final CBZs and reports reviewable; remove only the benchmark's input copy.
        Remove-Item -LiteralPath $copy
    }
}
if ((Get-FileHash -LiteralPath $source.FullName).Hash -ne $hash) { throw 'Original input changed' }
$medians=@{}
foreach ($mode in @('GPU','Hybrid')) {
    $group=@($rows | Where-Object { $_.Mode -eq $mode })
    if (@($group.GpuQuality | Select-Object -Unique).Count -ne 1 -or
        ($mode -eq 'Hybrid' -and @($group.CpuQuality | Select-Object -Unique).Count -ne 1)) {
        throw 'Quality settings varied between repeats; review runs individually'
    }
    $times=@($group.Seconds | Sort-Object)
    $n=$times.Count
    $median=if ($n % 2) { $times[[int][Math]::Floor($n/2)] } else { ($times[$n/2-1]+$times[$n/2])/2 }
    $medians[$mode]=$median
    Write-Host ("{0}: median {1:N3}s ({2} runs)" -f $mode,$median,$n)
}
if (@($rows.GpuQuality | Select-Object -Unique).Count -ne 1) { throw 'GPU quality differs across modes; not a matched comparison' }
Write-Host ('Hybrid wall-time change: {0:N2}%' -f (100*($medians.Hybrid/$medians.GPU-1)))
Write-Host 'Quality equivalence requires decoded representative-page review. No default change is made.'
