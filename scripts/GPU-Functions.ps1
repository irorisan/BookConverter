# Official NVIDIA GPU encoder for BookConverter (Windows PowerShell 5.1).
# CPU avifenc remains available through the original BAT files.
# No silent CPU fallback on a failed GPU encode.

function Convert-GpuQualityToCq {
    param([Parameter(Mandatory=$true)][ValidateRange(30,95)][int]$Quality)
    # Quality 30..95 is BookConverter's search scale, NOT libavif-equivalent quality.
    # NVENC CQ runs backwards: a smaller CQ requests a higher quality.
    return [int][Math]::Round(50.0 - (($Quality - 30) * (35.0 / 65.0)))
}

# Map Q30..95 to the existing NVENC CQ scale. Adjacent Q values may map
# to the same integer CQ, which makes additional quality probes redundant.
function Get-GpuDistinctQualityCandidate {
    param(
        [Parameter(Mandatory=$true)][int]$Low,
        [Parameter(Mandatory=$true)][int]$High,
        [int[]]$UsedCqs = @()
    )
    if ($Low -gt $High) { return $null }
    $mid = [int][Math]::Floor(($Low + $High) / 2)
    for ($offset = 0; $offset -le ($High - $Low); $offset++) {
        # On equal distance prefer higher Q, for quality-first selection.
        foreach ($candidate in @($mid + $offset, $mid - $offset)) {
            if ($candidate -lt $Low -or $candidate -gt $High) { continue }
            $cq = Convert-GpuQualityToCq -Quality $candidate
            if ($UsedCqs -notcontains $cq) { return [int]$candidate }
        }
    }
    return $null
}

function Get-GpuEncodeArguments {
    param(
        [Parameter(Mandatory=$true)][int]$Quality,
        [Parameter(Mandatory=$true)][string]$InputPath,
        [Parameter(Mandatory=$true)][string]$OutputPath
    )
    $cq = Convert-GpuQualityToCq -Quality $Quality
    # Explicit AVIF muxer; p7 is the fixed high-quality preset for GPU mode.
    return ('-hide_banner -loglevel error -y -i "{0}" -c:v av1_nvenc -rc vbr -cq {1} -b:v 0 -preset p7 -tune hq -pix_fmt yuv420p -frames:v 1 -f avif "{2}"' -f $InputPath, $cq, $OutputPath)
}

# Multiple independent AVIF outputs in one FFmpeg invocation.
# Four streams per process and at most twelve outstanding NVENC sessions.
function Get-GpuBatchProcessLimit {
    param(
        [Parameter(Mandatory=$true)][ValidateRange(1,12)][int]$Workers,
        [Parameter(Mandatory=$true)][ValidateRange(1,4)][int]$BatchSize
    )
    return [int][Math]::Min($Workers, [Math]::Floor(12 / $BatchSize))
}

function Get-GpuBatchEncodeArguments {
    param(
        [Parameter(Mandatory=$true)][ValidateCount(1,4)][object[]]$Jobs,
        [Parameter(Mandatory=$true)][ValidateRange(30,95)][int]$Quality
    )
    $cq = Convert-GpuQualityToCq -Quality $Quality
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('-hide_banner -loglevel error -nostdin -y')
    foreach ($job in $Jobs) {
        $inputPath = [string]$job.InputPath
        if ($inputPath.Contains('"')) { throw "Invalid FFmpeg input path: $inputPath" }
        $parts.Add(('-i "{0}"' -f $inputPath))
    }
    for ($i = 0; $i -lt $Jobs.Count; $i++) {
        $outputPath = [string]$Jobs[$i].OutputPath
        if ($outputPath.Contains('"')) { throw "Invalid FFmpeg output path: $outputPath" }
        # Output options are scoped to the next output. Repeat all encode
        # settings per stream; AVIF muxer accepts only one color stream.
        $parts.Add(('-map {0}:v:0 -c:v av1_nvenc -rc vbr -cq {1} -b:v 0 -preset p7 -tune hq -pix_fmt yuv420p -frames:v 1 -f avif "{2}"' -f $i, $cq, $outputPath))
    }
    return ($parts -join ' ')
}

