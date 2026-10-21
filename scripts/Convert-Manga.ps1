param(
    [switch]$GPU,
    [ValidateSet('Legacy','GPU','Hybrid')][string]$ConversionMode='Legacy',
    [ValidateRange(1,12)][int]$GpuWorkers=12,
    [ValidateRange(1,4)][int]$CpuWorkers=4,
    [string]$ReportDirectory,
    [string]$CancelFile,
    [ValidateRange(1,86400)][int]$EncoderTimeoutSeconds=300,
    [switch]$Magazine,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$DroppedPaths
)

$ErrorActionPreference = 'Stop'
if ($ConversionMode -in @('GPU','Hybrid')) { $GPU = $true }
$script:ExperimentFailed=$false
$script:CpuEncoder = $null
$script:HybridCpuQuality = 95
$script:EncodePasses = [System.Collections.Generic.List[object]]::new()
# Redirected smoke tests and pasted Japanese paths use UTF-8 on both streams.
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ImageExtensions = @('.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.avif')
$ArchiveExtensions = @('.zip', '.cbz', '.rar', '.epub')
$OutputFolderName = 'avif変換cbz'
. (Join-Path $PSScriptRoot 'Convert-Manga-Epub.ps1')
. (Join-Path $PSScriptRoot 'Convert-Manga-Progress.ps1')
. (Join-Path $PSScriptRoot 'Convert-Manga-Input.ps1')
. (Join-Path $PSScriptRoot 'Convert-Manga-Zip.ps1')
# PowerShell 1MB means 1MiB (1,048,576 bytes).
$CopyThresholdBytes = [long](60 * 1MB)
$MaxTargetBytes = [long](70 * 1MB)
# Quality selection targets 68 MiB: 2 MiB headroom below the 70 MiB limit.
$SampleSafetyBytes = [long](2 * 1MB)

function Get-VolumeInfo {
    param([string]$BaseName, [string]$ParentTitle = '')

    # Allow both traditional volume names (15巻 / v15 / vol.15) and
    # bracketed numbers such as （１５） / (15) / 作品名（１５）.
    # Preserve the title exactly; normalize only the detected volume number.
    $numberPattern = '[0-9０-９]+(?:[.．][0-9０-９]+)?[a-zA-Zａ-ｚＡ-Ｚ]?'
    $namedVolumePattern = "(?:(?:第\s*)?$numberPattern\s*巻|(?:v|vol(?:ume)?\.?)\s*$numberPattern)"
    $bracketVolumePattern = "[（(]\s*(?:$namedVolumePattern|$numberPattern)\s*[）)]"
    $volumePattern = "(?:$bracketVolumePattern|$namedVolumePattern)"
    # Some publisher EPUBs append credits after a volume number, for example:
    # 葬送のフリーレン（１） - 山田鐘人 & アベツカサ.epub
    # Match credits only after an explicit spaced dash so titles remain intact.
    $creditsTailPattern = '(?:\s+[-－–—]\s+.+)?'

    $title = ''
    $volumeToken = ''
    if ($BaseName -match "^(?<suffix>$volumePattern)$creditsTailPattern$") {
        # If the filename is just a volume, use the containing series folder.
        if ([string]::IsNullOrWhiteSpace($ParentTitle)) { return $null }
        $title = $ParentTitle.Trim()
        $volumeToken = $Matches['suffix']
    }
    elseif ($BaseName -match "^(?<title>.+?)\s*(?:[+＋_-]\s*)?(?<suffix>$volumePattern)$creditsTailPattern$") {
        $title = $Matches['title'].Trim()
        $volumeToken = $Matches['suffix']
    }
    elseif ($BaseName -match "^(?<title>.+)_(?<suffix>$numberPattern)$") {
        # Site-suffixed manga names such as Manga-Zip.info_10 use '_10'
        # as the volume marker. Only the manga BAT invokes this parser.
        $title = $Matches['title'].Trim()
        $volumeToken = $Matches['suffix']
    }
    else { return $null }

    if ([string]::IsNullOrWhiteSpace($title)) { return $null }
    # Compatibility normalization converts fullwidth １５, ．, ｂ to 15, ., b.
    # Do not normalize the work title or the file path.
    $normalizedToken = $volumeToken.Normalize([Text.NormalizationForm]::FormKC)
    $number = [regex]::Match($normalizedToken, '[0-9]+(?:\.[0-9]+)?[a-zA-Z]?')
    if (-not $number.Success) { return $null }
    return [pscustomobject]@{ Title = $title; Volume = $number.Value }
}

# Prevent accidentally packaging an entire series/library as one CBZ.
# Non-numbered folders count as one-shot books only when their DIRECT children
# contain images and there are no volume subfolders or archive children.
function Test-StandaloneImageFolder {
    param([System.IO.DirectoryInfo]$Folder)

    $hasDirectImages = $false
    foreach ($child in @(Get-ChildItem -LiteralPath $Folder.FullName -Force)) {
        if ($child.PSIsContainer) { return $false }
        if ($child.Extension.ToLowerInvariant() -in $ArchiveExtensions) { return $false }
        if ($child.Extension.ToLowerInvariant() -in $ImageExtensions -and
            $child.Name -notlike '._*') {
            $hasDirectImages = $true
        }
    }
    return $hasDirectImages
}

function Add-MangaItem {
    param([System.IO.FileSystemInfo]$InputItem, [string]$ParentTitle = '')

    # 二重変換防止: 出力先のAVIF済みCBZを再入力対象にしない。
    if (-not $InputItem.PSIsContainer -and $InputItem.Directory.Name -eq $OutputFolderName) {
        return $false
    }

    if (-not $InputItem.PSIsContainer -and
        $InputItem.Extension.ToLowerInvariant() -notin $ArchiveExtensions) {
        return $false
    }

    $base = if ($InputItem.PSIsContainer) {
        $InputItem.Name
    } else {
        [IO.Path]::GetFileNameWithoutExtension($InputItem.Name)
    }

    # The BAT entrance, not the volume-token heuristic, selects the mode.
    $info = $null
    if (-not $script:Magazine) {
        $info = Get-VolumeInfo -BaseName $base -ParentTitle $ParentTitle
        if ($null -eq $info -and [string]::IsNullOrWhiteSpace($ParentTitle)) {
            # A filename containing only v100b may obtain its title from its parent.
            $fallbackTitle = if ($InputItem.PSIsContainer) { $InputItem.Parent.Name } else { $InputItem.Directory.Name }
            $info = Get-VolumeInfo -BaseName $base -ParentTitle $fallbackTitle
        }
    }
    $isStandalone = [bool]$script:Magazine
    if ($null -eq $info) {
        # Bare folders are books only if pages are direct children.
        if ($InputItem.PSIsContainer -and -not (Test-StandaloneImageFolder -Folder $InputItem)) {
            return $false
        }
        $info = [pscustomobject]@{ Title = $base.Trim(); Volume = '' }
    }
    if (-not (Test-SafeTitle -Name $info.Title)) {
        Write-Warning "書名として使えない名前です: $base"
        return $false
    }

    $full = $InputItem.FullName
    if ($Seen.Add($full)) {
        $Items.Add([pscustomobject]@{
            Title       = $info.Title
            SourceBase  = $base.Trim()
            Volume      = $info.Volume
            IsStandalone = [bool]$isStandalone
            FullName    = $full
            OutputDir   = if ($InputItem.PSIsContainer) { $InputItem.Parent.FullName } else { $InputItem.DirectoryName }
            IsDirectory = [bool]$InputItem.PSIsContainer
        })
    }
    return $true
}

