# PowerShell 7.6 ThreadJobs keep the independent GPU and CPU size searches
# concurrent without introducing another executable or changing search criteria.

# Independent of the CPU worker count used by the Hybrid full conversion.
function Select-CpuProbeWorkers {
    param([Nullable[int]]$Requested, [switch]$Interactive)
    if ($null -ne $Requested) {
        if ($Requested -lt 0 -or $Requested -gt 8) { throw 'CPU品質探索並列数は0～8で指定してください' }
        return [int]$Requested
    }
    if (-not $Interactive) { return 4 }
    while ($true) {
        $answer = Read-MangaResponse 'CPU品質探索の並列数 [0-8]（Enterで4、0でCPU探索を省略）'
        if ($null -eq $answer) { return $null }
        $answer = $answer.Trim()
        if ($answer -eq '') { return 4 }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 0 -and $number -le 8) {
            return $number
        }
        Write-Host '0～8の整数かEnterを入力してください。' -ForegroundColor Yellow
    }
}
function Invoke-HybridQualitySearch {
    param(
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[object]]$Entries,
        [Parameter(Mandatory=$true)][string]$Encoder,
        [Parameter(Mandatory=$true)][string]$CpuEncoder,
        [string]$Decoder,
        [Parameter(Mandatory=$true)][int]$GpuWorkers,
        [Parameter(Mandatory=$true)][ValidateRange(0,8)][int]$CpuProbeWorkers,
        [Parameter(Mandatory=$true)][string]$ScratchDir,
        [Parameter(Mandatory=$true)][string]$VolumeName,
        [Parameter(Mandatory=$true)][long]$SampleLimitBytes,
        [Parameter(Mandatory=$true)][string]$ScriptRoot,
        [string]$CancelFile,
        [int]$EncoderTimeoutSeconds=300
    )
    New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null
    $probeCancelFile=Join-Path $ScratchDir '.quality-probe-cancel'
    $functionNames=@('Test-AvifOutput','Invoke-ParallelAvif','Get-AvifSampleEstimate','Find-AvifQuality')
    $definitions=@{}
    foreach($name in $functionNames){
        $definitions[$name]=(Get-Command -Name $name -CommandType Function -ErrorAction Stop).Definition
    }

    $worker={
        param($context)
        $ErrorActionPreference='Stop'
        . (Join-Path $context.ScriptRoot 'GPU-Functions.ps1')
        . (Join-Path $context.ScriptRoot 'Hybrid-Functions.ps1')
        foreach($name in @('Test-AvifOutput','Invoke-ParallelAvif','Get-AvifSampleEstimate','Find-AvifQuality')){
            Set-Item -Path ("Function:" + $name) -Value ([scriptblock]::Create($context.Definitions[$name]))
        }
        $ConversionMode='Hybrid'
        $GpuWorkers=[int]$context.GpuWorkers
        $CpuWorkers=[int]$context.CpuProbeWorkers
        $CancelFile=[string]$context.CancelFile
        $EncoderTimeoutSeconds=[int]$context.EncoderTimeoutSeconds
        $script:CpuEncoder=[string]$context.CpuEncoder
        $script:HybridCpuQuality=95
        $script:EncodePasses=[System.Collections.Generic.List[object]]::new()
        $cpu=($context.Backend -eq 'Cpu')
        $workers=if($cpu){$CpuWorkers}else{$GpuWorkers}
        $volume=if($cpu){"$($context.VolumeName) / CPU"}else{[string]$context.VolumeName}
        $choice=Find-AvifQuality -Entries $context.Entries -Encoder $context.Encoder -Decoder $context.Decoder `
            -Workers $workers -ScratchDir $context.ScratchDir -VolumeName $volume `
            -SampleLimitBytes $context.SampleLimitBytes -CpuProbe:$cpu `
            -ProgressState $context.ProgressState -ProgressBackend $context.Backend
        [pscustomobject]@{
            Backend=$context.Backend
            Choice=$choice
            Passes=$script:EncodePasses.ToArray()
        }
    }

    $progress=[System.Collections.Concurrent.ConcurrentDictionary[string,int]]::new()
    $progress['Gpu']=0
    $progress['Cpu']=0
    $totalProbes=if($CpuProbeWorkers -gt 0){10}else{5}
    $jobs=[System.Collections.Generic.List[object]]::new()
    $pending=[System.Collections.Generic.List[object]]::new()
    $results=@{}
    $succeeded=$false
    try{
        if($CancelFile -and (Test-Path -LiteralPath $CancelFile)){throw 'Quality search cancelled'}
        $backends=if($CpuProbeWorkers -eq 0){@('Gpu')}else{@('Gpu','Cpu')}
        foreach($backend in $backends){
            $context=@{
                Backend=$backend
                Entries=$Entries
                Encoder=$Encoder
                CpuEncoder=$CpuEncoder
                Decoder=$Decoder
                GpuWorkers=$GpuWorkers
                CpuProbeWorkers=$CpuProbeWorkers
                ScratchDir=$ScratchDir
                VolumeName=$VolumeName
                SampleLimitBytes=$SampleLimitBytes
                ScriptRoot=$ScriptRoot
                CancelFile=$probeCancelFile
                EncoderTimeoutSeconds=$EncoderTimeoutSeconds
                Definitions=$definitions
                ProgressState=$progress
            }
            $job=Start-ThreadJob -Name ("QualityProbe-"+$backend) -ArgumentList $context -ScriptBlock $worker
            $jobs.Add($job)
            $pending.Add($job)
        }
        Write-MangaPageProgress -Completed 0 -Total $totalProbes -Activity '品質探索' -Unit '試行' `
            -Detail $(if($CpuProbeWorkers -eq 0){'GPU 0/5'}else{'GPU 0/5・CPU 0/5'})
        while($pending.Count -gt 0){
            if($CancelFile -and (Test-Path -LiteralPath $CancelFile)){throw 'Quality search cancelled'}
            $finished=Wait-Job -Job $pending.ToArray() -Any -Timeout 1
            $doneGpu=$progress['Gpu']
            $doneCpu=$progress['Cpu']
            $detail=if($CpuProbeWorkers -eq 0){"GPU $doneGpu/5"}else{"GPU $doneGpu/5・CPU $doneCpu/5"}
            Write-MangaPageProgress -Completed ($doneGpu+$doneCpu) -Total $totalProbes `
                -Activity '品質探索' -Unit '試行' -Detail $detail
            if($null -eq $finished){continue}
            if($finished.State -ne 'Completed'){
                # Receive-Job preserves the actual encoder/probe exception.
                Receive-Job -Job $finished -ErrorAction Stop | Out-Null
                throw ("Quality probe did not complete: {0} ({1})" -f $finished.Name,$finished.State)
            }
            [void]$pending.Remove($finished)
        }
        foreach($job in $jobs){
            $output=@(Receive-Job -Job $job -ErrorAction Stop)
            if($output.Count -ne 1 -or $null -eq $output[0].Choice){
                throw "Quality probe returned an invalid result: $($job.Name)"
            }
            $results[$output[0].Backend]=$output[0]
        }
        if(-not $results.ContainsKey('Gpu') -or ($CpuProbeWorkers -gt 0 -and -not $results.ContainsKey('Cpu'))){
            throw 'Missing required GPU or CPU quality probe'
        }
        $passes=@($results.Gpu.Passes)
        $cpuChoice=$null
        if($CpuProbeWorkers -gt 0){
            $passes+=@($results.Cpu.Passes)
            $cpuChoice=$results.Cpu.Choice
        }
        $succeeded=$true
        return [pscustomobject]@{
            GpuChoice=$results.Gpu.Choice
            CpuChoice=$cpuChoice
            Passes=$passes
        }
    }
    finally{
        Write-MangaPageProgress -Activity '品質探索' -Done
        if(-not $succeeded -and $jobs.Count -gt 0){
            # The scheduler polls this file and disposes all active encoders in finally.
            New-Item -ItemType File -Path $probeCancelFile -Force | Out-Null
            $running=@($jobs | Where-Object {$_.State -eq 'Running'})
            if($running.Count -gt 0){Wait-Job -Job $running -Timeout 15 | Out-Null}
        }
        foreach($job in $jobs){
            if($job.State -eq 'Running'){Stop-Job -Job $job -ErrorAction SilentlyContinue}
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $probeCancelFile -Force -ErrorAction SilentlyContinue
    }
}
