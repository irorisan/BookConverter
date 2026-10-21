#requires -Version 7.6
$ErrorActionPreference = 'Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repo 'scripts/Hybrid-QualityParallel.ps1')

# Dependency-free quality-search test: no mock encoder executable.
function Test-AvifOutput { param([string]$Path) }
function Invoke-ParallelAvif { param() }
function Get-AvifSampleEstimate { param() }
function Find-AvifQuality {
    param($Entries,[string]$Encoder,[string]$Decoder,[int]$Workers,
        [string]$ScratchDir,[string]$VolumeName,[long]$SampleLimitBytes,
        [switch]$CpuProbe)
    $backend=if($CpuProbe){'Cpu'}else{'Gpu'}
    [IO.Directory]::CreateDirectory($ScratchDir) | Out-Null
    [IO.File]::WriteAllText((Join-Path $ScratchDir ($backend+'-started')),
        [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString())
    $duration=if($VolumeName -match 'cancel-test' -and -not $CpuProbe){4000}else{1400}
    if($VolumeName -match 'cancel-test' -and $CpuProbe){throw 'Deliberate CPU search failure'}
    $elapsed=[Diagnostics.Stopwatch]::StartNew()
    while($elapsed.ElapsedMilliseconds -lt $duration){
        if($CancelFile -and (Test-Path -LiteralPath $CancelFile)){throw 'Other probe cancelled'}
        Start-Sleep -Milliseconds 40
    }
    $q=if($CpuProbe){71}else{83}
    $script:EncodePasses.Add([pscustomobject]@{Phase='Sample';Backend=$backend;GpuPages=$(if($CpuProbe){0}else{12});CpuPages=$(if($CpuProbe){12}else{0})})
    return [pscustomobject]@{
        Quality=$q
        EstimatedBytes=[long](45MB)
        Probe=[pscustomobject]@{Quality=$q;Cache=@()}
        Probes=@([pscustomobject]@{Quality=$q;EstimatedBytes=[long](45MB)})
    }
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ConcurrentQuality_'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
    $entries=[System.Collections.Generic.List[object]]::new()
    $entries.Add([pscustomobject]@{SourcePath='source.png';NeedsConversion=$true;Length=123L})
    $before=[Diagnostics.Stopwatch]::StartNew()
    $result=Invoke-HybridQualitySearch -Entries $entries -Encoder 'unused.exe' -CpuEncoder 'unused.exe' -GpuWorkers 12 -CpuWorkers 4 -ScratchDir $temp -VolumeName 'test' -SampleLimitBytes 68MB -ScriptRoot (Join-Path $repo 'scripts') -EncoderTimeoutSeconds 5
    $before.Stop()
    if($result.GpuChoice.Quality -ne 83 -or $result.CpuChoice.Quality -ne 71) {throw 'Wrong independent qualities'}
    if(@($result.Passes).Count -ne 2 -or @($result.Passes | Where-Object {$_.Backend -eq 'Gpu'}).Count -ne 1 -or @($result.Passes | Where-Object {$_.Backend -eq 'Cpu'}).Count -ne 1){throw 'Probe metrics were lost'}
    $g=[long][IO.File]::ReadAllText((Join-Path $temp 'Gpu-started'))
    $c=[long][IO.File]::ReadAllText((Join-Path $temp 'Cpu-started'))
    if([Math]::Abs($g-$c) -ge 1000){throw 'GPU and CPU probes did not start concurrently'}
    if($before.Elapsed.TotalSeconds -ge 3.5){throw 'Quality search took as long as serial execution'}
    if($entries[0].SourcePath -ne 'source.png'){throw 'Original entry was modified'}

    $failed=$false
    $cancelDir=Join-Path $temp 'cancel'
    try {
        Invoke-HybridQualitySearch -Entries $entries -Encoder 'unused.exe' -CpuEncoder 'unused.exe' -GpuWorkers 12 -CpuWorkers 4 -ScratchDir $cancelDir -VolumeName 'cancel-test' -SampleLimitBytes 68MB -ScriptRoot (Join-Path $repo 'scripts') -EncoderTimeoutSeconds 5 | Out-Null
    } catch {
        if($_.Exception.Message -notmatch 'CPU|Deliberate|failed'){throw}
        $failed=$true
    }
    if(-not $failed){throw 'CPU job failure was swallowed'}
    if(Test-Path -LiteralPath (Join-Path $cancelDir '.quality-probe-cancel')){throw 'Cancellation marker was not cleaned'}
    Write-Host 'PASS: independent concurrent quality probes, results, metrics, cancellation and entry safety'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