function Scan-Container {
    param([System.IO.DirectoryInfo]$Container)

    if ($Container.Name -eq $OutputFolderName) {
        Write-Warning 'AVIF変換後の出力フォルダは入力対象から除外します。'
        return
    }

    # The dropped folder is a single volume folder: handle directly.
    if (Add-MangaItem -InputItem $Container) { return }

    # Otherwise, treat it as a manga library or a series folder.
    $children = @(Get-ChildItem -LiteralPath $Container.FullName -Force)
    foreach ($child in $children) {
        if ($child.PSIsContainer -and $child.Name -eq $OutputFolderName) { continue }
        if (-not $child.PSIsContainer -and
            $child.Extension.ToLowerInvariant() -notin $ArchiveExtensions) {
            continue
        }

        if (Add-MangaItem -InputItem $child -ParentTitle $Container.Name) {
            continue
        }

        # One more level: 漫画/シリーズ名/50巻, etc.
        if ($child.PSIsContainer) {
            foreach ($grandchild in @(Get-ChildItem -LiteralPath $child.FullName -Force)) {
                if ($grandchild.PSIsContainer -and $grandchild.Name -eq $OutputFolderName) { continue }
                if (-not $grandchild.PSIsContainer -and
                    $grandchild.Extension.ToLowerInvariant() -notin $ArchiveExtensions) {
                    continue
                }
                if (-not (Add-MangaItem -InputItem $grandchild -ParentTitle $child.Name)) {
                    Write-Warning "変換対象として認識できないため除外: $($grandchild.FullName)"
                }
            }
        }
        else {
            Write-Warning "変換対象として認識できないため除外: $($child.FullName)"
        }
    }
}

function Find-WinRAR {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'WinRAR\WinRAR.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'WinRAR\WinRAR.exe')
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $cmd = Get-Command 'WinRAR.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'WinRAR.exeが見つかりません。通常のインストール先かPATHを確認してください。'
}

function Find-OrInstall-Avifenc {
    $candidates = @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\avifenc.exe'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'avifenc.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $command = Get-Command 'avifenc.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $apiUrl = 'https://api.github.com/repos/AOMediaCodec/libavif/releases/latest'
    $releasePage = 'https://github.com/AOMediaCodec/libavif/releases'
    $toolsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools'
    $target = Join-Path $toolsDir 'avifenc.exe'
    $downloadDir = Join-Path ([IO.Path]::GetTempPath()) ('AvifencSetup_' + [Guid]::NewGuid().ToString('N'))
    try {
        Write-Host "`navifenc.exeがないため、AOMedia公式libavifの最新Windows x64版を取得します。" -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = 'Convert-Manga' }
        $release = Invoke-RestMethod -Headers $headers -Uri $apiUrl -TimeoutSec 120
        if ($null -eq $release -or $null -eq $release.assets) {
            throw 'GitHub APIからリリース情報を取得できませんでした'
        }
        # libavif公式はwindows-artifacts.zipという名前で配布している。
        $asset = @($release.assets | Where-Object {
            $_.name -eq 'windows-artifacts.zip'
        } | Select-Object -First 1)
        if ($asset.Count -eq 0) {
            throw '最新リリースに公式のwindows-artifacts.zipが見つかりません'
        }
        $archivePath = Join-Path $downloadDir $asset[0].name
        Invoke-WebRequest -Headers $headers -Uri $asset[0].browser_download_url -OutFile $archivePath -UseBasicParsing -TimeoutSec 300

        $extractDir = Join-Path $downloadDir 'extracted'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force
        $exe = Get-ChildItem -LiteralPath $extractDir -Filter 'avifenc.exe' -Recurse -File |
            Select-Object -First 1
        if ($null -eq $exe) { throw '取得したZIP内にavifenc.exeが見つかりません' }

        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
        Copy-Item -LiteralPath $exe.FullName -Destination $target -Force
        Get-ChildItem -LiteralPath $exe.DirectoryName -Filter '*.dll' -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $toolsDir $_.Name) -Force
        }
        Write-Host "avifenc.exeを配置しました: $target" -ForegroundColor Green
        return $target
    }
    catch {
        throw ('avifenc.exeの自動導入に失敗しました: ' + $_.Exception.Message +
            "`n公式リリース: $releasePage" +
            "`nリリースZIPからavifenc.exeを取り出し、tools\avifenc.exe に手動配置して再実行してください。")
    }
    finally {
        Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Google公式のWebPデコーダー。既存CBZ内に.webpがある場合だけ導入する。
# dwebpはWebPをPNGへ展開し、そのPNGをavifencへ渡すためだけに使用する。
function Find-OrInstall-Dwebp {
    $candidates = @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\dwebp.exe'),
        (Join-Path $PSScriptRoot 'dwebp.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command 'dwebp.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $url = 'https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0-windows-x64.zip'
    $toolsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools'
    $target = Join-Path $toolsDir 'dwebp.exe'
    $downloadDir = Join-Path ([IO.Path]::GetTempPath()) ('DwebpSetup_' + [Guid]::NewGuid().ToString('N'))
    try {
        Write-Host "`nCBZ内のWebP画像を変換するため、Google公式dwebp.exeを取得します。" -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $archive = Join-Path $downloadDir 'libwebp-windows-x64.zip'
        Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing -TimeoutSec 120
        $extractDir = Join-Path $downloadDir 'extracted'
        Expand-Archive -LiteralPath $archive -DestinationPath $extractDir -Force
        $exe = Get-ChildItem -LiteralPath $extractDir -Filter 'dwebp.exe' -File -Recurse | Select-Object -First 1
        if ($null -eq $exe) { throw '公式ZIP内にdwebp.exeがありません' }
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
        Copy-Item -LiteralPath $exe.FullName -Destination $target -Force
        Get-ChildItem -LiteralPath $exe.DirectoryName -Filter '*.dll' -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $toolsDir $_.Name) -Force
        }
        return $target
    }
    catch {
        throw ('dwebp.exeの自動取得に失敗しました: ' + $_.Exception.Message +
            "`nGoogle公式配布: $url" +
            "`n手動でtools\dwebp.exeに配置して再実行してください。")
    }
    finally {
        Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-AvifOutput {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "AVIF出力が見つかりません: $Path"
    }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $header = New-Object byte[] 16
        if ($stream.Read($header, 0, $header.Length) -lt 12 -or
            [Text.Encoding]::ASCII.GetString($header, 4, 4) -ne 'ftyp' -or
            [Text.Encoding]::ASCII.GetString($header, 8, 4) -ne 'avif') {
            throw "AVIFファイルの形式確認に失敗しました: $Path"
        }
    }
    finally { $stream.Dispose() }
}

. (Join-Path $PSScriptRoot 'GPU-Functions.ps1')
. (Join-Path $PSScriptRoot 'Hybrid-Functions.ps1')