# The GPU multi-output path is enabled explicitly for full conversion first;
# representative quality samples keep the existing single-page path until phase 2.
function Invoke-GpuEncodeBatch {
    param(
        [Parameter(Mandatory=$true)][object[]]$Entries,
        [Parameter(Mandatory=$true)][string]$FFmpeg,
        [Parameter(Mandatory=$true)][ValidateRange(30,95)][int]$Quality,
        [Parameter(Mandatory=$true)][ValidateRange(1,12)][int]$Workers,
        [Parameter(Mandatory=$true)][string]$TempDir,
        [Parameter(Mandatory=$true)][string]$OutputName,
        [string]$Decoder
    )
    if ($Entries.Count -eq 0) { return }
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    $batchSize = 4
    $processLimit = Get-GpuBatchProcessLimit -Workers $Workers -BatchSize $batchSize
    $running = [System.Collections.Generic.List[object]]::new()
    $outputs = [System.Collections.Generic.List[string]]::new()
    $next = 0
    $finished = 0
    $activity = "NVENCバッチ変換: $OutputName"
    Write-Progress -Id 2 -ParentId 1 -Activity $activity -Status "0 / $($Entries.Count)枚" -PercentComplete 0
    try {
        while ($finished -lt $Entries.Count) {
            while ($running.Count -lt $processLimit -and $next -lt $Entries.Count) {
                $end = [Math]::Min($Entries.Count, $next + $batchSize)
                $pages = [System.Collections.Generic.List[object]]::new()
                $process = $null
                try {
                    for ($j = $next; $j -lt $end; $j++) {
                        $entry = $Entries[$j]
                        $basename = 'image_{0:D6}' -f ($j + 1)
                        $staged = Join-Path $TempDir ($basename + $entry.Extension)
                        $destination = Join-Path $TempDir ($basename + '.avif')
                        $intermediate = $null
                        # Stage under ASCII-only names, as in the single-image path.
                        Copy-Item -LiteralPath $entry.SourcePath -Destination $staged -Force
                        $pages.Add([pscustomobject]@{
                            Entry = $entry
                            InputPath = $staged
                            OutputPath = $destination
                            Staged = $staged
                            Intermediate = $null
                        })
                        if ($entry.Extension -eq '.webp') {
                            if ([string]::IsNullOrWhiteSpace($Decoder)) { throw 'WebP入力にはdwebp.exeが必要です' }
                            $intermediate = Join-Path $TempDir ($basename + '.png')
                            & $Decoder -quiet $staged -o $intermediate | Out-Null
                            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $intermediate -PathType Leaf)) {
                                throw "WebP展開に失敗しました: $($entry.EntryName)"
                            }
                            $pages[$pages.Count - 1].InputPath = $intermediate
                            $pages[$pages.Count - 1].Intermediate = $intermediate
                        }
                    }
                    $info = New-Object System.Diagnostics.ProcessStartInfo
                    $info.FileName = $FFmpeg
                    $info.Arguments = Get-GpuBatchEncodeArguments -Jobs $pages.ToArray() -Quality $Quality
                    $info.UseShellExecute = $false
                    $info.CreateNoWindow = $true
                    $process = New-Object System.Diagnostics.Process
                    $process.StartInfo = $info
                    if (-not $process.Start()) { throw "NVENCバッチを起動できません: $($pages[0].Entry.EntryName)" }
                    $running.Add([pscustomobject]@{ Process = $process; Pages = $pages.ToArray() })
                    $process = $null
                    $next = $end
                }
                catch {
                    if ($null -ne $process) {
                        try {
                            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
                        }
                        catch { }
                        finally { $process.Dispose() }
                    }
                    foreach ($page in $pages) {
                        Remove-Item -LiteralPath $page.Staged -Force -ErrorAction SilentlyContinue
                        if ($page.Intermediate) {
                            Remove-Item -LiteralPath $page.Intermediate -Force -ErrorAction SilentlyContinue
                        }
                    }
                    throw
                }
            }
            $gotResult = $false
            for ($i = $running.Count - 1; $i -ge 0; $i--) {
                $job = $running[$i]
                if (-not $job.Process.HasExited) { continue }
                $gotResult = $true
                $code = $job.Process.ExitCode
                $job.Process.Dispose()
                $running.RemoveAt($i)
                if ($code -ne 0) {
                    throw ('NVENCバッチ変換失敗: FFmpeg code {0} / {1}' -f $code, (($job.Pages | ForEach-Object { $_.Entry.EntryName }) -join ', '))
                }
                foreach ($page in $job.Pages) {
                    Test-AvifOutput -Path $page.OutputPath
                    $page.Entry.SourcePath = $page.OutputPath
                    $page.Entry.Length = [long](Get-Item -LiteralPath $page.OutputPath).Length
                    $outputs.Add($page.OutputPath)
                    Remove-Item -LiteralPath $page.Staged -Force
                    if ($page.Intermediate) { Remove-Item -LiteralPath $page.Intermediate -Force }
                    $finished++
                }
                Write-Progress -Id 2 -ParentId 1 -Activity $activity -Status "$finished / $($Entries.Count)枚" -PercentComplete ([int](100 * $finished / $Entries.Count))
            }
            if (-not $gotResult) { Start-Sleep -Milliseconds 20 }
        }
    }
    finally {
        foreach ($job in $running) {
            try {
                if (-not $job.Process.HasExited) {
                    $job.Process.Kill()
                    $job.Process.WaitForExit()
                }
            }
            catch { }
            finally { $job.Process.Dispose() }
        }
        Write-Progress -Id 2 -ParentId 1 -Activity $activity -Completed
    }
    return $outputs.ToArray()
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

