# Official NVIDIA GPU encoder for BookConverter (PowerShell 7.6 on Windows).
# CPU avifenc remains available through the original BAT files.
# No silent CPU fallback on a failed GPU encode.

function Convert-GpuQualityToCq {
    param([Parameter(Mandatory=$true)][ValidateRange(30,95)][int]$Quality)
    # Quality 30..95 is BookConverter's search scale, NOT libavif-equivalent quality.
    # NVENC CQ runs backwards: a smaller CQ requests a higher quality.
    return [int][Math]::Round(50.0 - (($Quality - 30) * (35.0 / 65.0)))
}

function Get-GpuEncodeArguments {
    param(
        [Parameter(Mandatory=$true)][int]$Quality,
        [Parameter(Mandatory=$true)][string]$InputPath,
        [Parameter(Mandatory=$true)][string]$OutputPath
    )
    $cq = Convert-GpuQualityToCq -Quality $Quality
    # Explicit AVIF muxer; p7 is the fixed high-quality preset for GPU mode.
    return ('-hide_banner -loglevel error -nostdin -y -i "{0}" -c:v av1_nvenc -rc vbr -cq {1} -b:v 0 -preset p7 -tune hq -pix_fmt yuv420p -frames:v 1 -f avif "{2}"' -f $InputPath, $cq, $OutputPath)
}

function Find-FFmpegNvenc {
    $candidates = @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\ffmpeg.exe'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'ffmpeg.exe')
    )
    $command = Get-Command 'ffmpeg.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $encoders = & $candidate -hide_banner -encoders 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $encoders -notmatch '(?m)^\s*V[.A-Z ]+\s+av1_nvenc\b') { continue }
        $muxers = & $candidate -hide_banner -muxers 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $muxers -notmatch '(?m)^\s*E\s+avif\b') { continue }
        return $candidate
    }
    throw ('NVENC対応FFmpegが見つかりません。tools\ffmpeg.exe またはPATHに配置してください。' +
        ' 必要な機能: av1_nvenc encoder と avif muxer。CPU版は別BATから起動できます。')
}

# Select roughly one AVIF per ten pages plus the final AVIF. Include at
# least one output from each encoder backend present in the final volume.
function Select-AvifVerificationSamples {
    param([Parameter(Mandatory=$true)][object[]]$Entries)
    $avifs = @($Entries | Where-Object { [IO.Path]::GetExtension([string]$_.SourcePath) -eq '.avif' })
    if ($avifs.Count -eq 0) { return @() }
    $indexes = [System.Collections.Generic.SortedSet[int]]::new()
    for ($i=0; $i -lt $avifs.Count; $i+=10) { [void]$indexes.Add($i) }
    [void]$indexes.Add($avifs.Count-1)
    foreach ($backend in @('Gpu','Cpu')) {
        $first = -1
        $covered = $false
        for ($i=0; $i -lt $avifs.Count; $i++) {
            $encodedBy = if ($avifs[$i].PSObject.Properties['EncodedBy']) { [string]$avifs[$i].EncodedBy } else { '' }
            if ($encodedBy -ne $backend) { continue }
            if ($first -eq -1) { $first = $i }
            if ($indexes.Contains($i)) { $covered = $true; break }
        }
        if ($first -ge 0 -and -not $covered) { [void]$indexes.Add($first) }
    }
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($index in $indexes) { $paths.Add([string]$avifs[$index].SourcePath) }
    return $paths.ToArray()
}

# Decode every SELECTED AVIF (independent inputs and mapped streams) in a single
# FFmpeg process per bounded batch. Do not use stream copy: it bypasses decoding.
function Get-GpuVerifyArguments {
    param([Parameter(Mandatory=$true)][ValidateCount(1,8)][string[]]$Paths)
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('-hide_banner -loglevel error -nostdin -xerror -max_error_rate 0')
    foreach ($path in $Paths) {
        if ($path.Contains('"')) { throw "AVIF検証パスに引用符が含まれています: $path" }
        $parts.Add(('-i "{0}"' -f $path))
    }
    for ($i = 0; $i -lt $Paths.Count; $i++) {
        $parts.Add(('-map {0}:v:0' -f $i))
    }
    $parts.Add('-f null NUL')
    return ($parts -join ' ')
}

