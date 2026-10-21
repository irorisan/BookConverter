# Hybrid CPU-probe-workers=0: use a GPU-sized reference and at most three
# CPU calibration pages. No assumption that NVENC CQ and libavif q are equivalent.
function Invoke-GpuLedCpuCalibration {
    param(
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[object]]$Entries,
        [Parameter(Mandatory=$true)]$GpuProbe,
        [Parameter(Mandatory=$true)][string]$Encoder,
        [string]$Decoder,
        [Parameter(Mandatory=$true)][string]$ScratchDir,
        [Parameter(Mandatory=$true)][string]$VolumeName
    )
    $gpuSamples=@($GpuProbe.Cache)
    if($gpuSamples.Count -eq 0){throw 'No GPU quality samples available for CPU calibration'}
    $positions=[System.Collections.Generic.SortedSet[int]]::new()
    [int]$last=$gpuSamples.Count - 1
    [int]$middle=[int][Math]::Floor($last / 2.0)
    foreach($position in @(0,$middle,$last)){
        [void]$positions.Add($position)
    }
    $references=[System.Collections.Generic.List[object]]::new()
    [long]$gpuBytes=0
    foreach($position in $positions){
        $reference=$gpuSamples[$position]
        $references.Add($reference)
        $gpuBytes += [long]$reference.Length
    }
    if($gpuBytes -le 0){throw 'Invalid GPU calibration reference sizes'}

    $calibrationQualities=@(70,50,40)
    Write-MangaPageProgress -Completed 0 -Total $calibrationQualities.Count -Activity 'CPU校正' -Unit '試行'
    try {
    for($round=0;$round -lt $calibrationQualities.Count;$round++){
        $quality=$calibrationQualities[$round]
        $selected=[System.Collections.Generic.List[object]]::new()
        foreach($ref in $references){
            $source=$Entries[[int]$ref.Index]
            $selected.Add([pscustomobject]@{
                SourceIndex=[int]$ref.Index
                SourcePath=$source.SourcePath
                EntryName=$source.EntryName
                Length=[long]$source.Length
                NeedsConversion=$true
                Extension=$source.Extension
            })
        }
        $dir=Join-Path $ScratchDir ('cpu_calibration_q'+$quality)
        [void](Invoke-ParallelAvif -Entries $selected -Encoder $Encoder -Decoder $Decoder `
            -Quality $quality -Workers $selected.Count -TempDir $dir `
            -OutputName "$VolumeName / CPU校正 q$quality" -CpuProbe)
        [long]$cpuBytes=0
        $cache=[System.Collections.Generic.List[object]]::new()
        foreach($sample in $selected){
            $cpuBytes += [long]$sample.Length
            $cache.Add([pscustomobject]@{
                Index=[int]$sample.SourceIndex
                Path=$sample.SourcePath
                Length=[long]$sample.Length
                EncodedBy='Cpu'
            })
        }
        Write-Host ('  CPU校正 q{0}: GPU代表 {1:N0} bytes / CPU代表 {2:N0} bytes' -f $quality,$gpuBytes,$cpuBytes)
        Write-MangaPageProgress -Completed ($round+1) -Total $calibrationQualities.Count -Activity 'CPU校正' -Unit '試行'
        if($cpuBytes -le $gpuBytes -or $quality -eq 40){
            if($cpuBytes -gt $gpuBytes){
                Write-Warning 'CPU q40でもGPU代表容量を超過。最終容量超過時のみCPU担当ページをq30まで差分再変換します。'
            }
            return [pscustomobject]@{
                Quality=[int]$quality
                Cache=$cache.ToArray()
                GpuReferenceBytes=$gpuBytes
                CpuReferenceBytes=$cpuBytes
            }
        }
    }
    throw 'CPU calibration did not produce a usable sample'
    }
    finally {
        Write-MangaPageProgress -Activity 'CPU校正' -Done
    }
}

# Return a working copy with only the named encoder's pages marked for redo.
# All other completed AVIFs remain byte-identical in the next attempt.
function Copy-SelectiveHybridRetry {
    param(
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[object]]$Original,
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[object]]$Previous,
        [Parameter(Mandatory=$true)][ValidateSet('Gpu','Cpu')][string]$Backend
    )
    $next=Copy-VolumeEntries -Entries $Previous
    for($i=0;$i -lt $next.Count;$i++){
        $redo=($next[$i].EncodedBy -eq $Backend)
        $next[$i].NeedsConversion=$redo
        if($redo){
            if(-not $Original[$i].NeedsConversion){throw 'Attempted to re-encode an unchanged source entry'}
            $next[$i].SourcePath=$Original[$i].SourcePath
            $next[$i].Length=[long]$Original[$i].Length
            $next[$i].Extension=$Original[$i].Extension
        }
    }
    return ,$next
}

function Get-HybridPayloadSize {
    param([Parameter(Mandatory=$true)][System.Collections.Generic.List[object]]$Entries)
    [long]$total=0
    foreach($entry in $Entries){$total += [long]$entry.Length}
    return $total
}