# Decode every AVIF (independent inputs and mapped streams) in a single FFmpeg
# process for each bounded batch. Do not use stream copy: it bypasses decoding.
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

function Invoke-GpuVerifyAvifBatch {
    param(
        [string[]]$Paths,
        [Parameter(Mandatory=$true)][string]$FFmpeg,
        [ValidateRange(1,12)][int]$Workers = 8
    )
    if (-not $Paths -or $Paths.Count -eq 0) { return }

    # 8 independent AVIF streams per invocation, with at most 2 concurrent
    # FFmpeg processes to avoid excessive decoder memory and thread counts.
    $batchSize = 8
    $processLimit = [Math]::Min(2, $Workers)
    $avifdec = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\avifdec.exe'
    $hasAvifdec = Test-Path -LiteralPath $avifdec -PathType Leaf
    $running = [System.Collections.Generic.List[object]]::new()
    $next = 0
    $verified = 0
    try {
        while ($verified -lt $Paths.Count) {
            while ($next -lt $Paths.Count -and $running.Count -lt $processLimit) {
                $last = [Math]::Min($Paths.Count, $next + $batchSize) - 1
                $group = [string[]]@($Paths[$next..$last])
                $p = $null
                try {
                    $info = New-Object System.Diagnostics.ProcessStartInfo
                    $info.FileName = $FFmpeg
                    $info.Arguments = Get-GpuVerifyArguments -Paths $group
                    $info.UseShellExecute = $false
                    $info.CreateNoWindow = $true
                    $p = New-Object System.Diagnostics.Process
                    $p.StartInfo = $info
                    if (-not $p.Start()) { throw "AVIF検証プロセスを起動できません: $($group[0])" }
                    $running.Add([pscustomobject]@{ Process = $p; Paths = $group })
                    $p = $null
                }
                finally {
                    if ($null -ne $p) { $p.Dispose() }
                }
                $next = $last + 1
            }

            $gotResult = $false
            for ($i = $running.Count - 1; $i -ge 0; $i--) {
                $job = $running[$i]
                if (-not $job.Process.HasExited) { continue }
                $gotResult = $true
                $code = $job.Process.ExitCode
                $job.Process.Dispose()
                $running.RemoveAt($i)
                if ($code -ne 0) {
                    throw ("AVIFデコード検証に失敗しました: FFmpeg code {0} / 対象 {1}" -f $code, ($job.Paths -join ', '))
                }

                foreach ($path in $job.Paths) {
                    # Keep optional independent libavif validation for every page.
                    if ($hasAvifdec) {
                        $testPng = [IO.Path]::ChangeExtension($path, '.validated.png')
                        try {
                            & $avifdec $path $testPng | Out-Null
                            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $testPng -PathType Leaf)) {
                                throw "libavifによるデコード検証に失敗しました: $path"
                            }
                        }
                        finally {
                            Remove-Item -LiteralPath $testPng -Force -ErrorAction SilentlyContinue
                        }
                    }
                    $verified++
                }
                if ($verified -eq $Paths.Count -or ($verified % 20) -eq 0) {
                    Write-Host ("  AVIF検証: {0}/{1} 枚" -f $verified, $Paths.Count) -ForegroundColor DarkCyan
                }
            }
            if (-not $gotResult) { Start-Sleep -Milliseconds 20 }
        }
    }
    finally {
        foreach ($job in $running) {
            try {
                if (-not $job.Process.HasExited) {
                    $job.Process.Kill()
                    $job.Process.WaitForExit()
                }
            }
            catch { }
            finally { $job.Process.Dispose() }
        }
    }
}