# A multi-stream failure alone does not prove any particular AVIF is broken.
# Run a bounded, independent one-file decode for each member of the failed batch.
function Invoke-FFmpegSingleAvifProbe {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$FFmpeg,
        [string]$CancelFile,
        [int]$TimeoutSeconds=0
    )
    $process=[Diagnostics.Process]::new()
    $clock=[Diagnostics.Stopwatch]::StartNew()
    try {
        $process.StartInfo.FileName=$FFmpeg
        $process.StartInfo.Arguments=Get-GpuVerifyArguments -Paths ([string[]]@($Path))
        $process.StartInfo.UseShellExecute=$false
        $process.StartInfo.CreateNoWindow=$true
        if (-not $process.Start()) { throw "AVIF単体検証プロセスを起動できません: $Path" }
        while (-not $process.WaitForExit(20)) {
            if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { throw 'AVIF verification cancelled' }
            if ($TimeoutSeconds -gt 0 -and $clock.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                throw 'AVIF verification timed out'
            }
        }
        return [int]$process.ExitCode
    }
    finally {
        if (-not $process.HasExited) {
            try { $process.Kill(); $process.WaitForExit() } catch { }
        }
        $process.Dispose()
        $clock.Stop()
    }
}

function Invoke-GpuVerifyAvifBatch {
    param(
        [string[]]$Paths,
        [Parameter(Mandatory=$true)][string]$FFmpeg,
        [ValidateRange(1,12)][int]$Workers = 8,
        [string]$CancelFile,
        [ValidateRange(0,86400)][int]$TimeoutSeconds=0,
        [switch]$ReturnFailedPaths
    )
    if (-not $Paths -or $Paths.Count -eq 0) { return }

    $batchSize=8
    $processLimit=[Math]::Min(2,$Workers)
    $avifdec=Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\avifdec.exe'
    $hasAvifdec=Test-Path -LiteralPath $avifdec -PathType Leaf
    $running=[System.Collections.Generic.List[object]]::new()
    $failures=[System.Collections.Generic.List[string]]::new()
    $next=0
    $verified=0
    try {
        while ($verified -lt $Paths.Count) {
            if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { throw 'AVIF verification cancelled' }
            if ($TimeoutSeconds -gt 0) {
                foreach ($job in $running) {
                    if (((Get-Date)-$job.Started).TotalSeconds -gt $TimeoutSeconds) {
                        throw 'AVIF verification timed out'
                    }
                }
            }
            while ($next -lt $Paths.Count -and $running.Count -lt $processLimit) {
                $last=[Math]::Min($Paths.Count,$next+$batchSize)-1
                $group=[string[]]@($Paths[$next..$last])
                $p=$null
                try {
                    $info=[Diagnostics.ProcessStartInfo]::new()
                    $info.FileName=$FFmpeg
                    $info.Arguments=Get-GpuVerifyArguments -Paths $group
                    $info.UseShellExecute=$false
                    $info.CreateNoWindow=$true
                    $p=[Diagnostics.Process]::new()
                    $p.StartInfo=$info
                    if (-not $p.Start()) { throw "AVIF検証プロセスを起動できません: $($group[0])" }
                    $running.Add([pscustomobject]@{Process=$p; Paths=$group; Started=(Get-Date)})
                    $p=$null
                }
                finally {
                    if ($null -ne $p) { $p.Dispose() }
                }
                $next=$last+1
            }

            $gotResult=$false
            for ($i=$running.Count-1; $i -ge 0; $i--) {
                $job=$running[$i]
                if (-not $job.Process.HasExited) { continue }
                $gotResult=$true
                $code=$job.Process.ExitCode
                $job.Process.Dispose()
                $running.RemoveAt($i)

                $invalid=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                if ($code -ne 0) {
                    Write-Warning ("AVIFバッチ検証失敗 (FFmpeg code {0}, {1}枚)。各画像を単体で再検証します。" -f $code,$job.Paths.Count)
                    foreach ($path in $job.Paths) {
                        $singleCode=Invoke-FFmpegSingleAvifProbe -Path $path -FFmpeg $FFmpeg -CancelFile $CancelFile -TimeoutSeconds $TimeoutSeconds
                        if ($singleCode -ne 0) {
                            [void]$invalid.Add($path)
                            Write-Warning ("AVIF単体デコード失敗 (FFmpeg code {0}): {1}" -f $singleCode,$path)
                        }
                    }
                    if ($invalid.Count -eq 0) {
                        Write-Warning 'AVIFバッチのみ失敗。単体検証は全枚成功したため、CPU再変換せず続行します。'
                    }
                }

                foreach ($path in $job.Paths) {
                    if ($invalid.Contains($path)) {
                        if (-not $failures.Contains($path)) { $failures.Add($path) }
                        $verified++
                        continue
                    }
                    # Independently decode a sampled file with libavif when present.
                    if ($hasAvifdec) {
                        $testPng=[IO.Path]::ChangeExtension($path,'.validated.png')
                        try {
                            $decodeCode=0
                            if ($TimeoutSeconds -gt 0) {
                                $decodeProcess=[Diagnostics.Process]::new()
                                $decodeClock=[Diagnostics.Stopwatch]::StartNew()
                                try {
                                    $decodeProcess.StartInfo.FileName=$avifdec
                                    $decodeProcess.StartInfo.Arguments='"{0}" "{1}"' -f $path,$testPng
                                    $decodeProcess.StartInfo.UseShellExecute=$false
                                    $decodeProcess.StartInfo.CreateNoWindow=$true
                                    if (-not $decodeProcess.Start()) { throw 'avifdec start failed' }
                                    while (-not $decodeProcess.WaitForExit(20)) {
                                        if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { throw 'avifdec cancelled' }
                                        if ($decodeClock.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'avifdec timed out' }
                                    }
                                    $decodeCode=$decodeProcess.ExitCode
                                }
                                finally {
                                    try { if (-not $decodeProcess.HasExited) { $decodeProcess.Kill(); $decodeProcess.WaitForExit() } } catch { }
                                    $decodeProcess.Dispose()
                                    $decodeClock.Stop()
                                }
                            }
                            else {
                                & $avifdec $path $testPng | Out-Null
                                $decodeCode=$LASTEXITCODE
                            }
                            if ($decodeCode -ne 0 -or -not (Test-Path -LiteralPath $testPng -PathType Leaf)) {
                                Write-Warning ("libavif単体デコード失敗 (code {0}): {1}" -f $decodeCode,$path)
                                if (-not $failures.Contains($path)) { $failures.Add($path) }
                            }
                        }
                        finally { Remove-Item -LiteralPath $testPng -Force -ErrorAction SilentlyContinue }
                    }
                    $verified++
                }
                if ($verified -eq $Paths.Count -or ($verified % 20) -eq 0) {
                    Write-Host ("  AVIF検証: {0}/{1} 枚" -f $verified,$Paths.Count) -ForegroundColor DarkCyan
                }
            }
            if (-not $gotResult) { Start-Sleep -Milliseconds 20 }
        }
    }
    finally {
        foreach ($job in $running) {
            try {
                if (-not $job.Process.HasExited) { $job.Process.Kill(); $job.Process.WaitForExit() }
            }
            catch { }
            finally { $job.Process.Dispose() }
        }
    }
    if ($ReturnFailedPaths) { return $failures.ToArray() }
    if ($failures.Count -gt 0) {
        throw ("AVIFデコード検証に失敗しました（単体で不適合 {0}枚）: {1}" -f $failures.Count,($failures -join ', '))
    }
}

