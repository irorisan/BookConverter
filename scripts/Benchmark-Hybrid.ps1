#requires -Version 7.6
param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$ResultsDirectory,
    [ValidateRange(3,20)][int]$Repeats=3,
    [ValidateRange(0,8)][int]$CpuProbeWorkers=0
)
$ErrorActionPreference='Stop'
if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -ne 7 -or $PSVersionTable.PSVersion.Minor -ne 6) {
    throw 'BookConverter requires PowerShell 7.6.x on Windows (pwsh.exe).'
}
$source=Get-Item -LiteralPath $InputPath
if($source.PSIsContainer){throw 'Benchmark requires one archive file'}
if($source.Length -le 60MB){throw 'Input must exceed 60MiB to measure encoding'}
if(Test-Path -LiteralPath $ResultsDirectory){throw 'Results directory must be new'}
[void](New-Item -ItemType Directory -Path $ResultsDirectory)
$ResultsDirectory=(Resolve-Path -LiteralPath $ResultsDirectory).Path
$hash=(Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
$scriptPath=Join-Path $PSScriptRoot 'Convert-Manga.ps1'
. (Join-Path $PSScriptRoot 'GPU-Functions.ps1')
$ffmpeg=Find-FFmpegNvenc
$avifenc=Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/avifenc.exe'
if(-not (Test-Path -LiteralPath $avifenc)){$avifenc=Join-Path (Split-Path -Parent $PSScriptRoot) 'avifenc.exe'}
if(-not (Test-Path -LiteralPath $avifenc)){$avifenc=(Get-Command avifenc.exe -ErrorAction Stop).Source}
$metadata=[ordered]@{Input=$source.FullName; SHA256=$hash; Repeats=$Repeats; CpuProbeWorkers=$CpuProbeWorkers;
    PowerShell=$PSVersionTable.PSVersion.ToString(); FFmpeg=$ffmpeg; Avifenc=$avifenc;
    FFmpegVersion=(& $ffmpeg -version 2>&1 | Out-String);
    AvifencVersion=(& $avifenc --version 2>&1 | Out-String);
    GPU=(& nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv 2>&1 | Out-String)}
$metadata|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $ResultsDirectory 'environment.json') -Encoding UTF8
$rows=[System.Collections.Generic.List[object]]::new()
for($round=1;$round -le $Repeats;$round++){
    $runDir=Join-Path $ResultsDirectory ("$round-Hybrid")
    [void](New-Item -ItemType Directory -Path $runDir)
    $copy=Join-Path $runDir $source.Name
    Copy-Item -LiteralPath $source.FullName -Destination $copy
    if((Get-FileHash -LiteralPath $copy).Hash -ne $hash){throw 'Input copy hash mismatch'}
    $metrics=Join-Path $runDir 'metrics'
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=Join-Path $PSHOME 'pwsh.exe'
    foreach($arg in @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,
        '-Magazine','-GpuWorkers','12','-CpuWorkers','4','-CpuProbeWorkers',[string]$CpuProbeWorkers,
        '-ReportDirectory',$metrics,$copy)){[void]$psi.ArgumentList.Add($arg)}
    $psi.UseShellExecute=$false
    $psi.RedirectStandardInput=$true
    $proc=[Diagnostics.Process]::new()
    $proc.StartInfo=$psi
    try {
        [void]$proc.Start()
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        if($proc.ExitCode -ne 0){throw "Hybrid converter process failed in round $round"}
    } finally {$proc.Dispose()}
    $files=@(Get-ChildItem -LiteralPath $metrics -Filter '*.json')
    if($files.Count -ne 1){throw 'Expected one volume report'}
    $report=Get-Content -LiteralPath $files[0].FullName -Raw|ConvertFrom-Json
    if($report.Status -ne 'Success' -or $report.FinalBytes -gt 70MB){throw 'Invalid or oversized benchmark result'}
    if(@($report.Passes|Where-Object {$_.Errors -gt 0}).Count){throw 'Errors prevent clean speed comparison'}
    $rows.Add([pscustomobject]@{Round=$round;Mode='Hybrid';Seconds=$report.TotalSeconds;
        Bytes=$report.FinalBytes;GpuQuality=$report.GpuQuality;CpuQuality=$report.CpuQuality;
        CpuProbeWorkers=$report.CpuProbeWorkers;ProbeSeconds=$report.Stages.'品質探索'})
    $rows|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $ResultsDirectory 'runs.json') -Encoding UTF8
    Remove-Item -LiteralPath $copy
}
if((Get-FileHash -LiteralPath $source.FullName).Hash -ne $hash){throw 'Original input changed'}
$times=@($rows.Seconds|Sort-Object)
$median=if($times.Count % 2){$times[[int][Math]::Floor($times.Count/2)]}else{
    ($times[$times.Count/2-1]+$times[$times.Count/2])/2
}
Write-Host ("Hybrid median {0:N3}s ({1} runs, CPU probe {2})" -f $median,$times.Count,$CpuProbeWorkers)
Write-Host 'Inspect quality and output size before comparing against other probe settings.'
