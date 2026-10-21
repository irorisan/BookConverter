# Official NVIDIA GPU encoder for BookConverter (Windows PowerShell 5.1).
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
    return ('-hide_banner -loglevel error -y -i "{0}" -c:v av1_nvenc -rc vbr -cq {1} -b:v 0 -preset p7 -tune hq -pix_fmt yuv420p -frames:v 1 -f avif "{2}"' -f $InputPath, $cq, $OutputPath)
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

function Invoke-GpuVerifyAvifBatch {
    param(
        [string[]]$Paths,
        [Parameter(Mandatory=$true)][string]$FFmpeg,
        [ValidateRange(1,12)][int]$Workers = 8
    )
    if (-not $Paths -or $Paths.Count -eq 0) { return }
    $running = [System.Collections.Generic.List[object]]::new()
    $next = 0
    $verified = 0
    try {
        while ($verified -lt $Paths.Count) {
            while ($next -lt $Paths.Count -and $running.Count -lt $Workers) {
                $path = $Paths[$next]
                $p = $null
                try {
                    $info = New-Object System.Diagnostics.ProcessStartInfo
                    $info.FileName = $FFmpeg
                    $info.Arguments = '-hide_banner -loglevel error -i "{0}" -frames:v 1 -f null NUL' -f $path
                    $info.UseShellExecute = $false
                    $info.CreateNoWindow = $true
                    $p = New-Object System.Diagnostics.Process
                    $p.StartInfo = $info
                    if (-not $p.Start()) { throw "AVIF検証プロセスを起動できません: $path" }
                    $running.Add([pscustomobject]@{ Process=$p; Path=$path })
                    $p = $null
                }
                finally { if ($null -ne $p) { $p.Dispose() } }
                $next++
            }
            $gotResult = $false
            for ($i = $running.Count - 1; $i -ge 0; $i--) {
                $job = $running[$i]
                if (-not $job.Process.HasExited) { continue }
                $gotResult = $true
                $code = $job.Process.ExitCode
                $job.Process.Dispose()
                $running.RemoveAt($i)
                if ($code -ne 0) { throw "AVIFデコード検証に失敗しました: $($job.Path) (FFmpeg code $code)" }
                # Independent libavif decode validation if avifdec was installed.
                $avifdec = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\avifdec.exe'
                if (Test-Path -LiteralPath $avifdec -PathType Leaf) {
                    $testPng = [IO.Path]::ChangeExtension($job.Path, '.validated.png')
                    try {
                        & $avifdec $job.Path $testPng | Out-Null
                        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $testPng -PathType Leaf)) {
                            throw "libavifによるデコード検証に失敗しました: $($job.Path)"
                        }
                    }
                    finally { Remove-Item -LiteralPath $testPng -Force -ErrorAction SilentlyContinue }
                }
                $verified++
                if ($verified -eq $Paths.Count -or ($verified % 20) -eq 0) {
                    Write-Host ("  AVIF検証: {0}/{1} 枚" -f $verified, $Paths.Count) -ForegroundColor DarkCyan
                }
            }
            if (-not $gotResult) { Start-Sleep -Milliseconds 50 }
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
