# EPUB 2/3 (reflowable images / fixed-layout manga) input adapter.
# Invoke via dot sourcing from Convert-Manga.ps1. PowerShell 7.6 on Windows compatible.
# The ZIP remains read-only. Only the reading-order images are extracted to a private temp folder.

function Read-EpubXml {
    param([Parameter(Mandatory = $true)][IO.Compression.ZipArchiveEntry]$Entry)

    $stream = $Entry.Open()
    $reader = $null
    try {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
        $settings.XmlResolver = $null
        $settings.MaxCharactersInDocument = 20000000
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        $xml = New-Object System.Xml.XmlDocument
        $xml.XmlResolver = $null
        $xml.Load($reader)
        return $xml
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $stream.Dispose()
    }
}

# EPUB uses POSIX paths. Resolve links relative to the referring OPF/XHTML/SVG.
# Reject external URLs and path traversal beyond the EPUB root.
function Resolve-EpubPath {
    param([string]$Referer, [string]$Href)

    if ([string]::IsNullOrWhiteSpace($Href)) { throw 'EPUB内部に空の参照先があります' }
    $target = $Href.Trim()
    if ($target -match '^[a-zA-Z][a-zA-Z0-9+.-]*:' -or $target.StartsWith('//')) {
        throw "EPUB内部の外部参照には対応していません: $Href"
    }
    $target = ($target -split '[?#]', 2)[0]
    $target = [Uri]::UnescapeDataString($target).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($target)) { throw "EPUB内部の参照先が画像ではありません: $Href" }

    $parts = [System.Collections.Generic.List[string]]::new()
    if (-not $target.StartsWith('/')) {
        $base = $Referer.Replace('\', '/')
        $slash = $base.LastIndexOf('/')
        if ($slash -ge 0) {
            foreach ($segment in $base.Substring(0, $slash).Split('/')) {
                if ($segment.Length -gt 0) { $parts.Add($segment) }
            }
        }
    }
    foreach ($segment in $target.Split('/')) {
        if ($segment -eq '' -or $segment -eq '.') { continue }
        if ($segment -eq '..') {
            if ($parts.Count -eq 0) { throw "EPUB外へのパス移動は許可されていません: $Href" }
            $parts.RemoveAt($parts.Count - 1)
        }
        else {
            if ($segment.IndexOf([char]0) -ge 0) { throw "無効なEPUBパスです: $Href" }
            $parts.Add($segment)
        }
    }
    if ($parts.Count -eq 0) { throw "無効なEPUBパスです: $Href" }
    return ($parts -join '/')
}

function Get-EpubArchiveEntry {
    param([IO.Compression.ZipArchive]$Archive, [string]$Path)

    # FullName is case-sensitive according to ZIP spec; case-insensitive fallback
    # accommodates books created by non-conforming EPUB exporters.
    $exact = $Archive.GetEntry($Path)
    if ($null -ne $exact) { return $exact }
    $matches = @($Archive.Entries | Where-Object { $_.FullName -ieq $Path })
    if ($matches.Count -eq 1) { return $matches[0] }
    if ($matches.Count -gt 1) { throw "EPUBに大文字・小文字違いの重複パスがあります: $Path" }
    throw "EPUB内部ファイルが見つかりません: $Path"
}

function Get-EpubElementAttribute {
    param([System.Xml.XmlNode]$Node, [string]$Name)

    if ($null -eq $Node.Attributes) { return '' }
    foreach ($attr in $Node.Attributes) {
        if ($attr.LocalName -eq $Name) { return [string]$attr.Value }
    }
    return ''
}