function Invoke-GpuLedHybridConversion {
    param(
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[object]]$Entries,
        [Parameter(Mandatory=$true)]$GpuProbe,
        [Parameter(Mandatory=$true)]$Calibration,
        [Parameter(Mandatory=$true)][string]$Encoder,
        [string]$Decoder,
        [Parameter(Mandatory=$true)][int]$GpuQuality,
        [Parameter(Mandatory=$true)][string]$ScratchDir,
        [Parameter(Mandatory=$true)][string]$OutputName,
        [Parameter(Mandatory=$true)][long]$MaxImageBytes,
        [int]$GpuWorkers=12,
        [int]$CpuWorkers=4,
        [System.Collections.IDictionary]$StageTimes
    )
    $count=@($Entries | Where-Object {$_.NeedsConversion}).Count
    $trial=Copy-VolumeEntries -Entries $Entries
    # The three CPU calibration outputs replace matching GPU quality samples.
    # They must be reused as real final pages, not only read for size estimates.
    foreach($cached in @($GpuProbe.Cache)+@($Calibration.Cache)){
        if(-not (Test-Path -LiteralPath $cached.Path -PathType Leaf)){
            throw "Missing quality sample cache: $($cached.Path)"
        }
        $index=[int]$cached.Index
        $trial[$index].SourcePath=[string]$cached.Path
        $trial[$index].Length=[long]$cached.Length
        $trial[$index].EncodedBy=[string]$cached.EncodedBy
        $trial[$index].NeedsConversion=$false
    }
    Write-MangaStage -Name $OutputName -Stage 'AVIF全ページ変換（GPU主体 / 初回）'
    [void](Invoke-ParallelAvif -Entries $trial -Encoder $Encoder -Decoder $Decoder -Quality $GpuQuality `
        -Workers $GpuWorkers -TempDir (Join-Path $ScratchDir 'full_gpu_led') `
        -OutputName $OutputName -StageTimes $StageTimes -FullPass)
    $size=Get-HybridPayloadSize -Entries $trial
    Write-Host ('  GPU主体初回: {0:N1} MiB / CPU校正の再利用 {1}枚' -f ($size/1MB),@($Calibration.Cache).Count)
    if($size -le $MaxImageBytes){
        return [pscustomobject]@{Entries=$trial;Quality=$GpuQuality;Bytes=$size;Converted=$count;UnderLimit=$true}
    }

    # On oversize, only CPU pages may be re-encoded by the first retry;
    # GPU output and original page ordering are preserved.
    if($script:HybridCpuQuality -gt 30 -and @($trial | Where-Object {$_.EncodedBy -eq 'Cpu'}).Count -gt 0){
        [long]$cpuBytes=0
        foreach($entry in $trial){if($entry.EncodedBy -eq 'Cpu'){$cpuBytes += [long]$entry.Length}}
        $overflow=[Math]::Max(0,$size-$MaxImageBytes)
        $step=[int][Math]::Max(10,[Math]::Min(40,[Math]::Ceiling(80*$overflow/[double][Math]::Max(1,$cpuBytes))))
        $script:HybridCpuQuality=[int][Math]::Max(30,$script:HybridCpuQuality-$step)
        $retry=Copy-SelectiveHybridRetry -Original $Entries -Previous $trial -Backend Cpu
        Write-Warning "容量超過: CPU担当ページだけをq$($script:HybridCpuQuality)で再変換（GPU成果物は再利用）"
        [void](Invoke-ParallelAvif -Entries $retry -Encoder $Encoder -Decoder $Decoder -Quality $script:HybridCpuQuality `
            -Workers $CpuWorkers -TempDir (Join-Path $ScratchDir 'retry_cpu_only') `
            -OutputName $OutputName -StageTimes $StageTimes -CpuProbe -FullPass)
        $trial=$retry
        $size=Get-HybridPayloadSize -Entries $trial
        if($size -le $MaxImageBytes){
            return [pscustomobject]@{Entries=$trial;Quality=$GpuQuality;Bytes=$size;Converted=$count;UnderLimit=$true}
        }
    }

    # Final permitted retry: re-encode only GPU pages at lower NVENC quality.
    # All CPU results from calibration/first pass/CPU retry are reused intact.
    if($GpuQuality -gt 30 -and @($trial | Where-Object {$_.EncodedBy -eq 'Gpu'}).Count -gt 0){
        [long]$gpuBytes=0
        foreach($entry in $trial){if($entry.EncodedBy -eq 'Gpu'){$gpuBytes += [long]$entry.Length}}
        $overflow=[Math]::Max(0,$size-$MaxImageBytes)
        $step=[int][Math]::Max(10,[Math]::Min(40,[Math]::Ceiling(80*$overflow/[double][Math]::Max(1,$gpuBytes))))
        $newGpuQuality=[int][Math]::Max(30,$GpuQuality-$step)
        $retry=Copy-SelectiveHybridRetry -Original $Entries -Previous $trial -Backend Gpu
        Write-Warning "容量超過: GPU担当ページだけをQ$newGpuQualityで再変換（CPU成果物は再利用）"
        [void](Invoke-ParallelAvif -Entries $retry -Encoder $Encoder -Decoder $Decoder -Quality $newGpuQuality `
            -Workers $GpuWorkers -TempDir (Join-Path $ScratchDir 'retry_gpu_only') `
            -OutputName $OutputName -StageTimes $StageTimes -GpuOnly -FullPass)
        $trial=$retry
        $size=Get-HybridPayloadSize -Entries $trial
        if($size -le $MaxImageBytes){
            return [pscustomobject]@{Entries=$trial;Quality=$newGpuQuality;Bytes=$size;Converted=$count;UnderLimit=$true}
        }
    }
    throw 'Experimental conversion exceeded 70MiB after selective retries; no output committed'
}
