#requires -Version 7.6
$ErrorActionPreference = 'Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repo 'scripts/Hybrid-QualityParallel.ps1')
. (Join-Path $repo 'scripts/Convert-Manga-Progress.ps1')
$script:taskProgress=[System.Collections.Generic.List[object]]::new()
function Write-Progress {
    param([int]$Id,[int]$ParentId,[string]$Activity,[string]$Status,[int]$PercentComplete,[switch]$Completed)
    $script:taskProgress.Add([pscustomobject]@{Id=$Id;ParentId=$ParentId;Activity=$Activity;
        Status=$Status;PercentComplete=$PercentComplete;Done=[bool]$Completed})
}

# Interactive and argument-based probe selection are independent of full-pass CPU workers.
$script:answers=[System.Collections.Generic.Queue[string]]::new()
function Read-MangaResponse {
    param([string]$Prompt)
    if($script:answers.Count -eq 0){return $null}
    return $script:answers.Dequeue()
}
if((Select-CpuProbeWorkers -Requested 0 -Interactive) -ne 0){throw 'Explicit zero must disable CPU probing'}
if((Select-CpuProbeWorkers -Requested 8 -Interactive) -ne 8){throw 'Explicit eight must be permitted'}
if((Select-CpuProbeWorkers -Interactive:$false) -ne 4){throw 'Noninteractive default must be four'}
$script:answers.Enqueue('bad')
$script:answers.Enqueue('9')
$script:answers.Enqueue('-1')
$script:answers.Enqueue('8')
if((Select-CpuProbeWorkers -Interactive) -ne 8){throw 'Interactive validation and eight selection failed'}
$script:answers.Enqueue('')
if((Select-CpuProbeWorkers -Interactive) -ne 4){throw 'Interactive Enter default failed'}
$script:answers.Enqueue('0')
if((Select-CpuProbeWorkers -Interactive) -ne 0){throw 'Interactive zero selection failed'}
if($null -ne (Select-CpuProbeWorkers -Interactive)){throw 'Interactive EOF must abort safely'}


