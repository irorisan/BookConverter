# PowerShell 7.6 ThreadJobs keep the independent GPU and CPU size searches
# concurrent without introducing another executable or changing search criteria.
function Invoke-HybridQualitySearch {
    param(
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[object]]$Entries,
        [Parameter(Mandatory=$true)][string]$Encoder,
        [Parameter(Mandatory=$true)][string]$CpuEncoder,
        [string]$Decoder,
        [Parameter(Mandatory=$true)][int]$GpuWorkers,
        [Parameter(Mandatory=$true)][int]$CpuWorkers,
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
        $CpuWorkers=[int]$context.CpuWorkers
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
            -SampleLimitBytes $context.SampleLimitBytes -CpuProbe:$cpu
        [pscustomobject]@{
            Backend=$context.Backend
            Choice=$choice
            Passes=$script:EncodePasses.ToArray()
        }
    }

    $jobs=[System.Collections.Generic.List[object]]::new()
    $pending=[System.Collections.Generic.List[object]]::new()
    $results=@{}
    $succeeded=$false
    try{
        if($CancelFile -and (Test-Path -LiteralPath $CancelFile)){throw 'Quality search cancelled'}
        foreach($backend in @('Gpu','Cpu')){
            $context=@{
                Backend=$backend
                Entries=$Entries
                Encoder=$Encoder
                CpuEncoder=$CpuEncoder
                Decoder=$Decoder
                GpuWorkers=$GpuWorkers
                CpuWorkers=$CpuWorkers
                ScratchDir=$ScratchDir
                VolumeName=$VolumeName
                SampleLimitBytes=$SampleLimitBytes
                ScriptRoot=$ScriptRoot
                CancelFile=$probeCancelFile
                EncoderTimeoutSeconds=$EncoderTimeoutSeconds
                Definitions=$definitions
            }
            $job=Start-ThreadJob -Name ("QualityProbe-"+$backend) -ArgumentList $context -ScriptBlock $worker
            $jobs.Add($job)
            $pending.Add($job)
        }
        while($pending.Count -gt 0){
            if($CancelFile -and (Test-Path -LiteralPath $CancelFile)){throw 'Quality search cancelled'}
            $finished=Wait-Job -Job $pending.ToArray() -Any -Timeout 1
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
        if(-not $results.ContainsKey('Gpu') -or -not $results.ContainsKey('Cpu')){
            throw 'Missing GPU or CPU quality probe'
        }
        $succeeded=$true
        return [pscustomobject]@{
            GpuChoice=$results.Gpu.Choice
            CpuChoice=$results.Cpu.Choice
            Passes=@($results.Gpu.Passes)+@($results.Cpu.Passes)
        }
    }
    finally{
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
