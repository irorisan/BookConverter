#requires -Version 7.6
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script = Join-Path $repo 'scripts/MangaSplit.ps1'
$bat = Get-Content -LiteralPath (Join-Path $repo 'MangaSplit.bat') -Raw -ErrorAction SilentlyContinue
if (-not $bat -or $bat -notmatch 'Start-BookConverter-Terminal.ps1' -or $bat -notmatch '-Mode Split') { throw 'MangaSplit.bat Terminal entrypoint missing' }
if (-not (Test-Path -LiteralPath $script)) { throw 'MangaSplit.ps1 missing' }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('BookSplitTest_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
function Ensure($condition, $message) { if (-not $condition) { throw $message } }
function New-Image([string]$path,[int]$width,[int]$height,[bool]$cover) {
    $b=[Drawing.Bitmap]::new($width,$height)
    try {
        for($y=0;$y -lt $height;$y++){for($x=0;$x -lt $width;$x++){
            $color = if ($cover) {
                if($x -ge ($width / 4) -and $x -lt ($width * 3 / 4)) {[Drawing.Color]::Lime} else {[Drawing.Color]::Black}
            } elseif($x -lt ($width / 2)) {[Drawing.Color]::Red} else {[Drawing.Color]::Blue}
            $b.SetPixel($x,$y,$color)
        }}
        $b.Save($path,[Drawing.Imaging.ImageFormat]::Png)
    } finally { $b.Dispose() }
}
function Test-Result([string]$archive) {
    $d=Join-Path $temp ('check_'+[guid]::NewGuid().ToString('N'))
    [IO.Compression.ZipFile]::ExtractToDirectory($archive,$d)
    $p=@(Get-ChildItem -LiteralPath $d -Filter '*.png' | Sort-Object Name)
    Ensure ($p.Count -eq 3) "wrong page count for $archive"
    Ensure (($p.Name -join ',') -eq '0001.png,0002.png,0003.png') 'page numbering'
    $colors=@('Lime','Blue','Red')
    for($i=0;$i -lt 3;$i++){
        $b=[Drawing.Bitmap]::new($p[$i].FullName)
        try {
            Ensure ($b.Width -eq 8 -and $b.Height -eq 4) 'unexpected resize or crop'
            Ensure ($b.GetPixel(2,1).ToArgb() -eq ([Drawing.Color]::FromName($colors[$i])).ToArgb()) "incorrect page order at $i"
        } finally { $b.Dispose() }
    }
    $xml=Join-Path $d 'ComicInfo.xml'
    Ensure (Test-Path -LiteralPath $xml) 'ComicInfo missing'
    $doc=[xml](Get-Content -LiteralPath $xml -Raw)
    Ensure ($doc.ComicInfo.Series -eq 'Synthetic') 'series metadata missing'
    Ensure ($null -eq $doc.ComicInfo.Pages) 'obsolete Pages metadata remained'
}
try {
    $source=Join-Path $temp 'source'
    [void][IO.Directory]::CreateDirectory($source)
    New-Image (Join-Path $source '001.png') 16 4 $true
    New-Image (Join-Path $source '002.png') 16 4 $false
    [IO.File]::WriteAllText((Join-Path $source 'ComicInfo.xml'),'<ComicInfo><Series>Synthetic</Series><Pages><Page Image="0" /></Pages></ComicInfo>')
    $archive=Join-Path $temp '合成 & 1.cbz'
    [IO.Compression.ZipFile]::CreateFromDirectory($source,$archive)
    $before=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    & pwsh.exe -NoLogo -NoProfile -File $script $archive
    Ensure ($LASTEXITCODE -eq 0) 'archive conversion failed'
    $result=Join-Path $temp '合成 & 1_裁断.cbz'
    Ensure (Test-Path -LiteralPath $result) 'result missing'
    Test-Result $result
    Ensure ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -eq $before) 'original was modified'
    & pwsh.exe -NoLogo -NoProfile -File $script $archive $source
    Ensure ($LASTEXITCODE -eq 0) 'mixed duplicate archive/folder failed'
    Ensure (Test-Path -LiteralPath (Join-Path $temp '合成 & 1_裁断 (2).cbz')) 'collision should create a unique name'
    Ensure (Test-Path -LiteralPath (Join-Path $temp 'source_裁断.cbz')) 'folder input output missing'
    # Real manga often uses title prefixes or a different zero-padding width.
    # No basename exactly '001' should be required.
    $prefixed=Join-Path $temp '巻名 & 表紙'
    [void][IO.Directory]::CreateDirectory($prefixed)
    New-Image (Join-Path $prefixed '作品名01.png') 16 4 $true
    New-Image (Join-Path $prefixed '作品名02.png') 16 4 $false
    Copy-Item -LiteralPath (Join-Path $source 'ComicInfo.xml') -Destination $prefixed
    & pwsh.exe -NoLogo -NoProfile -File $script $prefixed
    Ensure ($LASTEXITCODE -eq 0) 'prefixed first image should be accepted'
    Test-Result (Join-Path $temp '巻名 & 表紙_裁断.cbz')

    $numeric=Join-Path $temp '自然順'
    [void][IO.Directory]::CreateDirectory($numeric)
    New-Image (Join-Path $numeric '作品名10.png') 16 4 $false
    New-Image (Join-Path $numeric '作品名2.png') 16 4 $true
    Copy-Item -LiteralPath (Join-Path $source 'ComicInfo.xml') -Destination $numeric
    & pwsh.exe -NoLogo -NoProfile -File $script $numeric
    Ensure ($LASTEXITCODE -eq 0) 'first image in natural numeric order must become cover'
    Test-Result (Join-Path $temp '自然順_裁断.cbz')

    # Even 002.png is valid as the first/only image; name is not a sentinel.
    $single=Join-Path $temp '単枚'
    [void][IO.Directory]::CreateDirectory($single)
    New-Image (Join-Path $single '002.png') 16 4 $true
    & pwsh.exe -NoLogo -NoProfile -File $script $single
    Ensure ($LASTEXITCODE -eq 0) 'first image not named 001 should work'
    $singleExtract=Join-Path $temp 'only-output'
    [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $temp '単枚_裁断.cbz'),$singleExtract)
    $singlePages=@(Get-ChildItem -LiteralPath $singleExtract -Filter '*.png')
    Ensure ($singlePages.Count -eq 1 -and $singlePages[0].Name -eq '0001.png') 'single image must be saved only as cover'

    $bad=Join-Path $temp 'empty-images'
    [void][IO.Directory]::CreateDirectory($bad)
    [IO.File]::WriteAllText((Join-Path $bad 'README.txt'),'No images')
    & pwsh.exe -NoLogo -NoProfile -File $script $bad
    Ensure ($LASTEXITCODE -ne 0) 'image-free input should fail'
    Ensure (-not (Test-Path -LiteralPath (Join-Path $temp 'empty-images_裁断.cbz'))) 'bad input produced output'
    # The final digit run must override numbers earlier in the file name,
    # even if alphabetical / natural path sorting would reverse the pages.
    $suffix=Join-Path $temp 'suffix first'
    [void][IO.Directory]::CreateDirectory($suffix)
    New-Image (Join-Path $suffix '13DL.me_Net_0002.png') 16 4 $false
    New-Image (Join-Path $suffix '99DL.me_Net_0001.png') 16 4 $true
    Copy-Item -LiteralPath (Join-Path $source 'ComicInfo.xml') -Destination $suffix
    & pwsh.exe -NoLogo -NoProfile -File $script $suffix
    Ensure ($LASTEXITCODE -eq 0) 'trailing page number should override earlier digits'
    Test-Result (Join-Path $temp 'suffix first_裁断.cbz')

    # Gaps are warned about, but splitting still succeeds.
    $gaps=Join-Path $temp 'gaps'
    [void][IO.Directory]::CreateDirectory($gaps)
    New-Image (Join-Path $gaps '13DL.me_Net_0001.png') 16 4 $true
    New-Image (Join-Path $gaps '13DL.me_Net_0004.png') 16 4 $false
    Copy-Item -LiteralPath (Join-Path $source 'ComicInfo.xml') -Destination $gaps
    $gapOutput=& pwsh.exe -NoLogo -NoProfile -File $script $gaps 2>&1 | Out-String
    Ensure ($LASTEXITCODE -eq 0) 'gap should not prevent splitting'
    Ensure ($gapOutput -match 'Missing page number') 'missing page number warning was not printed'
    Test-Result (Join-Path $temp 'gaps_裁断.cbz')

    # Normalized duplicate suffixes in distinct filenames cannot silently
    # choose an arbitrary reading order.
    $duplicate=Join-Path $temp 'duplicates'
    [void][IO.Directory]::CreateDirectory($duplicate)
    New-Image (Join-Path $duplicate '13DL.me_Net_0001.png') 16 4 $true
    New-Image (Join-Path $duplicate 'different_1.png') 16 4 $false
    & pwsh.exe -NoLogo -NoProfile -File $script $duplicate
    Ensure ($LASTEXITCODE -ne 0) 'duplicate numeric suffixes must fail'
    Ensure (-not (Test-Path -LiteralPath (Join-Path $temp 'duplicates_裁断.cbz'))) 'duplicate created an output'

    # Mixed numbered/un-numbered pages are ambiguous and must be rejected.
    $mixed=Join-Path $temp 'mixed numbered'
    [void][IO.Directory]::CreateDirectory($mixed)
    New-Image (Join-Path $mixed 'cover.png') 16 4 $true
    New-Image (Join-Path $mixed '13DL.me_Net_0002.png') 16 4 $false
    & pwsh.exe -NoLogo -NoProfile -File $script $mixed
    Ensure ($LASTEXITCODE -ne 0) 'mixed numbered and unnumbered images must fail'
    Ensure (-not (Test-Path -LiteralPath (Join-Path $temp 'mixed numbered_裁断.cbz'))) 'mixed suffixes created an output'

    # A volume with no numeric suffixes still permits natural sort.
    $unnumbered=Join-Path $temp 'unnumbered'
    [void][IO.Directory]::CreateDirectory($unnumbered)
    New-Image (Join-Path $unnumbered 'A_cover.png') 16 4 $true
    New-Image (Join-Path $unnumbered 'B_spread.png') 16 4 $false
    Copy-Item -LiteralPath (Join-Path $source 'ComicInfo.xml') -Destination $unnumbered
    & pwsh.exe -NoLogo -NoProfile -File $script $unnumbered
    Ensure ($LASTEXITCODE -eq 0) 'no suffixes should use natural-order fallback'
    Test-Result (Join-Path $temp 'unnumbered_裁断.cbz')

    Write-Host 'MangaSplit synthetic smoke tests passed.'
} finally {
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force -Recurse}
}