# Dependency-free quality-search test: no mock encoder executable.
function Test-AvifOutput { param([string]$Path) }
function Invoke-ParallelAvif { param() }
function Get-AvifSampleEstimate { param() }
function Find-AvifQuality {
    param($Entries,[string]$Encoder,[string]$Decoder,[int]$Workers,
        [string]$ScratchDir,[string]$VolumeName,[long]$SampleLimitBytes,
        [switch]$CpuProbe,
        [System.Collections.Concurrent.ConcurrentDictionary[string,int]]$ProgressState,
        [string]$ProgressBackend)
    $backend=if($CpuProbe){'Cpu'}else{'Gpu'}
    [IO.Directory]::CreateDirectory($ScratchDir) | Out-Null
    [IO.File]::WriteAllText((Join-Path $ScratchDir ($backend+'-started')),
        [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString())
    [IO.File]::WriteAllText((Join-Path $ScratchDir ($backend+'-workers')), [string]$Workers)
    $duration=if($VolumeName -match 'cancel-test' -and -not $CpuProbe){4000}else{1400}
    if($VolumeName -match 'cancel-test' -and $CpuProbe){throw 'Deliberate CPU search failure'}
    $elapsed=[Diagnostics.Stopwatch]::StartNew()
    while($elapsed.ElapsedMilliseconds -lt $duration){
        if($CancelFile -and (Test-Path -LiteralPath $CancelFile)){throw 'Other probe cancelled'}
        Start-Sleep -Milliseconds 40
    }
    if($null -ne $ProgressState){$ProgressState[$ProgressBackend]=1}
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
    $result=Invoke-HybridQualitySearch -Entries $entries -Encoder 'unused.exe' -CpuEncoder 'unused.exe' -GpuWorkers 12 -CpuProbeWorkers 4 -ScratchDir $temp -VolumeName 'test' -SampleLimitBytes 68MB -ScriptRoot (Join-Path $repo 'scripts') -EncoderTimeoutSeconds 5
    $before.Stop()
    if($result.GpuChoice.Quality -ne 83 -or $result.CpuChoice.Quality -ne 71) {throw 'Wrong independent qualities'}
    if(@($result.Passes).Count -ne 2 -or @($result.Passes | Where-Object {$_.Backend -eq 'Gpu'}).Count -ne 1 -or @($result.Passes | Where-Object {$_.Backend -eq 'Cpu'}).Count -ne 1){throw 'Probe metrics were lost'}
    $g=[long][IO.File]::ReadAllText((Join-Path $temp 'Gpu-started'))
    $c=[long][IO.File]::ReadAllText((Join-Path $temp 'Cpu-started'))
    if([Math]::Abs($g-$c) -ge 1000){throw 'GPU and CPU probes did not start concurrently'}
    if($before.Elapsed.TotalSeconds -ge 3.5){throw 'Quality search took as long as serial execution'}
    if($entries[0].SourcePath -ne 'source.png'){throw 'Original entry was modified'}
    $qualityTicks=@($script:taskProgress | Where-Object {$_.Id -eq 2 -and
        $_.Status -match 'GPU.*CPU' -and $_.PercentComplete -gt 0})
    if($qualityTicks.Count -lt 1){throw 'Parent process did not render completed concurrent quality probes'}
    if(@($script:taskProgress | Where-Object {$_.Id -eq 2 -and $_.Done}).Count -lt 1){
        throw 'Concurrent quality progress must be cleared at end'
    }
    foreach($n in @(0,8)){
        $probeDir=Join-Path $temp ('workers-'+$n)
        $probe=Invoke-HybridQualitySearch -Entries $entries -Encoder 'unused.exe' -CpuEncoder 'unused.exe' -GpuWorkers 12 -CpuProbeWorkers $n -ScratchDir $probeDir -VolumeName ('workers-'+$n) -SampleLimitBytes 68MB -ScriptRoot (Join-Path $repo 'scripts') -EncoderTimeoutSeconds 5
        if($probe.GpuChoice.Quality -ne 83){throw "GPU quality missing for probe workers $n"}
        if($n -eq 0){
            if($null -ne $probe.CpuChoice -or @($probe.Passes).Count -ne 1 -or (Test-Path -LiteralPath (Join-Path $probeDir 'Cpu-started'))){throw 'Zero must omit CPU exploration completely'}
        }
        else {
            if($probe.CpuChoice.Quality -ne 71 -or @($probe.Passes).Count -ne 2){throw 'Eight must preserve CPU quality exploration'}
            if((Get-Content -LiteralPath (Join-Path $probeDir 'Cpu-workers') -Raw) -ne '8'){throw 'CPU probe worker count not propagated'}
        }
    }


    $failed=$false
    $cancelDir=Join-Path $temp 'cancel'
    try {
        Invoke-HybridQualitySearch -Entries $entries -Encoder 'unused.exe' -CpuEncoder 'unused.exe' -GpuWorkers 12 -CpuProbeWorkers 4 -ScratchDir $cancelDir -VolumeName 'cancel-test' -SampleLimitBytes 68MB -ScriptRoot (Join-Path $repo 'scripts') -EncoderTimeoutSeconds 5 | Out-Null
    } catch {
        if($_.Exception.Message -notmatch 'CPU|Deliberate|failed'){throw}
        $failed=$true
    }
    if(-not $failed){throw 'CPU job failure was swallowed'}
    if(Test-Path -LiteralPath (Join-Path $cancelDir '.quality-probe-cancel')){throw 'Cancellation marker was not cleaned'}
    # Run the actual size-estimation and binary-search functions with a pure
    # PowerShell sample encoder, verifying cache isolation and unchanged probes.
    $parseTokens=$null; $parseErrors=$null
    $sourceAst=[Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repo 'scripts/Convert-Manga.ps1'),[ref]$parseTokens,[ref]$parseErrors)
    if($parseErrors){throw $parseErrors[0]}
    foreach($name in @('Get-AvifSampleEstimate','Find-AvifQuality')){
        $node=$sourceAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        if(-not $node){throw "Missing production function: $name"}
        . ([scriptblock]::Create($node.Extent.Text))
    }
    function Invoke-ParallelAvif {
        param([System.Collections.Generic.List[object]]$Entries,[string]$Encoder,
            [string]$Decoder,[int]$Quality,[int]$Workers,[string]$TempDir,
            [string]$OutputName,[switch]$CpuProbe)
        [IO.Directory]::CreateDirectory($TempDir) | Out-Null
        $backend=if($CpuProbe){'Cpu'}else{'Gpu'}
        for($i=0;$i -lt $Entries.Count;$i++){
            $bytes=[byte[]]::new($(if($CpuProbe){2000+$Quality}else{1000+$Quality}))
            $path=Join-Path $TempDir ('probe_{0:D2}.avif' -f $i)
            [IO.File]::WriteAllBytes($path,$bytes)
            $Entries[$i].SourcePath=$path
            $Entries[$i].Length=[long]$bytes.Length
            $Entries[$i] | Add-Member -NotePropertyName EncodedBy -NotePropertyValue $backend -Force
        }
        $script:EncodePasses.Add([pscustomobject]@{Phase='Sample';Backend=$backend;GpuPages=$(if($CpuProbe){0}else{12});CpuPages=$(if($CpuProbe){12}else{0})})
        return $Entries.Count
    }
    $realEntries=[System.Collections.Generic.List[object]]::new()
    foreach($i in 1..40){
        $realEntries.Add([pscustomobject]@{
            SourcePath=('original_{0:D2}.png' -f $i)
            EntryName=('volume_{0:D2}.avif' -f $i)
            Length=100L
            NeedsConversion=$true
            Extension='.png'
        })
    }
    $realSearch=Invoke-HybridQualitySearch -Entries $realEntries -Encoder 'unused.exe' -CpuEncoder 'unused.exe' -GpuWorkers 12 -CpuProbeWorkers 4 -ScratchDir (Join-Path $temp 'real-search') -VolumeName 'real-search' -SampleLimitBytes 68MB -ScriptRoot (Join-Path $repo 'scripts') -EncoderTimeoutSeconds 5
    if($realSearch.GpuChoice.Quality -ne 93 -or $realSearch.CpuChoice.Quality -ne 93) { throw 'Real binary-search quality decisions changed' }
    if($realSearch.GpuChoice.Probes.Count -ne 5 -or $realSearch.CpuChoice.Probes.Count -ne 5 -or @($realSearch.Passes).Count -ne 10){throw 'Real quality probe count or metrics changed'}
    foreach($cached in $realSearch.GpuChoice.Probe.Cache){ if($cached.EncodedBy -ne 'Gpu' -or $cached.Path -notmatch 'sample_q'){throw 'GPU sample cache is corrupt'} }
    foreach($cached in $realSearch.CpuChoice.Probe.Cache){ if($cached.EncodedBy -ne 'Cpu' -or $cached.Path -notmatch 'cpu_sample_q'){throw 'CPU sample cache is corrupt'} }
    if(@($realEntries | Where-Object {$_.SourcePath -notmatch '^original_'}).Count -gt 0){throw 'Real search modified input entries'}
    Write-Host 'PASS: concurrent probes, real quality binary search, cache isolation, metrics, cancellation and entry safety'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
