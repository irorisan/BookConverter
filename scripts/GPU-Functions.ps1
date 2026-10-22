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

# CPU-only libavif decoding validates the sampled AVIFs independently of
# FFmpeg's AVIF decoder. Full PNG output is required, not just an AVIF header.
function Get-AvifDecodeArguments {
    param(
        [Parameter(Mandatory=$true)][string]$InputPath,
        [Parameter(Mandatory=$true)][string]$OutputPath
    )
    foreach ($path in @($InputPath,$OutputPath)) {
        if ($path.Contains('"')) { throw "Invalid AVIF verification path: $path" }
    }
    return ('"{0}" "{1}"' -f $InputPath,$OutputPath)
}

function Test-DecodedPng {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $stream=[IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 8) { return $false }
        $header=[byte[]]::new(8)
        [void]$stream.Read($header,0,8)
        return ([Convert]::ToHexString($header) -ceq '89504E470D0A1A0A')
    }
    finally { $stream.Dispose() }
}

function Invoke-CpuVerifyAvifSamples {
    param(
        [string[]]$Paths,
        [Parameter(Mandatory=$true)][string]$Avifdec,
        [Parameter(Mandatory=$true)][string]$ScratchDir,
        [string]$CancelFile,
        [ValidateRange(1,86400)][int]$TimeoutSeconds=300,
        [switch]$ReturnFailedPaths
    )
    if (-not $Paths -or $Paths.Count -eq 0) { return }
    if (-not (Test-Path -LiteralPath $Avifdec -PathType Leaf)) {
        throw "CPU AVIFデコーダーが見つかりません: $Avifdec"
    }

    $verifyDir=Join-Path $ScratchDir ('avif_verify_'+[Guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $verifyDir -ErrorAction Stop)
    $failures=[System.Collections.Generic.List[string]]::new()
    try {
        for ($i=0; $i -lt $Paths.Count; $i++) {
            if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { throw 'AVIF verification cancelled' }
            $path=$Paths[$i]
            $output=Join-Path $verifyDir ('decoded_{0:D6}.png' -f $i)
            $process=[Diagnostics.Process]::new()
            $started=$false
            $clock=[Diagnostics.Stopwatch]::StartNew()
            try {
                $process.StartInfo.FileName=$Avifdec
                $process.StartInfo.Arguments=Get-AvifDecodeArguments -InputPath $path -OutputPath $output
                $process.StartInfo.UseShellExecute=$false
                $process.StartInfo.CreateNoWindow=$true
                if (-not $process.Start()) { throw "CPU AVIFデコーダーを起動できません: $path" }
                $started=$true
                while (-not $process.WaitForExit(20)) {
                    if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { throw 'AVIF verification cancelled' }
                    if ($clock.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "AVIF verification timed out: $path" }
                }
                $code=$process.ExitCode
                if ($code -ne 0 -or -not (Test-DecodedPng -Path $output)) {
                    Write-Warning ("CPU avifdecでデコード失敗 (code {0}): {1}" -f $code,$path)
                    $failures.Add($path)
                }
            }
            finally {
                if ($started -and -not $process.HasExited) {
                    try { $process.Kill(); $process.WaitForExit() } catch { }
                }
                $process.Dispose()
                $clock.Stop()
                Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
            }
            if (($i+1) -eq $Paths.Count -or (($i+1) % 20) -eq 0) {
                Write-Host ("  CPU AVIF検証: {0}/{1} 枚" -f ($i+1),$Paths.Count) -ForegroundColor DarkCyan
            }
        }
    }
    finally { Remove-Item -LiteralPath $verifyDir -Recurse -Force -ErrorAction SilentlyContinue }

    if ($ReturnFailedPaths) { return $failures.ToArray() }
    if ($failures.Count -gt 0) {
        throw ("CPU AVIFデコード検証に失敗しました（{0}枚）: {1}" -f $failures.Count,($failures -join ', '))
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
