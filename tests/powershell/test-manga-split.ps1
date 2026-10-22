#requires -Version 7.6
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script = Join-Path $repo 'scripts/MangaSplit.ps1'
$bat = Get-Content -LiteralPath (Join-Path $repo 'MangaSplit.bat') -Raw -ErrorAction SilentlyContinue
if (-not $bat -or $bat -notmatch 'MangaSplit.ps1') { throw 'MangaSplit.bat entrypoint missing' }
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
    $bad=Join-Path $temp 'no-cover'
    [void][IO.Directory]::CreateDirectory($bad)
    New-Image (Join-Path $bad '002.png') 16 4 $false
    & pwsh.exe -NoLogo -NoProfile -File $script $bad
    Ensure ($LASTEXITCODE -ne 0) 'missing 001 should fail'
    Ensure (-not (Test-Path -LiteralPath (Join-Path $temp 'no-cover_裁断.cbz'))) 'bad input produced output'
    Write-Host 'MangaSplit synthetic smoke tests passed.'
} finally {
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force -Recurse}
}