function Test-EpubExtractedImage {
    param([string]$FilePath, [string]$Extension)

    $bytes = New-Object byte[] 16
    $stream = [IO.File]::OpenRead($FilePath)
    try { $count = $stream.Read($bytes, 0, $bytes.Length) }
    finally { $stream.Dispose() }
    $ascii = [Text.Encoding]::ASCII
    $valid = switch ($Extension) {
        { $_ -in @('.jpg', '.jpeg') } { $count -ge 3 -and $bytes[0] -eq 255 -and $bytes[1] -eq 216 -and $bytes[2] -eq 255; break }
        '.png' { $count -ge 8 -and $bytes[0] -eq 137 -and $ascii.GetString($bytes, 1, 3) -eq 'PNG'; break }
        '.webp' { $count -ge 12 -and $ascii.GetString($bytes, 0, 4) -eq 'RIFF' -and $ascii.GetString($bytes, 8, 4) -eq 'WEBP'; break }
        '.gif' { $count -ge 6 -and $ascii.GetString($bytes, 0, 3) -eq 'GIF'; break }
        '.bmp' { $count -ge 2 -and $ascii.GetString($bytes, 0, 2) -eq 'BM'; break }
        '.avif' { $count -ge 12 -and $ascii.GetString($bytes, 4, 4) -eq 'ftyp'; break }
        default { $false }
    }
    if (-not $valid) {
        throw "EPUB画像の形式が正しくありません（暗号化・DRM・拡張子不一致の可能性）: $FilePath"
    }
}