# Pair corrupt generated AVIFs with their unmodified original page.
# This is a pure planner: caller decides whether/how to commit validated CPU files.
function Get-AvifCpuRecoveryPlan {
    param(
        [Parameter(Mandatory=$true)][object[]]$Entries,
        [Parameter(Mandatory=$true)][object[]]$OriginalEntries,
        [Parameter(Mandatory=$true)][string[]]$FailedPaths
    )
    if ($Entries.Count -ne $OriginalEntries.Count) { throw 'AVIF recovery page counts do not match' }
    $remaining=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $FailedPaths) { [void]$remaining.Add($path) }
    $plan=[System.Collections.Generic.List[object]]::new()
    for ($i=0; $i -lt $Entries.Count; $i++) {
        if (-not $remaining.Remove([string]$Entries[$i].SourcePath)) { continue }
        $original=$OriginalEntries[$i]
        if (-not $original.NeedsConversion) {
            throw ("元からあるAVIFなど、再変換対象外の画像はCPU再変換できません: {0}" -f $original.EntryName)
        }
        $plan.Add([pscustomobject]@{
            Index=$i
            Entry=[pscustomobject]@{
                SourcePath=[string]$original.SourcePath
                EntryName=[string]$original.EntryName
                Length=[long]$original.Length
                NeedsConversion=$true
                Extension=[string]$original.Extension
                EncodedBy=''
            }
        })
    }
    if ($remaining.Count -gt 0) { throw ('回復対象のAVIFが見つかりません: '+($remaining -join ', ')) }
    return $plan.ToArray()
}
