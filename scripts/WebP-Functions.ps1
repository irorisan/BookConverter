# CPU-only WebP; FFmpeg also decodes AVIF without a GPU or separate dwebp.
function Find-WebPFFmpeg {
    $candidates = @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/ffmpeg.exe'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'ffmpeg.exe')
    )
    $command = Get-Command 'ffmpeg.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $encoders = & $candidate -hide_banner -encoders 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -and $encoders -match '(?m)^\s*V[.A-Z ]+\s+libwebp\s') { return $candidate }
    }
    throw 'CPU WebP用FFmpeg（libwebp対応）が必要です。tools\ffmpeg.exe またはPATHに配置してください。'
}

function Get-WebPEncodeArguments {
    param([ValidateRange(30,95)][int]$Quality, [string]$InputPath, [string]$OutputPath)
    return ('-hide_banner -loglevel error -nostdin -y -hwaccel none -threads 1 -i "{0}" -map 0:v:0 -c:v libwebp -lossless 0 -quality {1} -compression_level 6 -threads 1 -frames:v 1 -f webp "{2}"' -f $InputPath, $Quality, $OutputPath)
}

function Test-WebPOutput {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $header = [byte[]]::new(12)
        if ($stream.Length -le 12 -or $stream.Read($header,0,12) -ne 12 -or
            [Text.Encoding]::ASCII.GetString($header,0,4) -ne 'RIFF' -or
            [Text.Encoding]::ASCII.GetString($header,8,4) -ne 'WEBP' -or
            [BitConverter]::ToUInt32($header,4) + 8L -ne $stream.Length) {
            throw "WebP出力が不正です: $Path"
        }
    } finally { $stream.Dispose() }
}

function Invoke-WebPEncode {
    param([object[]]$Entries, [string]$Encoder, [int]$Quality, [int]$Workers,
        [string]$TempDir, [string]$OutputName, [System.Collections.IDictionary]$StageTimes,
        [switch]$TrackProgress, [string]$CancelFile, [int]$TimeoutSeconds)
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    $running = [Collections.Generic.List[object]]::new()
    $next = 0
    $finished = 0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($finished -lt $Entries.Count) {
            if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { throw 'WebP変換をキャンセルしました' }
            while ($next -lt $Entries.Count -and $running.Count -lt $Workers) {
                $entry = $Entries[$next]
                $destination = Join-Path $TempDir ('image_{0:D6}.webp' -f $next)
                $info = [Diagnostics.ProcessStartInfo]::new()
                $info.FileName = $Encoder
                $info.Arguments = Get-WebPEncodeArguments -Quality $Quality -InputPath $entry.SourcePath -OutputPath $destination
                $info.UseShellExecute = $false
                $info.CreateNoWindow = $true
                $process = [Diagnostics.Process]::new()
                $process.StartInfo = $info
                try {
                    if (-not $process.Start()) { throw 'CPU WebPエンコーダーを起動できません' }
                } catch { $process.Dispose(); throw }
                $running.Add([pscustomobject]@{Process=$process; Entry=$entry; Destination=$destination; Timer=[Diagnostics.Stopwatch]::StartNew()})
                $next++
            }
            for ($i = $running.Count - 1; $i -ge 0; $i--) {
                $job = $running[$i]
                if (-not $job.Process.HasExited) {
                    if ($job.Timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "WebPエンコードがタイムアウトしました: $($job.Entry.EntryName)" }
                    continue
                }
                if ($job.Process.ExitCode -ne 0) { throw "WebP変換に失敗しました: $($job.Entry.EntryName)" }
                Test-WebPOutput -Path $job.Destination
                $job.Entry.SourcePath = $job.Destination
                $job.Entry.Length = [long](Get-Item -LiteralPath $job.Destination).Length
                $job.Entry | Add-Member -NotePropertyName EncodedBy -NotePropertyValue 'Cpu' -Force
                $job.Process.Dispose()
                $running.RemoveAt($i)
                $finished++
                if ($TrackProgress) { Write-MangaPageProgress -Completed $finished -Total $Entries.Count -Activity "WebP変換: $OutputName" }
            }
            if ($finished -lt $Entries.Count) { Start-Sleep -Milliseconds 20 }
        }
    } finally {
        foreach ($job in $running) {
            try { if (-not $job.Process.HasExited) { $job.Process.Kill($true); $job.Process.WaitForExit() } }
            finally { $job.Process.Dispose() }
        }
        if ($TrackProgress) { Write-MangaPageProgress -Activity 'WebP変換' -Done }
        $timer.Stop()
        if ($null -ne $StageTimes) { $StageTimes['WebP本変換'] += $timer.Elapsed }
    }
    return $finished
}

function Invoke-WebPVerify {
    param([object[]]$Entries, [string]$Encoder, [string]$CancelFile, [int]$TimeoutSeconds)
    foreach ($entry in $Entries) {
        Test-WebPOutput -Path $entry.SourcePath
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $Encoder
        $info.Arguments = '-hide_banner -loglevel error -nostdin -xerror -hwaccel none -threads 1 -i "{0}" -map 0:v:0 -frames:v 1 -f null NUL' -f $entry.SourcePath
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        $timer = [Diagnostics.Stopwatch]::StartNew()
        try {
            if (-not $process.Start()) { throw 'WebPデコード検証を開始できません' }
            while (-not $process.WaitForExit(100)) {
                if ($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'WebPデコード検証がタイムアウトしました' }
                if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { throw 'WebP変換をキャンセルしました' }
            }
            if ($process.ExitCode -ne 0) { throw "WebPデコード検証に失敗しました: $($entry.EntryName)" }
        } finally {
            try { if ($process.Id -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() } }
            finally { $process.Dispose() }
        }
    }
}