function Get-EpubPageImages {
    param(
        [Parameter(Mandatory = $true)][string]$EpubPath,
        [Parameter(Mandatory = $true)][string]$ExtractionDir
    )

    $archive = [IO.Compression.ZipFile]::OpenRead($EpubPath)
    try {
        $container = Read-EpubXml -Entry (Get-EpubArchiveEntry -Archive $archive -Path 'META-INF/container.xml')
        $rootFile = $container.SelectSingleNode('/*[local-name()="container"]/*[local-name()="rootfiles"]/*[local-name()="rootfile"]')
        if ($null -eq $rootFile) { throw 'META-INF/container.xmlにOPFへの参照がありません' }
        $opfPath = Resolve-EpubPath -Referer '' -Href (Get-EpubElementAttribute -Node $rootFile -Name 'full-path')
        $opf = Read-EpubXml -Entry (Get-EpubArchiveEntry -Archive $archive -Path $opfPath)
        $manifest = @{}
        $coverId = ''
        $coverPath = ''

        foreach ($node in @($opf.SelectNodes('/*[local-name()="package"]/*[local-name()="manifest"]/*[local-name()="item"]'))) {
            $id = Get-EpubElementAttribute -Node $node -Name 'id'
            $href = Get-EpubElementAttribute -Node $node -Name 'href'
            if ($id -eq '' -or $href -eq '') { throw 'EPUBのmanifestにidまたはhrefがありません' }
            if ($manifest.ContainsKey($id)) { throw "manifestに重複IDがあります: $id" }
            $entryPath = Resolve-EpubPath -Referer $opfPath -Href $href
            $mediaType = Get-EpubElementAttribute -Node $node -Name 'media-type'
            $manifest[$id] = [pscustomobject]@{
                Path = $entryPath
                MediaType = $mediaType
            }
            $properties = Get-EpubElementAttribute -Node $node -Name 'properties'
            if (($properties -split '\s+') -contains 'cover-image') { $coverPath = $entryPath }
        }
        foreach ($node in @($opf.SelectNodes('/*[local-name()="package"]/*[local-name()="metadata"]/*[local-name()="meta"]'))) {
            if ((Get-EpubElementAttribute -Node $node -Name 'name') -eq 'cover') {
                $coverId = Get-EpubElementAttribute -Node $node -Name 'content'
            }
        }
        if ($coverPath -eq '' -and $coverId -ne '' -and $manifest.ContainsKey($coverId)) {
            $coverPath = $manifest[$coverId].Path
        }

        $pagePaths = [System.Collections.Generic.List[string]]::new()
        $spine = @($opf.SelectNodes('/*[local-name()="package"]/*[local-name()="spine"]/*[local-name()="itemref"]'))
        if ($spine.Count -eq 0) { throw 'EPUBにspine（読書順）がありません' }
        foreach ($itemref in $spine) {
            if ((Get-EpubElementAttribute -Node $itemref -Name 'linear') -eq 'no') { continue }
            $idref = Get-EpubElementAttribute -Node $itemref -Name 'idref'
            if (-not $manifest.ContainsKey($idref)) { throw "spineの参照先がmanifestにありません: $idref" }
            $item = $manifest[$idref]
            $media = $item.MediaType.ToLowerInvariant()
            if ($media.StartsWith('image/') -and $media -ne 'image/svg+xml') {
                $pagePaths.Add($item.Path)
                continue
            }
            if ($media -notin @('application/xhtml+xml', 'text/html', 'image/svg+xml')) {
                throw "未対応のEPUB本文形式です: $($item.MediaType) / $($item.Path)"
            }
            $pageXml = Read-EpubXml -Entry (Get-EpubArchiveEntry -Archive $archive -Path $item.Path)
            # XPath union preserves XML document order. An SVG image wrapper is a page too.
            $imageNodes = @($pageXml.SelectNodes('//*[local-name()="img" or local-name()="image" or local-name()="object"]'))
            $countBefore = $pagePaths.Count
            foreach ($imageNode in $imageNodes) {
                $name = $imageNode.LocalName
                $reference = if ($name -eq 'object') {
                    Get-EpubElementAttribute -Node $imageNode -Name 'data'
                }
                elseif ($name -eq 'img') {
                    Get-EpubElementAttribute -Node $imageNode -Name 'src'
                }
                else {
                    Get-EpubElementAttribute -Node $imageNode -Name 'href'
                }
                if ([string]::IsNullOrWhiteSpace($reference)) { continue }
                $pagePaths.Add((Resolve-EpubPath -Referer $item.Path -Href $reference))
            }
            if ($pagePaths.Count -eq $countBefore) {
                # Fail safely rather than silently losing text, vector-only SVG, or CSS pages.
                throw "画像参照がないEPUB本文ページです（文字主体・CSS背景・SVG図形などは未対応）: $($item.Path)"
            }
        }
        if ($pagePaths.Count -eq 0) { throw 'EPUBの本文から画像ページを取得できません' }

        # Cover may be provided only as OPF metadata and not appear in the spine.
        # Include it once at the start; never duplicate a page already in the spine.
        $hasCoverPage = $false
        foreach ($page in $pagePaths) {
            if ($page -ieq $coverPath) { $hasCoverPage = $true; break }
        }
        if ($coverPath -ne '' -and -not $hasCoverPage) {
            $pagePaths.Insert(0, $coverPath)
        }
        if ($pagePaths.Count -gt 20000) { throw 'EPUBのページ数が多すぎます（20,000ページ超）' }

        New-Item -ItemType Directory -Path $ExtractionDir -Force | Out-Null
        $width = [Math]::Max(3, $pagePaths.Count.ToString().Length)
        $valid = @('.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.avif')
        $pages = [System.Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $pagePaths.Count; $index++) {
            $pagePath = $pagePaths[$index]
            $entry = Get-EpubArchiveEntry -Archive $archive -Path $pagePath
            $ext = [IO.Path]::GetExtension($pagePath).ToLowerInvariant()
            if ($ext -notin $valid) {
                throw "未対応のEPUB画像形式です: $pagePath（JPEG / PNG / WebP / GIF / BMP / AVIFのみ対応）"
            }
            if ($entry.Length -le 0) { throw "中身が空の画像です: $pagePath" }
            $number = ($index + 1).ToString('D' + $width)
            $filePath = Join-Path $ExtractionDir ($number + $ext)
            $sourceStream = $entry.Open()
            $destStream = $null
            try {
                $destStream = [IO.File]::Create($filePath)
                $sourceStream.CopyTo($destStream)
            }
            finally {
                if ($null -ne $destStream) { $destStream.Dispose() }
                $sourceStream.Dispose()
            }
            Test-EpubExtractedImage -FilePath $filePath -Extension $ext
            $pages.Add((Get-Item -LiteralPath $filePath))
        }
        # Emit the files in spine order, not by their original filename.
        foreach ($page in $pages) { Write-Output $page }
    }
    finally { $archive.Dispose() }
}