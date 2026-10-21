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
    $realSearch=Invoke-HybridQualitySearch -Entries $realEntries -Encoder 'unused.exe' -CpuEncoder 'unused.exe' -GpuWorkers 12 -CpuWorkers 4 -ScratchDir (Join-Path $temp 'real-search') -VolumeName 'real-search' -SampleLimitBytes 68MB -ScriptRoot (Join-Path $repo 'scripts') -EncoderTimeoutSeconds 5
    if($realSearch.GpuChoice.Quality -ne 93 -or $realSearch.CpuChoice.Quality -ne 93) { throw 'Real binary-search quality decisions changed' }
    if($realSearch.GpuChoice.Probes.Count -ne 5 -or $realSearch.CpuChoice.Probes.Count -ne 5 -or @($realSearch.Passes).Count -ne 10){throw 'Real quality probe count or metrics changed'}
    foreach($cached in $realSearch.GpuChoice.Probe.Cache){ if($cached.EncodedBy -ne 'Gpu' -or $cached.Path -notmatch 'sample_q'){throw 'GPU sample cache is corrupt'} }
    foreach($cached in $realSearch.CpuChoice.Probe.Cache){ if($cached.EncodedBy -ne 'Cpu' -or $cached.Path -notmatch 'cpu_sample_q'){throw 'CPU sample cache is corrupt'} }
    if(@($realEntries | Where-Object {$_.SourcePath -notmatch '^original_'}).Count -gt 0){throw 'Real search modified input entries'}
    Write-Host 'PASS: concurrent probes, real quality binary search, cache isolation, metrics, cancellation and entry safety'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
