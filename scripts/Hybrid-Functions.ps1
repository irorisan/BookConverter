# Experimental single-page process scheduler. Parent owns both queues and all entry mutations.
function Get-HybridCpuArguments {
    param([int]$Quality, [string]$InputPath, [string]$OutputPath)
    foreach ($path in @($InputPath,$OutputPath)) {
        if ($path.Contains('"')) { throw 'Invalid encoder path' }
    }
    return ('--codec aom --yuv 420 --depth 8 -q {0} -s 6 -j 1 "{1}" "{2}"' -f $Quality,$InputPath,$OutputPath)
}

function Test-HybridAvifenc {
    param([string]$Path)
    $help = & $Path --help 2>&1 | Out-String
    if ($help -notmatch '(?i)aom' -or $help -notmatch '--codec' -or $help -notmatch '--yuv' -or
        $help -notmatch '--depth' -or $help -notmatch '(?m)\s-q[, ]' -or $help -notmatch '(?m)\s-j[, ]') {
        throw 'avifenc must support AOM, --codec, --yuv, --depth, -q quality and -j jobs. Check --help.'
    }
    return $help
}

function Invoke-HybridEncode {
    param(
        [Parameter(Mandatory=$true)][object[]]$Entries,
        [string]$FFmpeg, [string]$Avifenc, [string]$Decoder,
        [ValidateRange(30,95)][int]$GpuQuality,
        [ValidateRange(0,100)][int]$CpuQuality,
        [ValidateRange(0,12)][int]$GpuWorkers=12,
        [ValidateRange(0,4)][int]$CpuWorkers=4,
        [Parameter(Mandatory=$true)][string]$TempDir,
        [string]$CancelFile,
        [ValidateRange(1,86400)][int]$TimeoutSeconds=300
    )
    if ($GpuWorkers + $CpuWorkers -eq 0) { throw 'No workers configured' }
    # Never remove a caller-owned directory during error cleanup.
    if (Test-Path -LiteralPath $TempDir) { throw "Work directory already exists: $TempDir" }
    New-Item -ItemType Directory -Path $TempDir | Out-Null
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $fallback = [System.Collections.Generic.Queue[object]]::new()
    $ready=@{Gpu=[System.Collections.Generic.Queue[object]]::new(); Cpu=[System.Collections.Generic.Queue[object]]::new()}
    $running = [System.Collections.Generic.List[object]]::new()
    $stats = [ordered]@{ GpuPages=0; CpuPages=0; GpuAttempts=0; CpuAttempts=0;
        GpuSeconds=0.0; CpuSeconds=0.0; Errors=0; Retries=0;
        PeakGpu=0; PeakCpu=0; PeakTotal=0; GpuQuality=$GpuQuality; CpuQuality=$CpuQuality }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $success = $false
    $cpuLimit = $CpuWorkers
    try {
        for ($i=0; $i -lt $Entries.Count; $i++) {
            $pending.Enqueue([pscustomobject]@{Entry=$Entries[$i]; Index=$i; Backend=''; Attempts=0; InputPath=$null; OutputPath=(Join-Path $TempDir ('page_{0:D6}.avif' -f $i)); Staged=$null; Process=$null; Started=0.0; Preparing=$false})
        }
        while ($pending.Count + $fallback.Count + $ready.Gpu.Count + $ready.Cpu.Count + $running.Count -gt 0) {
            if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { throw 'Conversion cancelled' }
            # Reap before dispatch: retry and fallback always respect the same process caps.
            for ($i=$running.Count-1; $i -ge 0; $i--) {
                $job = $running[$i]
                $elapsed = $timer.Elapsed.TotalSeconds - $job.Started
                $timedOut = $elapsed -gt $TimeoutSeconds
                if (-not $job.Process.HasExited -and -not $timedOut) { continue }
                if ($timedOut -and -not $job.Process.HasExited) { $job.Process.Kill(); $job.Process.WaitForExit() }
                $code = $job.Process.ExitCode
                $job.Process.Dispose(); $job.Process=$null
                $running.RemoveAt($i)
                $stats[$job.Backend+'Seconds'] += $elapsed
                if ($job.Preparing) {
                    if ($timedOut -or $code -ne 0 -or -not (Test-Path -LiteralPath $job.InputPath)) {
                        $stats.Errors++
                        throw "WebP decode failed: $($job.Entry.EntryName)"
                    }
                    $job.Preparing=$false; $job.Attempts--
                    $stats[$job.Backend+'Attempts']--
                    $ready[$job.Backend].Enqueue($job)
                    continue
                }
                $valid = $false
                if (-not $timedOut -and $code -eq 0) {
                    try { Test-AvifOutput -Path $job.OutputPath; $valid=$true } catch { $valid=$false }
                }
                if ($valid) {
                    $job.Entry.SourcePath=$job.OutputPath
                    $job.Entry.Length=[long](Get-Item -LiteralPath $job.OutputPath).Length
                    $stats[$job.Backend+'Pages']++
                    Remove-Item -LiteralPath $job.Staged -Force -ErrorAction SilentlyContinue
                    if ($job.InputPath -ne $job.Staged) { Remove-Item -LiteralPath $job.InputPath -Force -ErrorAction SilentlyContinue }
                } else {
                    $stats.Errors++
                    Remove-Item -LiteralPath $job.OutputPath -Force -ErrorAction SilentlyContinue
                    if ($job.Backend -eq 'Gpu') {
                        Write-Warning "GPU failed; CPU fallback: $($job.Entry.EntryName) (code $code, timeout $timedOut)"
                        $job.Attempts=0
                        $fallback.Enqueue($job)
                        $cpuLimit=[Math]::Max(1,$CpuWorkers)
                        $stats.Retries++
                    } elseif ($job.Attempts -lt 2) {
                        $fallback.Enqueue($job); $stats.Retries++
                        Write-Warning "CPU retry: $($job.Entry.EntryName)"
                    } else { throw "CPU encode failed after retry: $($job.Entry.EntryName) (code $code, timeout $timedOut)" }
                }
            }
            # GPU gets the shared FIFO first. CPU cannot reserve a fixed proportion of pages.
            foreach ($backend in @('Gpu','Cpu')) {
                $limit = if ($backend -eq 'Gpu') { $GpuWorkers } else { $cpuLimit }
                $active = @($running | Where-Object { $_.Backend -eq $backend }).Count
                while ($active -lt $limit) {
                    $job=$null
                    if ($ready[$backend].Count -gt 0) { $job=$ready[$backend].Dequeue() }
                    elseif ($backend -eq 'Cpu' -and $fallback.Count -gt 0) { $job=$fallback.Dequeue() }
                    elseif ($pending.Count -gt 0 -and ($backend -eq 'Gpu' -or $GpuWorkers -eq 0 -or $pending.Count -gt $GpuWorkers)) {
                        $job=$pending.Dequeue()
                    }
                    if ($null -eq $job) { break }
                    $job.Backend=$backend; $job.Attempts++
                    $stats[$backend+'Attempts']++
                    $job.Started=$timer.Elapsed.TotalSeconds
                    $p=$null
                    try {
                        if (-not $job.InputPath) {
                            $job.Staged=Join-Path $TempDir ('page_{0:D6}{1}' -f $job.Index,$job.Entry.Extension)
                            Copy-Item -LiteralPath $job.Entry.SourcePath -Destination $job.Staged
                            $job.InputPath=$job.Staged
                            if ($job.Entry.Extension -eq '.webp') {
                                if (-not $Decoder) { throw 'WebP requires dwebp' }
                                $job.InputPath=[IO.Path]::ChangeExtension($job.Staged,'.png')
                                $job.Preparing=$true
                            }
                        }
                        $info=New-Object Diagnostics.ProcessStartInfo
                        $info.FileName=if ($backend -eq 'Gpu') { $FFmpeg } else { $Avifenc }
                        $info.Arguments=if ($backend -eq 'Gpu') {
                            Get-GpuEncodeArguments -Quality $GpuQuality -InputPath $job.InputPath -OutputPath $job.OutputPath
                        } else { Get-HybridCpuArguments -Quality $CpuQuality -InputPath $job.InputPath -OutputPath $job.OutputPath }
                        if ($job.Preparing) {
                            $info.FileName=$Decoder
                            $info.Arguments='-quiet "{0}" -o "{1}"' -f $job.Staged,$job.InputPath
                        }
                        $info.UseShellExecute=$false; $info.CreateNoWindow=$true
                        $p=New-Object Diagnostics.Process; $p.StartInfo=$info
                        if (-not $p.Start()) { throw 'Encoder start failed' }
                        $job.Process=$p; $running.Add($job); $p=$null
                        $active++
                        $stats['Peak'+$backend]=[Math]::Max($stats['Peak'+$backend],$active)
                        $stats.PeakTotal=[Math]::Max($stats.PeakTotal,$running.Count)
                    } catch {
                        if ($p) { $p.Dispose() }
                        $stats.Errors++
                        if ($backend -eq 'Gpu') {
                            Write-Warning "GPU launch failed; CPU fallback: $($job.Entry.EntryName) / $_"
                            $job.Attempts=0; $fallback.Enqueue($job); $cpuLimit=[Math]::Max(1,$CpuWorkers); $stats.Retries++
                        } elseif ($job.Attempts -lt 2) { $fallback.Enqueue($job); $stats.Retries++ }
                        else { throw }
                    }
                }
            }
            if ($running.Count -gt 0) { Start-Sleep -Milliseconds 10 }
        }
        $success=$true
    } catch {
        $_.Exception.Data['HybridMetrics']=$stats
        throw
    } finally {
        foreach ($job in $running) {
            $stats[$job.Backend+'Seconds'] += $timer.Elapsed.TotalSeconds-$job.Started
            try { if (-not $job.Process.HasExited) { $job.Process.Kill(); $job.Process.WaitForExit() } }
            catch { Write-Warning "Encoder cleanup: $_" }
            finally { $job.Process.Dispose() }
        }
        $timer.Stop()
        $stats.Seconds=$timer.Elapsed.TotalSeconds
        $stats.GpuIdleSlotSeconds=[Math]::Max(0.0,$GpuWorkers*$stats.Seconds-$stats.GpuSeconds)
        $stats.CpuIdleSlotSeconds=[Math]::Max(0.0,$cpuLimit*$stats.Seconds-$stats.CpuSeconds)
        $stats.GpuAverageSeconds=if ($stats.GpuAttempts) { $stats.GpuSeconds/$stats.GpuAttempts } else { 0 }
        $stats.CpuAverageSeconds=if ($stats.CpuAttempts) { $stats.CpuSeconds/$stats.CpuAttempts } else { 0 }
        $stats.PagesPerSecond=($stats.GpuPages+$stats.CpuPages)/[Math]::Max(0.000001,$stats.Seconds)
        if (-not $success) { Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]$stats
}