function Invoke-ParallelAvif {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$Entries,
        [Parameter(Mandatory = $true)][string]$Encoder,
        [string]$Decoder,
        [Parameter(Mandatory = $true)][int]$Quality,
        [Parameter(Mandatory = $true)][ValidateRange(1, 16)][int]$Workers,
        [Parameter(Mandatory = $true)][string]$TempDir,
        [Parameter(Mandatory = $true)][string]$OutputName,
        [System.Collections.IDictionary]$StageTimes,
        [switch]$FullPass,
        [switch]$CpuProbe
    )

    $pending = @($Entries | Where-Object { $_.NeedsConversion })
    if ($pending.Count -eq 0) { return 0 }
    if (@($pending | Where-Object { $_.Extension -eq '.webp' }).Count -gt 0 -and
        [string]::IsNullOrWhiteSpace($Decoder)) {
        throw 'WebP画像の入力にはdwebp.exeが必要です'
    }
    if ($ConversionMode -in @('GPU','Hybrid')) {
        $g = $GpuWorkers
        $c = if ($ConversionMode -eq 'Hybrid' -and $FullPass) { $CpuWorkers } else { 0 }
        $cpuQ = $script:HybridCpuQuality
        if ($CpuProbe) { $g=0; $c=$CpuWorkers; $cpuQ=$Quality }
        $encodeTimer = [Diagnostics.Stopwatch]::StartNew()
        try {
            $pass = Invoke-HybridEncode -Entries $pending -FFmpeg $Encoder -Avifenc $script:CpuEncoder `
                -Decoder $Decoder -GpuQuality $Quality -CpuQuality $cpuQ -GpuWorkers $g -CpuWorkers $c `
                -TempDir $TempDir -CancelFile $CancelFile -TimeoutSeconds $EncoderTimeoutSeconds
            $pass | Add-Member -NotePropertyName Phase -NotePropertyValue $(if ($FullPass) {'Full'} else {'Sample'})
            $script:EncodePasses.Add($pass)
        } catch {
            if ($_.Exception.Data.Contains('HybridMetrics')) {
                $pass=[pscustomobject]$_.Exception.Data['HybridMetrics']
                $pass | Add-Member -NotePropertyName Phase -NotePropertyValue $(if ($FullPass) {'Full'} else {'Sample'})
                $script:EncodePasses.Add($pass)
            }
            throw
        } finally {
            $encodeTimer.Stop()
            if ($null -ne $StageTimes) { $StageTimes['AVIF本変換'] += $encodeTimer.Elapsed }
        }
        # Each output has already passed the encoder exit-code and AVIF header checks.
        # Sample candidates are size probes only. All final AVIFs, including reused
        # samples, are fully decoded in Invoke-MangaBatch before the CBZ is saved.
        return $pending.Count
    }
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    $running = [System.Collections.Generic.List[object]]::new()
    $gpuVerifyPaths = [System.Collections.Generic.List[string]]::new()
    $next = 0
    $finished = 0
    $activity = "AVIF並列変換: $OutputName"
    Write-Progress -Id 2 -ParentId 1 -Activity $activity -Status "0 / $($pending.Count)枚（並列数 $Workers）" -PercentComplete 0

    $encodeTimer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while ($finished -lt $pending.Count) {
            while ($running.Count -lt $Workers -and $next -lt $pending.Count) {
                $entry = $pending[$next]
                $asciiBase = 'image_{0:D6}' -f ($next + 1)
                $staged = Join-Path $TempDir ($asciiBase + $entry.Extension)
                $destination = Join-Path $TempDir ($asciiBase + '.avif')
                $pngIntermediate = $null

                # dwebp / avifencのUnicodeパス問題を回避するため、一時名はASCIIにする。
                Copy-Item -LiteralPath $entry.SourcePath -Destination $staged -Force
                $process = $null
                try {
                    $avifInput = $staged
                    if ($entry.Extension -eq '.webp') {
                        $pngIntermediate = Join-Path $TempDir ($asciiBase + '.png')
                        # WebPからPNGへ可逆展開してからAVIFに圧縮する。
                        & $Decoder -quiet $staged -o $pngIntermediate | Out-Null
                        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $pngIntermediate -PathType Leaf)) {
                            throw "dwebp.exeによるWebP展開に失敗しました: $($entry.EntryName)"
                        }
                        $avifInput = $pngIntermediate
                    }

                    $info = New-Object System.Diagnostics.ProcessStartInfo
                    $info.FileName = $Encoder
                    if ($GPU) {
                        $info.Arguments = Get-GpuEncodeArguments -Quality $Quality -InputPath $avifInput -OutputPath $destination
                    }
                    else {
                        $info.Arguments = '-q {0} -s 6 -j 1 "{1}" "{2}"' -f $Quality, $avifInput, $destination
                    }
                    $info.UseShellExecute = $false
                    $info.CreateNoWindow = $true
                    $process = New-Object System.Diagnostics.Process
                    $process.StartInfo = $info
                    if (-not $process.Start()) {
                        throw "avifenc.exeを起動できません: $($entry.EntryName)"
                    }
                    $running.Add([pscustomobject]@{
                        Process     = $process
                        Entry       = $entry
                        Staged      = $staged
                        Intermediate= $pngIntermediate
                        Destination = $destination
                    })
                    $process = $null
                }
                catch {
                    if ($null -ne $process) {
                        try {
                            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
                        }
                        catch { }
                        $process.Dispose()
                    }
                    Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
                    if ($null -ne $pngIntermediate) {
                        Remove-Item -LiteralPath $pngIntermediate -Force -ErrorAction SilentlyContinue
                    }
                    throw
                }
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
                if ($code -ne 0) {
                    throw "avifenc.exeでの変換に失敗しました（終了コード: $code）: $($job.Entry.EntryName)"
                }
                Test-AvifOutput -Path $job.Destination
                if ($GPU) { $gpuVerifyPaths.Add($job.Destination) }
                $job.Entry.SourcePath = $job.Destination
                $job.Entry.Length = [long](Get-Item -LiteralPath $job.Destination).Length
                Remove-Item -LiteralPath $job.Staged -Force
                if ($null -ne $job.Intermediate) {
                    Remove-Item -LiteralPath $job.Intermediate -Force
                }
                $finished++
                Write-Progress -Id 2 -ParentId 1 -Activity $activity -Status "$finished / $($pending.Count)枚（並列数 $Workers）" -PercentComplete ([int](100 * $finished / $pending.Count))
            }
            if (-not $gotResult) { Start-Sleep -Milliseconds $(if ($GPU) { 20 } else { 120 }) }
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
        $encodeTimer.Stop()
        if ($null -ne $StageTimes) { $StageTimes['AVIF本変換'] += $encodeTimer.Elapsed }
    }
    if ($GPU) {
        $verifyTimer = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-GpuVerifyAvifBatch -Paths $gpuVerifyPaths.ToArray() -FFmpeg $Encoder -Workers ([Math]::Min(8, $Workers))
        }
        finally {
            $verifyTimer.Stop()
            if ($null -ne $StageTimes) { $StageTimes['AVIFデコード検証'] += $verifyTimer.Elapsed }
        }
    }
    return $finished
}

# 圧縮せずそのまま使うかを判定。CBZなどは元アーカイブのサイズ、
# フォルダ入力は対象画像のバイト数を利用する。
function Get-InputSizeBytes {
    param([Parameter(Mandatory = $true)]$Item)
    if (-not $Item.IsDirectory) {
        return [long](Get-Item -LiteralPath $Item.FullName).Length
    }
    $total = [long]0
    foreach ($file in @(Get-ChildItem -LiteralPath $Item.FullName -File -Recurse -Force |
        Where-Object { $_.Extension.ToLowerInvariant() -in $ImageExtensions -and
            $_.Name -notlike '._*' -and $_.FullName -notmatch '[\\/]__MACOSX[\\/]' })) {
        $total += [long]$file.Length
    }
    return $total
}

