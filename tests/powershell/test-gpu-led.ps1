#requires -Version 7.6
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $root 'scripts/Hybrid-GpuLed.ps1')

# No third-party encoders: keep per-page identity and observe what gets encoded.
$script:fakeCalls=[System.Collections.Generic.List[object]]::new()
$script:scenario='normal'
$script:HybridCpuQuality=95
function Write-MangaStage {param([string]$Name,[string]$Stage)}
$script:probeProgress=[System.Collections.Generic.List[object]]::new()
function Write-MangaPageProgress {
    param([int]$Completed,[int]$Total,[string]$Activity,[string]$Unit,[switch]$Done)
    $script:probeProgress.Add([pscustomobject]@{Completed=$Completed;Total=$Total;Activity=$Activity;Unit=$Unit;Done=[bool]$Done})
}
function Copy-VolumeEntries {
    param([System.Collections.Generic.List[object]]$Entries)
    $copies=[System.Collections.Generic.List[object]]::new()
    foreach($e in $Entries){
        $copies.Add([pscustomobject]@{SourcePath=$e.SourcePath;EntryName=$e.EntryName;Length=[long]$e.Length;
            NeedsConversion=[bool]$e.NeedsConversion;Extension=$e.Extension;EncodedBy=[string]$e.EncodedBy})
    }
    return ,$copies
}
function Invoke-ParallelAvif {
    param([System.Collections.Generic.List[object]]$Entries,[string]$Encoder,[string]$Decoder,
        [int]$Quality,[int]$Workers,[string]$TempDir,[string]$OutputName,
        [System.Collections.IDictionary]$StageTimes,[switch]$FullPass,[switch]$CpuProbe,[switch]$GpuOnly)
    $pending=@($Entries | Where-Object {$_.NeedsConversion})
    if($pending.Count -eq 0){return 0}
    [void][IO.Directory]::CreateDirectory($TempDir)
    $kind=if(-not $FullPass){'calibrate'}elseif($CpuProbe){'cpu-retry'}elseif($GpuOnly){'gpu-retry'}else{'initial'}
    $script:fakeCalls.Add([pscustomobject]@{Kind=$kind;Count=$pending.Count;Names=@($pending.EntryName);Quality=$Quality})
    for($i=0;$i -lt $pending.Count;$i++){
        $e=$pending[$i]
        $backend=if($CpuProbe){'Cpu'}elseif($GpuOnly){'Gpu'}else{if($e.EntryName -match 'page(1|7)\.avif'){'Cpu'}else{'Gpu'}}
        $bytes=if($kind -eq 'calibrate'){
            if($script:scenario -eq 'q40'){if($Quality -ge 70){400}elseif($Quality -ge 50){300}else{180}}elseif($Quality -ge 70){400}elseif($Quality -ge 50){150}else{100}
        }elseif($script:scenario -eq 'oversize'){
            if($kind -eq 'initial'){1500}elseif($kind -eq 'cpu-retry'){200}else{700}
        }else{400}
        $dest=Join-Path $TempDir ("encoded_{0:D2}.avif" -f $i)
        [IO.File]::WriteAllBytes($dest,[byte[]]::new($bytes))
        $e.SourcePath=$dest; $e.Length=[long]$bytes
        $e | Add-Member -NotePropertyName EncodedBy -NotePropertyValue $backend -Force
    }
    return $pending.Count
}
function Assert {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('BookCpuCalibration_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tmp)
try{
    $entries=[System.Collections.Generic.List[object]]::new()
    foreach($i in 0..8){
        $entries.Add([pscustomobject]@{SourcePath=("original_{0}.png" -f $i);
            EntryName=("page{0}.avif" -f $i);Length=3000L;NeedsConversion=$true;Extension='.png';EncodedBy=''})
    }
    $cache=@()
    foreach($i in @(0,4,8)){
        $path=Join-Path $tmp ("gpu_{0}.avif" -f $i)
        [IO.File]::WriteAllBytes($path,[byte[]]::new(200))
        $cache+= [pscustomobject]@{Index=$i;Path=$path;Length=200L;EncodedBy='Gpu'}
    }
    $gpuProbe=[pscustomobject]@{Quality=80;Cache=$cache}
    $cal=Invoke-GpuLedCpuCalibration -Entries $entries -GpuProbe $gpuProbe -Encoder 'unused' -ScratchDir $tmp -VolumeName 'test'
    Assert ($cal.Quality -eq 50) 'Calibration did not select the first size-compatible CPU quality'
    Assert (@($script:probeProgress | Where-Object {$_.Unit -eq '試行' -and $_.Completed -eq 2 -and $_.Total -eq 3}).Count -eq 1) 'CPU calibration iteration progress missing'
    Assert ($script:probeProgress[-1].Done) 'CPU calibration progress not closed after short search'
    Assert (@($script:fakeCalls | Where-Object {$_.Kind -eq 'calibrate'}).Count -eq 2) 'CPU calibration must use only two rounds here'
    $script:probeProgress.Clear()
    $script:scenario='q40'
    $script:fakeCalls.Clear()
    $cal40=Invoke-GpuLedCpuCalibration -Entries $entries -GpuProbe $gpuProbe -Encoder 'unused' -ScratchDir (Join-Path $tmp 'q40-case') -VolumeName 'q40-case'
    Assert ($cal40.Quality -eq 40) 'CPU calibration should prefer q40 instead of falling to q30'
    Assert (@($script:fakeCalls | Where-Object {$_.Kind -eq 'calibrate'}).Count -eq 3) 'CPU q40 calibration should try exactly three qualities'
    Assert (@($script:fakeCalls | Where-Object {$_.Quality -eq 30}).Count -eq 0) 'q30 must not be probed as a normal baseline'
    $script:scenario='normal'
    $script:probeProgress.Clear()
    $script:fakeCalls.Clear()
    Assert (@($cal.Cache).Count -eq 3) 'Expected three CPU calibration pages'
    Assert (@($cal.Cache | Where-Object {$_.EncodedBy -ne 'Cpu'}).Count -eq 0) 'CPU calibration cache backend missing'
    Assert (@($entries | Where-Object {$_.SourcePath -notmatch '^original_'}).Count -eq 0) 'Calibration modified original entries'
    $script:HybridCpuQuality=$cal.Quality
    $script:fakeCalls.Clear()
    $result=Invoke-GpuLedHybridConversion -Entries $entries -GpuProbe $gpuProbe -Calibration $cal -Encoder 'unused' -GpuQuality 80 -ScratchDir (Join-Path $tmp 'normal') -OutputName 'normal' -MaxImageBytes 4000
    Assert ($result.UnderLimit -and $result.Bytes -le 4000) 'Normal first-pass should fit'
    Assert (@($script:fakeCalls).Count -eq 1) 'Fitting volume must not retry'
    Assert (@($script:fakeCalls[0].Names | Where-Object {$_ -in @('page0.avif','page4.avif','page8.avif')}).Count -eq 0) 'Calibrated pages were encoded again'
    Assert (@($result.Entries | Where-Object {$_.EncodedBy -eq 'Cpu'}).Count -ge 3) 'Calibrated outputs not reused in final result'
    Assert (@($result.Entries).Count -eq 9) 'Page count altered'

    $script:scenario='oversize'
    $script:HybridCpuQuality=50
    $script:fakeCalls.Clear()
    $out=Invoke-GpuLedHybridConversion -Entries $entries -GpuProbe $gpuProbe -Calibration $cal -Encoder 'unused' -GpuQuality 80 -ScratchDir (Join-Path $tmp 'oversize') -OutputName 'oversize' -MaxImageBytes 6500
    Assert ($out.UnderLimit -and $out.Bytes -le 6500) 'Selective retry failed to fit final size'
    Assert (@($script:fakeCalls).Count -eq 3) 'Expected initial + CPU-only + GPU-only passes'
    Assert ($script:fakeCalls[0].Kind -eq 'initial' -and $script:fakeCalls[1].Kind -eq 'cpu-retry' -and $script:fakeCalls[2].Kind -eq 'gpu-retry') 'Retry order or backend incorrect'
    $cpuNames=@($script:fakeCalls[1].Names)
    $gpuNames=@($script:fakeCalls[2].Names)
    Assert (@($cpuNames | Where-Object {$_ -in $gpuNames}).Count -eq 0) 'CPU pages were encoded again in GPU retry'
    Assert (@($script:fakeCalls[0].Names | Where-Object {$_ -in @('page0.avif','page4.avif','page8.avif')}).Count -eq 0) 'Calibrated cache got encoded twice'
    Assert (@($entries | Where-Object {$_.SourcePath -notmatch '^original_'}).Count -eq 0) 'Selective retry modified input files'

    $script:fakeCalls.Clear()
    $script:HybridCpuQuality=30
    $failed=$false
    try{
        Invoke-GpuLedHybridConversion -Entries $entries -GpuProbe $gpuProbe -Calibration $cal -Encoder 'unused' -GpuQuality 30 -ScratchDir (Join-Path $tmp 'reject') -OutputName 'reject' -MaxImageBytes 100 | Out-Null
    }catch{if($_.Exception.Message -notmatch '70MiB|exceeded'){throw};$failed=$true}
    Assert $failed 'Over-limit volume must not be committed'
    Write-Host 'PASS: GPU-led CPU calibration, 3-page cache reuse, selective retries, 70MiB refusal and originals preserved'
}finally{
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