# 最大12ページの代表画像をAVIFへ変換し、巻全体の出力容量を推定する。
# 予備変換済みAVIFは削除せず、最終品質が決まった時に本変換で再利用する。
function Get-AvifSampleEstimate {
    param(
        [System.Collections.Generic.List[object]]$Entries,
        [string]$Encoder,
        [string]$Decoder,
        [int]$Quality,
        [int]$Workers,
        [string]$ScratchDir,
        [string]$VolumeName,
        [switch]$CpuProbe
    )
    $convertible = [System.Collections.Generic.List[object]]::new()
    $fullOriginal = [long]0
    $unconverted = [long]0
    for ($index = 0; $index -lt $Entries.Count; $index++) {
        $entry = $Entries[$index]
        if ($entry.NeedsConversion) {
            $fullOriginal += [long]$entry.Length
            $convertible.Add([pscustomobject]@{ Index = $index; Entry = $entry })
        }
        else { $unconverted += [long]$entry.Length }
    }
    if ($convertible.Count -eq 0) {
        return [pscustomobject]@{
            Quality = $Quality
            EstimatedBytes = $unconverted
            Cache = @()
        }
    }

    $sampleCount = [Math]::Min(12, $convertible.Count)
    $selected = [System.Collections.Generic.List[object]]::new()
    $sampleOriginal = [long]0
    for ($i = 0; $i -lt $sampleCount; $i++) {
        $position = if ($sampleCount -eq 1) { 0 } else {
            [int][Math]::Round($i * ($convertible.Count - 1) / ($sampleCount - 1))
        }
        $source = $convertible[$position]
        $sampleOriginal += [long]$source.Entry.Length
        $selected.Add([pscustomobject]@{
            SourceIndex = [int]$source.Index
            SourcePath = $source.Entry.SourcePath
            EntryName = $source.Entry.EntryName
            Length = [long]$source.Entry.Length
            NeedsConversion = $true
            Extension = $source.Entry.Extension
        })
    }
    if ($sampleOriginal -le 0) { throw '代表画像のサイズを取得できません' }

    # 品質ごとに別の作業先へ保存する。本変換終了まで保持する。
    $sampleDir = Join-Path $ScratchDir ($(if ($CpuProbe) {'cpu_sample_q'} else {'sample_q'}) + $Quality)
    [void](Invoke-ParallelAvif -Entries $selected -Encoder $Encoder -Decoder $Decoder `
        -Quality $Quality -Workers $Workers -TempDir $sampleDir -OutputName "$VolumeName / 試算 Q$Quality" -CpuProbe:$CpuProbe)
    $sampleEncoded = [long]0
    $cache = [System.Collections.Generic.List[object]]::new()
    foreach ($sample in $selected) {
        $sampleEncoded += [long]$sample.Length
        $cache.Add([pscustomobject]@{
            Index = [int]$sample.SourceIndex
            Path = $sample.SourcePath
            Length = [long]$sample.Length
            EncodedBy = [string]$sample.EncodedBy
        })
    }
    $estimate = [long][Math]::Round($unconverted +
        ($fullOriginal * ($sampleEncoded / [double]$sampleOriginal)))
    return [pscustomobject]@{
        Quality = $Quality
        EstimatedBytes = $estimate
        Cache = $cache.ToArray()
    }
}

# 最大5回の品質テストで、推定68MiB以下になる最高品質を探す。
# 二分探索で試した品質の実AVIFをキャッシュして、全ページ変換に使う。
function Find-AvifQuality {
    param(
        [System.Collections.Generic.List[object]]$Entries,
        [string]$Encoder,
        [string]$Decoder,
        [int]$Workers,
        [string]$ScratchDir,
        [string]$VolumeName,
        [long]$SampleLimitBytes,
        [ValidateRange(30, 95)][int]$MaxQuality = 95,
        [switch]$CpuProbe
    )
    $low = 30
    $high = $MaxQuality
    $bestProbe = $null
    $probes = [System.Collections.Generic.List[object]]::new()

    for ($iteration = 0; $iteration -lt 5 -and $low -le $high; $iteration++) {
        $candidate = [int][Math]::Floor(($low + $high) / 2)
        $probe = Get-AvifSampleEstimate -Entries $Entries -Encoder $Encoder -Decoder $Decoder `
            -Quality $candidate -Workers $Workers -ScratchDir $ScratchDir -VolumeName $VolumeName -CpuProbe:$CpuProbe
        $probes.Add($probe)
        Write-Host ('  品質試算 Q{0}: 推定{1:N1} MiB / 内部目標{2:N1} MiB' -f `
            $candidate, ($probe.EstimatedBytes / 1MB), ($SampleLimitBytes / 1MB))
        if ($probe.EstimatedBytes -le $SampleLimitBytes) {
            $bestProbe = $probe
            $low = $candidate + 1
        }
        else {
            $high = $candidate - 1
        }
    }

    if ($null -eq $bestProbe) {
        # 試した中で最も低い品質を使う。70MiB超過時だけ全体で再試行する。
        $bestProbe = $probes | Sort-Object Quality | Select-Object -First 1
        Write-Warning '試した品質では68MiB以下にならない見込みです。必要なら本変換後に再調整します。'
    }
    return [pscustomobject]@{
        Quality = [int]$bestProbe.Quality
        EstimatedBytes = [long]$bestProbe.EstimatedBytes
        Probe = $bestProbe
        Probes = $probes.ToArray()
    }
}

# 元のエントリを残しておき、再試行ごとに独立した変換先を持たせる。
function Copy-VolumeEntries {
    param([System.Collections.Generic.List[object]]$Entries)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Entries) {
        $out.Add([pscustomobject]@{
            SourcePath = $entry.SourcePath
            EntryName = $entry.EntryName
            Length = [long]$entry.Length
            NeedsConversion = [bool]$entry.NeedsConversion
            Extension = $entry.Extension
            EncodedBy = if ($entry.PSObject.Properties['EncodedBy']) { [string]$entry.EncodedBy } else { '' }
        })
    }
    return ,$out
}

# 品質探索は最初の5回だけ。全ページは原則1回、70MiB超のときのみ再変換。
function Invoke-AutoSizeAvif {
    param(
        [System.Collections.Generic.List[object]]$Entries,
        [string]$Encoder,
        [string]$Decoder,
        [int]$Workers,
        [string]$ScratchDir,
        [string]$OutputName,
        [long]$MaxTargetBytes,
        [long]$SampleSafetyBytes,
        [System.Collections.IDictionary]$StageTimes
    )
    # ZIPヘッダー・中央ディレクトリエントリによる増分も見込む。
    $zipOverheadBytes = [long]0
    foreach ($entry in $Entries) {
        $nameBytes = [Text.Encoding]::UTF8.GetByteCount([string]$entry.EntryName)
        $zipOverheadBytes += [long](128 + 2 * $nameBytes)
    }
    $maxImageBytes = [long][Math]::Max(1, $MaxTargetBytes - $zipOverheadBytes)
    $sampleLimit = [long][Math]::Max(1, $maxImageBytes - $SampleSafetyBytes)
    Write-MangaStage -Name $OutputName -Stage "品質探索"
    $qualityTimer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $qualityChoice = Find-AvifQuality -Entries $Entries -Encoder $Encoder -Decoder $Decoder `
            -Workers $Workers -ScratchDir $ScratchDir -VolumeName $OutputName `
            -SampleLimitBytes $sampleLimit
        if ($ConversionMode -eq 'Hybrid') {
            $cpuChoice = Find-AvifQuality -Entries $Entries -Encoder $Encoder -Decoder $Decoder `
                -Workers $CpuWorkers -ScratchDir $ScratchDir -VolumeName "$OutputName / CPU" `
                -SampleLimitBytes $sampleLimit -CpuProbe
            $script:HybridCpuQuality = $cpuChoice.Quality
            Write-Host "  Independent qualities: GPU CQ$(Convert-GpuQualityToCq $qualityChoice.Quality), CPU q$($cpuChoice.Quality)"
        }
    }
    finally {
        $qualityTimer.Stop()
        if ($null -ne $StageTimes) { $StageTimes['品質探索'] += $qualityTimer.Elapsed }
    }
    $quality = $qualityChoice.Quality
    $selectedProbe = $qualityChoice.Probe
    $probes = @($qualityChoice.Probes)
    $bestOversizeEntries = $null
    $bestOversizeBytes = [long]::MaxValue
    $bestOversizeQuality = 0
    $converted = 0
    $originalConvertibleCount = @($Entries | Where-Object { $_.NeedsConversion }).Count

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $trialEntries = Copy-VolumeEntries -Entries $Entries
        $reusedCount = 0
        if ($null -ne $selectedProbe -and $selectedProbe.Quality -eq $quality) {
            # 探索中に作成した最大12ページを直接CBZ用エントリとして再利用。
            # ページ名・順番は元のエントリのままで、データ本体だけを差し替える。
            foreach ($cached in $selectedProbe.Cache) {
                if (-not (Test-Path -LiteralPath $cached.Path -PathType Leaf)) {
                    throw "品質試算キャッシュが見つかりません: $($cached.Path)"
                }
                $trialEntries[$cached.Index].SourcePath = $cached.Path
                $trialEntries[$cached.Index].Length = [long]$cached.Length
                $trialEntries[$cached.Index].NeedsConversion = $false
                $trialEntries[$cached.Index].EncodedBy = [string]$cached.EncodedBy
                $reusedCount++
            }
        }

        $trialDir = Join-Path $ScratchDir ('full_q' + $quality)
        Write-MangaStage -Name $OutputName -Stage "AVIF全ページ変換（$attempt / 3回, Q$quality）"
        Write-Host "  全ページ変換（$attempt / 最大3回）: 品質$quality / テスト画像再利用 $reusedCount 枚" -ForegroundColor Cyan
        [void](Invoke-ParallelAvif -Entries $trialEntries -Encoder $Encoder -Decoder $Decoder `
            -Quality $quality -Workers $Workers -TempDir $trialDir -OutputName $OutputName `
            -StageTimes $StageTimes -FullPass)
        $actualBytes = [long]0
        foreach ($entry in $trialEntries) { $actualBytes += [long]$entry.Length }
        Write-Host ('  AVIF画像の合計容量: {0:N1} MiB（Q{1}）' -f ($actualBytes / 1MB), $quality)

        if ($actualBytes -le $maxImageBytes) {
            if ($null -ne $bestOversizeEntries) {
                Remove-Item -LiteralPath (Join-Path $ScratchDir ('full_q' + $bestOversizeQuality)) `
                    -Recurse -Force -ErrorAction SilentlyContinue
            }
            return [pscustomobject]@{
                Entries = $trialEntries
                Quality = $quality
                Bytes = $actualBytes
                Converted = $originalConvertibleCount
                UnderLimit = $true
            }
        }

        if ($actualBytes -lt $bestOversizeBytes) {
            if ($null -ne $bestOversizeEntries) {
                Remove-Item -LiteralPath (Join-Path $ScratchDir ('full_q' + $bestOversizeQuality)) `
                    -Recurse -Force -ErrorAction SilentlyContinue
            }
            $bestOversizeEntries = $trialEntries
            $bestOversizeBytes = $actualBytes
            $bestOversizeQuality = $quality
            $converted = $originalConvertibleCount
        }
        else { Remove-Item -LiteralPath $trialDir -Recurse -Force -ErrorAction SilentlyContinue }

        if ($attempt -eq 3 -or $quality -le 30) { break }

        # 全体の実サイズから試算誤差を補正。探索は繰り返さず、既存の
        # サンプル結果で次の品質を決める（本変換の再試行は超過時だけ）。
        $estimatedAtQuality = $null
        foreach ($probe in $probes) {
            if ($probe.Quality -eq $quality) {
                $estimatedAtQuality = [long]$probe.EstimatedBytes
                break
            }
        }
        if ($null -eq $estimatedAtQuality) {
            # サンプル外の品質を全変換した場合は、前回の補正値を維持する。
            if ($null -eq $ratio) { $ratio = 1.0 }
        }
        else {
            $ratio = $actualBytes / [double][Math]::Max(1, $estimatedAtQuality)
        }
        $nextProbe = $null
        foreach ($probe in @($probes | Sort-Object Quality -Descending)) {
            if ($probe.Quality -lt $quality -and
                ($probe.EstimatedBytes * $ratio) -le $sampleLimit) {
                $nextProbe = $probe
                break
            }
        }
        if ($null -ne $nextProbe) {
            $nextQuality = [int]$nextProbe.Quality
        }
        else {
            # サンプルで適合品質がない場合は、現在品質から段階的に落とす。
            $overflowFraction = [Math]::Max(0, ($actualBytes - $sampleLimit) / [double]$sampleLimit)
            $step = [int][Math]::Max(5, [Math]::Ceiling($overflowFraction * 30))
            $nextQuality = [int][Math]::Max(30, $quality - $step)
        }
        if ($nextQuality -ge $quality) { $nextQuality = [int][Math]::Max(30, $quality - 1) }
        if ($nextQuality -eq $quality) { break }
        $quality = $nextQuality
        if ($ConversionMode -in @('GPU','Hybrid')) {
            $script:HybridCpuQuality=[Math]::Max(30,$script:HybridCpuQuality-5)
            Write-Warning "CPU own quality reduced to $script:HybridCpuQuality for size retry"
        }
        $selectedProbe = $nextProbe
        Write-Warning ('70MiB超過。追加の品質テストは行わず、Q{0}で再試行します。' -f $quality)
    }

    if ($ConversionMode -in @('GPU','Hybrid')) { throw 'Experimental conversion exceeded 70MiB after size retries; no output committed' }
    Write-Warning '70MiB以内に収まりませんでした。試した中で最小の結果を警告付きで保存します。'
    return [pscustomobject]@{
        Entries = $bestOversizeEntries
        Quality = $bestOversizeQuality
        Bytes = $bestOversizeBytes
        Converted = $converted
        UnderLimit = $false
    }
}

function Get-VolumeLabel {
    param([string]$Raw)
    # Input 'v100b' and 'v100B' are allowed, but strip only the trailing 'b' in output.
    # Other suffixes (e.g. 'a') are unchanged.
    $Raw = $Raw.Normalize([Text.NormalizationForm]::FormKC)
    if (-not ($Raw -match '^(?<whole>[0-9]+)(?<fraction>\.[0-9]+)?(?<suffix>[a-z]?)$')) {
        throw "未対応の巻数表記です: $Raw"
    }
    $whole = $Matches['whole'].TrimStart('0')
    if ($whole.Length -eq 0) { $whole = '0' }
    $label = $whole.PadLeft(2, '0')
    if ($Matches['fraction']) { $label += $Matches['fraction'] }
    if ($Matches['suffix'] -and $Matches['suffix'] -ine 'b') { $label += $Matches['suffix'] }
    return $label
}

function Get-NaturalSortKey {
    param([string]$Name)
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $m.Value.PadLeft(20, '0')
    }
    return [regex]::Replace($Name, '\d+', $evaluator)
}

function Test-SafeTitle {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -eq '.' -or $Name -eq '..' -or $Name -match '[. ]$') { return $false }
    if ($Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $false }
    return $true
}

function Invoke-MangaBatch {
    param([string[]]$Paths)

    # All mutable batch state lives in this invocation. Detection helpers use
    # PowerShell's caller scope for Items/Seen; no previous batch survives here.
    $Items = [System.Collections.Generic.List[object]]::new()
    $Seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($raw in $Paths) {
        try {
            $path = $raw.Trim('"')
            $inputItem = Get-Item -LiteralPath $path -ErrorAction Stop
            if ($inputItem.PSIsContainer) {
                Scan-Container -Container $inputItem
            }
            elseif (-not (Add-MangaItem -InputItem $inputItem)) {
                Write-Warning "対象外（形式・画像の有無を確認）: $($inputItem.FullName)"
            }
        }
        catch {
            Write-Warning "読み込み失敗: $raw / $($_.Exception.Message)"
        }
    }

    if ($Items.Count -eq 0) {
        Write-Host '変換できる漫画・雑誌が見つかりませんでした。'
        Write-Host '例: ONE PIECE v100.cbz、（１５）.epub、Weekly_Ascii_2026-10-20.epub、Best Selection.epub'
        return
    }

    Write-Host "`n読み込み: $($Items.Count)件" -ForegroundColor Cyan
    $Items | Sort-Object Title, @{ Expression = { Get-NaturalSortKey -Name $_.Volume } } | ForEach-Object {
        if ($_.IsStandalone) {
            Write-Host "  $($_.Title) [雑誌・単巻 / 元名維持] -> $($_.OutputDir)"
        }
        elseif ([string]::IsNullOrWhiteSpace($_.Volume)) {
            Write-Host "  $($_.Title) [漫画 / 巻数未検出・元名保持] -> $($_.OutputDir)"
        }
        else {
            Write-Host "  $($_.Title) [$($_.Volume)巻] -> $($_.OutputDir)"
        }
    }

    # WinRAR is only needed for ZIP/CBZ/RAR inputs, not for folders or EPUB.
    $WinRAR = $null
    $success = 0
    $skipped = 0
    $failed = 0
    $oversized = 0

    $seriesItems = @($Items | Where-Object { -not $_.IsStandalone })
    $standaloneItems = @($Items | Where-Object { $_.IsStandalone })
    $newTitle = ''
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "まとめて変換: $($Items.Count)件（漫画: $($seriesItems.Count) / 雑誌・単巻: $($standaloneItems.Count)）"

    if ($seriesItems.Count -gt 0) {
        # Manga mode always prompts once, even if every filename lacks a volume token.
        $originalTitles = @($seriesItems | ForEach-Object { $_.Title } | Select-Object -Unique)
        if ($originalTitles.Count -gt 1) {
            Write-Warning '複数のシリーズ名が見つかりました。シリーズ巻はすべて同じ作品名に統一します。'
            Write-Host ('検出した元作品名: ' + ($originalTitles -join ' / '))
        }
        $defaultTitle = $seriesItems[0].Title
        Write-Host "元のシリーズ名: $defaultTitle"
        $newTitle = Read-MangaResponse "シリーズの出力作品名（Enterなら $defaultTitle）"
        if ($null -eq $newTitle) { return }
        if ([string]::IsNullOrWhiteSpace($newTitle)) { $newTitle = $defaultTitle }
        $newTitle = $newTitle.Trim()
        if (-not (Test-SafeTitle -Name $newTitle)) {
            Write-Host "無効な作品名です: $newTitle" -ForegroundColor Red
            return
        }
        Write-Host "漫画$($seriesItems.Count)件の出力名に「$newTitle」を適用します（巻数不明は元名も保持）。" -ForegroundColor Cyan
    }
    if ($standaloneItems.Count -gt 0) {
        # Stand-alone files retain independent names; never apply one title to the batch.
        Write-Host "雑誌・単巻$($standaloneItems.Count)件は元のファイル名を保持して保存します。" -ForegroundColor Cyan
    }

    # 60MiB以下の巻は無変換。超える巻は70MiB以下で最高品質を目指す。
    Write-Host "`n====== AVIF自動容量調整 ======" -ForegroundColor Cyan
    Write-Host '元ファイルが60MiB以下: 変換なし（CBZならファイルをそのままコピー）'
    Write-Host '60MiB超: 代表12ページ・最大5回試算で68MiBを目安に品質を選択（上限70MiB）'
    if ($GPU) {
        # Fixed by benchmarking: one image per FFmpeg process, up to twelve.
        $workers = 12
        Write-Host 'NVENC GPUエンコード: preset p7 / yuv420p' -ForegroundColor Cyan
        Write-Host 'GPU並列: 12プロセス × 1画像（固定）' -ForegroundColor Cyan
        Write-Host 'GPU変換に失敗した場合、黙ってCPUへ切り替えません。元ファイルは保持します。'
    }
    else {
        Write-Host 'AVIFエンコード速度: -s 6（従来どおり） / 元CBZは保持して avif変換cbz へ出力'
        $logicalCores = [Environment]::ProcessorCount
        $autoWorkers = [int][Math]::Max(1, [Math]::Min(8, [Math]::Floor($logicalCores / 2)))
        Write-Host ''
        Write-Host '====== AVIFの並列処理 ======' -ForegroundColor Cyan
        Write-Host "CPU: $logicalCores 論理コア / 自動設定: $autoWorkers 枚同時"
        while ($true) {
            $workerInput = Read-MangaResponse "並列数 [1-16]（Enterで自動: $autoWorkers）"
            if ($null -eq $workerInput) { return }
            $workerInput = $workerInput.Trim()
            if ($workerInput -eq '') { $workers = $autoWorkers; break }
            $candidate = 0
            if ([int]::TryParse($workerInput, [ref]$candidate) -and $candidate -ge 1 -and $candidate -le 16) {
                $workers = $candidate
                break
            }
            Write-Host '1～16の整数かEnterを入力してください。' -ForegroundColor Yellow
        }

    }
    if ($ConversionMode -in @('GPU','Hybrid')) {
        $workers=$GpuWorkers
        Write-Host "Experimental $ConversionMode : GPU $GpuWorkers / CPU $(if ($ConversionMode -eq 'Hybrid') {$CpuWorkers} else {0}), logged CPU fallback enabled"
    }
    $encoder = $null
    $decoder = $null
    # If both v100 and v100b are dropped together, both normalize to v100.cbz.
    # Prefer the first (naturally sorted) input and skip subsequent collisions.
    $plannedOutputs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $completedItems = 0
    # Exclude time spent waiting for series title / worker input.
    $batchTimer = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($item in ($Items | Sort-Object @{ Expression = { Get-NaturalSortKey -Name $_.Volume } }, FullName)) {
        if ($item.IsStandalone) {
            $outputName = "$($item.SourceBase).cbz"
        }
        elseif ([string]::IsNullOrWhiteSpace($item.Volume)) {
            # Keep unknown-volume inputs distinct and do not invent an ordinal.
            $suffix = if ($item.SourceBase -ceq $newTitle) { '' } else { " - $($item.SourceBase)" }
            $outputName = "$newTitle$suffix.cbz"
        }
        else {
            $vol = Get-VolumeLabel -Raw $item.Volume
            $outputName = "$newTitle v$vol.cbz"
        }
        Write-MangaOverallProgress -Completed $completedItems -Total $Items.Count -Name $outputName
        Write-Host ("[{0}/{1}] {2}" -f ($completedItems + 1), $Items.Count, $outputName) -ForegroundColor Cyan
        # CBZ入力を同名で再変換できるよう、出力だけ専用のサブフォルダに分離。
        $destinationDir = Join-Path $item.OutputDir $OutputFolderName
        $output = Join-Path $destinationDir $outputName

        if (-not $plannedOutputs.Add($output)) {
            Write-Warning "SKIP 出力名重複: $($item.FullName) -> $outputName（同名の入力が今回の対象に含まれています）"
            $skipped++
            $completedItems++
            Write-MangaOverallProgress -Completed $completedItems -Total $Items.Count -Name $outputName
            continue
        }
        if (Test-Path -LiteralPath $output) {
            Write-Host "SKIP 既存: $output" -ForegroundColor Yellow
            $skipped++
            $completedItems++
            Write-MangaOverallProgress -Completed $completedItems -Total $Items.Count -Name $outputName
            continue
        }

        $stageTimes = [ordered]@{
            '入力準備' = [TimeSpan]::Zero
            '展開・EPUB抽出' = [TimeSpan]::Zero
            '品質探索' = [TimeSpan]::Zero
            'AVIF本変換' = [TimeSpan]::Zero
            'AVIFデコード検証' = [TimeSpan]::Zero
            'CBZ書込・コピー' = [TimeSpan]::Zero
            'CBZ検証・保存' = [TimeSpan]::Zero
        }
        $script:EncodePasses.Clear()
        $script:HybridCpuQuality=95
        $reportStatus='Failed'
        $finalBytes=0L
        $winningQuality=0
        $volumeTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $prepareTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $preparationRecorded = $false
        $workDir = Join-Path ([IO.Path]::GetTempPath()) ("MangaCbz_" + [Guid]::NewGuid().ToString('N'))
        $tempCbz = Join-Path $destinationDir ('.manga_' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null

            Write-MangaStage -Name $outputName -Stage "入力解析"
            $inputBytes = Get-InputSizeBytes -Item $item
            $shouldCompress = $inputBytes -gt $CopyThresholdBytes
            Write-Host ('元の容量: {0:N1} MB → {1}' -f ($inputBytes / 1MB), `
                $(if ($shouldCompress) { '自動AVIF変換' } else { '変換なし' }))

            # 60MB以下のCBZは中身・ZIP構造を一切変更せず、完成先に原本をコピー。
            if (-not $shouldCompress -and -not $item.IsDirectory -and $item.FullName.ToLowerInvariant().EndsWith('.cbz')) {
                Write-MangaStage -Name $outputName -Stage "CBZ原本コピー"
                $prepareTimer.Stop()
                $stageTimes['入力準備'] = $prepareTimer.Elapsed
                $preparationRecorded = $true
                $copyTimer = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    Copy-Item -LiteralPath $item.FullName -Destination $tempCbz -ErrorAction Stop
                    [IO.File]::Move($tempCbz, $output)
                }
                finally {
                    $copyTimer.Stop()
                    $stageTimes['CBZ書込・コピー'] += $copyTimer.Elapsed
                }
                Write-Host ('[OK] {0}（変換なし、そのままコピー / {1:N1} MB）' -f $outputName, ($inputBytes / 1MB)) -ForegroundColor Green
                $success++
                $reportStatus='Copied'
                $finalBytes=$inputBytes
                continue
            }

            $isEpub = ((-not $item.IsDirectory) -and
                ([IO.Path]::GetExtension($item.FullName).ToLowerInvariant() -eq '.epub'))
            if ($isEpub) {
                Write-MangaStage -Name $outputName -Stage "EPUB読書順抽出"
                Write-Host "EPUB読書順を解析: $($item.FullName)"
                $prepareTimer.Stop()
                $extractTimer = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $images = @(Get-EpubPageImages -EpubPath $item.FullName -ExtractionDir (Join-Path $workDir 'epub_pages'))
                }
                finally {
                    $extractTimer.Stop()
                    $stageTimes['展開・EPUB抽出'] += $extractTimer.Elapsed
                    $prepareTimer.Start()
                }
                Write-Host "  本文ページ順を取得: $($images.Count)枚（001から連番化）" -ForegroundColor Cyan
            }
            else {
                if ($item.IsDirectory) {
                    $sourceDir = $item.FullName
                }
                else {
                    if ($null -eq $WinRAR) { $WinRAR = Find-WinRAR }
                    Write-MangaStage -Name $outputName -Stage "アーカイブ展開"
                    Write-Host "解凍: $($item.FullName)"
                    # WinRAR x: preserve internal paths, skip overwrites inside this private temp directory.
                    $prepareTimer.Stop()
                    $extractTimer = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        & $WinRAR x -y -o- -inul $item.FullName ($workDir + '\') | Out-Null
                        if ($LASTEXITCODE -ne 0) {
                            throw "WinRARでの展開に失敗しました（終了コード: $LASTEXITCODE）"
                        }
                    }
                    finally {
                        $extractTimer.Stop()
                        $stageTimes['展開・EPUB抽出'] += $extractTimer.Elapsed
                        $prepareTimer.Start()
                    }
                    $sourceDir = $workDir
                }
                $images = @(
                    Get-ChildItem -LiteralPath $sourceDir -File -Recurse -Force |
                    Where-Object {
                        $_.Extension.ToLowerInvariant() -in $ImageExtensions -and
                        $_.Name -notlike '._*' -and
                        $_.FullName -notmatch '[\\/]__MACOSX[\\/]'
                    } |
                    Sort-Object @{ Expression = { Get-NaturalSortKey -Name $_.Name } }, FullName
                )
            }
            Write-MangaStage -Name $outputName -Stage "画像確認（$($images.Count)枚）"
            if ($images.Count -eq 0) { throw '画像ファイルが見つかりません' }

            # 格納名は元画像名を基本とし、AVIF変換時だけ.avifに変更。
            # 例: 001.jpg / 001.webp -> 001.avif。異なる拡張子同士の衝突も検出する。
            $entries = [System.Collections.Generic.List[object]]::new()
            $entryNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            # 無駄な変換を避けるため、出力名の衝突を先に確認する。
            foreach ($img in $images) {
                $ext = $img.Extension.ToLowerInvariant()
                $name = if ($shouldCompress -and $ext -in @('.jpg', '.jpeg', '.png', '.webp')) {
                    [IO.Path]::GetFileNameWithoutExtension($img.Name) + '.avif'
                } else { $img.Name }
                if (-not $entryNames.Add($name)) {
                    throw "CBZ内の画像名が重複します: $name（元ファイル名を確認してください）"
                }
            }
            # ページ順に格納リストを先に組み立て、AVIF対象のみ同時実行する。
            # ワーカーの完了順はZIP内のページ順に影響しない。
            $originalBytes = [long]0
            foreach ($img in $images) {
                $originalBytes += [long]$img.Length
                $extension = $img.Extension.ToLowerInvariant()
                $needsConversion = $shouldCompress -and $extension -in @('.jpg', '.jpeg', '.png', '.webp')
                $entryName = if ($needsConversion) {
                    [IO.Path]::GetFileNameWithoutExtension($img.Name) + '.avif'
                } else { $img.Name }
                $entries.Add([pscustomobject]@{
                    SourcePath      = $img.FullName
                    EntryName       = $entryName
                    Length          = [long]$img.Length
                    NeedsConversion = $needsConversion
                    Extension       = $extension
                    EncodedBy       = ''
                })
            }

            $prepareTimer.Stop()
            $stageTimes['入力準備'] = $prepareTimer.Elapsed
            $preparationRecorded = $true

            $converted = 0
            $formatLabel = '変換なし'
            $winningQuality = 0
            if ($shouldCompress) {
                if (@($entries | Where-Object { $_.NeedsConversion }).Count -gt 0) {
                    if ($null -eq $encoder) {
                        $encoder = if ($GPU) { Find-FFmpegNvenc } else { Find-OrInstall-Avifenc }
                        if ($ConversionMode -in @('GPU','Hybrid')) {
                            $script:CpuEncoder=Find-OrInstall-Avifenc
                            [void](Test-HybridAvifenc -Path $script:CpuEncoder)
                        }
                    }
                    if ($null -eq $decoder -and @($entries | Where-Object {
                        $_.NeedsConversion -and $_.Extension -eq '.webp'
                    }).Count -gt 0) {
                        $decoder = Find-OrInstall-Dwebp
                    }
                    $auto = Invoke-AutoSizeAvif -Entries $entries -Encoder $encoder -Decoder $decoder `
                        -Workers $workers -ScratchDir (Join-Path $workDir 'autotune') `
                        -OutputName $outputName -MaxTargetBytes $MaxTargetBytes `
                        -SampleSafetyBytes $SampleSafetyBytes -StageTimes $stageTimes
                    $entries = $auto.Entries
                    $converted = $auto.Converted
                    $winningQuality = $auto.Quality
                    $formatLabel = if ($GPU) {
                        "NVENC AVIF 品質尺度$winningQuality (CQ$(Convert-GpuQualityToCq -Quality $winningQuality))"
                    } else { "AVIF 品質$winningQuality" }
                    if (-not $auto.UnderLimit) {
                        Write-Warning ('70MiB以内に収まりませんでした: Q{0} / 約{1:N1} MiB' -f `
                            $winningQuality, ($auto.Bytes / 1MB))
                    }
                }
                else {
                    Write-Warning '対象のJPEG/PNG/WebPがないため、AVIFの圧縮品質調整はできません。画像をそのままCBZに格納します。'
                }
            }

            if ($ConversionMode -in @('GPU','Hybrid')) {
                $verifyTimer=[Diagnostics.Stopwatch]::StartNew()
                try {
                    $avifs=@($entries | Where-Object { [IO.Path]::GetExtension($_.SourcePath) -eq '.avif' })
                    $samples=[string[]]@(Select-AvifVerificationSamples -Entries $avifs)
                    if ($samples.Count -gt 0) {
                        if (-not $encoder) { $encoder=Find-FFmpegNvenc }
                        Write-Host ('  AVIFサンプル検証: {0}/{1} 枚' -f $samples.Count,$avifs.Count) -ForegroundColor DarkCyan
                        Invoke-GpuVerifyAvifBatch -Paths $samples -FFmpeg $encoder -Workers 2 -CancelFile $CancelFile -TimeoutSeconds $EncoderTimeoutSeconds
                    }
                } finally { $verifyTimer.Stop(); $stageTimes['AVIFデコード検証'] += $verifyTimer.Elapsed }
            }
            Write-MangaStage -Name $outputName -Stage "CBZ書き込み"
            $writeTimer = [System.Diagnostics.Stopwatch]::StartNew()
            try { Write-MangaStoredZip -Path $tempCbz -Entries $entries }
            finally {
                $writeTimer.Stop()
                $stageTimes['CBZ書込・コピー'] += $writeTimer.Elapsed
            }

            Write-MangaStage -Name $outputName -Stage "CBZ検証"
            $finalizeTimer = [System.Diagnostics.Stopwatch]::StartNew()
            try {
            $check = [IO.Compression.ZipFile]::OpenRead($tempCbz)
            try {
                if ($check.Entries.Count -ne $entries.Count) {
                    throw 'CBZ作成後の画像数が一致しません'
                }
                for ($i = 0; $i -lt $entries.Count; $i++) {
                    if ($check.Entries[$i].FullName -cne $entries[$i].EntryName -or
                        $check.Entries[$i].Length -ne $entries[$i].Length) {
                        throw 'CBZ作成後の画像名またはサイズが一致しません'
                    }
                }
            }
            finally { $check.Dispose() }

            # 一時CBZは出力先と同じディレクトリに作成。既存ファイルを上書きしない。
            if ($ConversionMode -in @('GPU','Hybrid') -and $shouldCompress -and ([IO.FileInfo]::new($tempCbz)).Length -gt $MaxTargetBytes) {
                throw 'Final CBZ exceeds 70MiB; no output committed'
            }
            if ($ConversionMode -in @('GPU','Hybrid') -and $CancelFile -and (Test-Path -LiteralPath $CancelFile)) { throw 'Conversion cancelled before commit' }
            [IO.File]::Move($tempCbz, $output)
            $reportStatus='Success'
            Write-Host "[OK] $outputName ($($images.Count)枚 / $formatLabel $converted 枚)" -ForegroundColor Green
            $finalBytes = [long](Get-Item -LiteralPath $output).Length
            Write-Host ('  元画像合計: {0:N1} MB / 完成CBZ: {1:N1} MB' -f ($originalBytes / 1MB), ($finalBytes / 1MB))
            if ($shouldCompress -and $finalBytes -gt $MaxTargetBytes) {
                Write-Warning ('[WARN] 70MiB上限超過: {0} / {1:N1} MiB' -f $outputName, ($finalBytes / 1MB))
                $oversized++
            }
            else { $success++ }
            }
            finally {
                $finalizeTimer.Stop()
                $stageTimes['CBZ検証・保存'] += $finalizeTimer.Elapsed
            }
        }
        catch {
            Write-Warning "FAIL: $($item.FullName) / $($_.Exception.Message)"
            if ($ConversionMode -in @('GPU','Hybrid')) { $script:ExperimentFailed=$true }
            $failed++
        }
        finally {
            if (-not $preparationRecorded) {
                $prepareTimer.Stop()
                $stageTimes['入力準備'] = $prepareTimer.Elapsed
            }
            try {
                # Failed cleanup is fatal: never accept another batch with live work.
                if (Test-Path -LiteralPath $tempCbz) { Remove-Item -LiteralPath $tempCbz -Force -ErrorAction Stop }
                if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Stop }
            }
            finally {
                $volumeTimer.Stop()
                Write-MangaTimingReport -Name $outputName -Stages $stageTimes -Total $volumeTimer.Elapsed
                if ($ConversionMode -in @('GPU','Hybrid')) {
                    $stageSeconds=[ordered]@{}
                    foreach ($key in $stageTimes.Keys) { $stageSeconds[$key]=$stageTimes[$key].TotalSeconds }
                    $report=[ordered]@{ Mode=$ConversionMode; Status=$reportStatus; Input=$item.FullName;
                        Output=$output; TotalSeconds=$volumeTimer.Elapsed.TotalSeconds; FinalBytes=$finalBytes;
                        GpuWorkers=$GpuWorkers; CpuWorkers=$(if ($ConversionMode -eq 'Hybrid') {$CpuWorkers} else {0});
                        GpuQuality=$winningQuality; CpuQuality=$script:HybridCpuQuality;
                        SizeRetries=[Math]::Max(0,@($script:EncodePasses | Where-Object { $_.Phase -eq 'Full' }).Count-1);
                        Stages=$stageSeconds; Passes=@($script:EncodePasses.ToArray()) }
                    $metricsDir=if ($ReportDirectory) { $ReportDirectory } else { Join-Path $destinationDir 'metrics' }
                    if ($metricsDir) {
                        New-Item -ItemType Directory -Path $metricsDir -Force | Out-Null
                        $reportPath=Join-Path $metricsDir ([Guid]::NewGuid().ToString('N')+'.json')
                        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
                        Write-Host "  Metrics: $reportPath"
                    }
                    foreach ($pass in $script:EncodePasses) {
                        Write-Host ('  [{0}] GPU {1} / CPU {2} pages, {3:N2} pages/s, errors {4}, retries {5}' -f $pass.Phase,$pass.GpuPages,$pass.CpuPages,$pass.PagesPerSecond,$pass.Errors,$pass.Retries)
                    }
                }
            }
            $completedItems++
            Write-MangaOverallProgress -Completed $completedItems -Total $Items.Count -Name $outputName
        }
    }

    $batchTimer.Stop()
    Write-MangaOverallProgress -Completed $completedItems -Total $Items.Count -Done
    Write-Host "`n========== 完了 ==========" -ForegroundColor Cyan
    Write-Host "成功: $success / 上限超過: $oversized / スキップ: $skipped / 失敗: $failed"
    Write-Host ("変換所要時間: {0}" -f (Format-MangaElapsed -Duration $batchTimer.Elapsed))
    Write-Host '元のフォルダ・ZIP・RAR・CBZは削除していません。'
}

try {
    if ($DroppedPaths.Count -gt 0) { Invoke-MangaBatch -Paths $DroppedPaths }
    $modeLabel = if ($Magazine) { '雑誌・単巻' } else { '漫画' }
    Write-Host ("BookConverter / {0}モード" -f $modeLabel) -ForegroundColor Cyan
    while ($true) {
        $line = Read-MangaResponse ('[待機中] 次の{0}の絶対パスを入力（ドロップ/貼り付け後Enter、終了 q/exit）' -f $modeLabel)
        if ($null -eq $line -or $line.Trim() -in @('q', 'exit')) { break }
        try { $paths = @(Split-MangaInput -Line $line) }
        catch {
            Write-Warning $_.Exception.Message
            continue
        }
        if ($paths.Count -eq 0) {
            Write-Host 'パスを入力してください。多数ファイルは親フォルダを指定できます。'
            continue
        }
        Invoke-MangaBatch -Paths $paths
    }
}
catch {
    Write-Warning "安全に継続できないため終了します: $($_.Exception.Message)"
    exit 1
}
finally {
    Write-Progress -Id 2 -ParentId 1 -Activity 'BookConverter' -Completed
    Write-MangaOverallProgress -Completed 0 -Total 0 -Done
}
if ($script:ExperimentFailed) { exit 1 }
exit 0
