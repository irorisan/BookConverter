#requires -Version 7.6
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$split=Join-Path $repo 'scripts/MangaSplit.ps1'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('SplitMargins_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
function Assert([bool]$ok,[string]$reason){if(-not $ok){throw $reason}}

function Write-Source([string]$folder,[int]$margin,[string]$ext) {
    [void][IO.Directory]::CreateDirectory($folder)
    foreach($page in @(1,2)){
        $b=[Drawing.Bitmap]::new(64,20)
        try {
            for($y=0;$y -lt 20;$y++){
                for($x=0;$x -lt 64;$x++){
                    $color=[Drawing.Color]::White
                    if($page -eq 1){
                        if($x -ge 16+$margin/2 -and $x -lt 48-$margin/2){
                            $color=[Drawing.Color]::Lime
                        }
                    } else {
                        if($x -ge $margin -and $x -lt 32){$color=[Drawing.Color]::Red}
                        if($x -ge 32 -and $x -lt 64-$margin){$color=[Drawing.Color]::Blue}
                    }
                    $b.SetPixel($x,$y,$color)
                }
            }
            $f=Join-Path $folder ('13DL.me_Net_{0:D4}.{1}' -f $page,$ext)
            $imageFormat=if($ext -eq 'jpg') { [Drawing.Imaging.ImageFormat]::Jpeg } else { [Drawing.Imaging.ImageFormat]::Png }
            $b.Save($f,$imageFormat)
        } finally {$b.Dispose()}
    }
}
function Check([string]$path,[int[]]$widths,[bool]$jpeg) {
    $out=Join-Path $temp ([guid]::NewGuid().ToString('N'))
    [IO.Compression.ZipFile]::ExtractToDirectory($path,$out)
    $files=@(Get-ChildItem -LiteralPath $out -File | Sort-Object Name)
    Assert ($files.Count -eq 3) 'expected cover and two split pages'
    $colors=@([Drawing.Color]::Lime,[Drawing.Color]::Blue,[Drawing.Color]::Red)
    for($i=0;$i -lt 3;$i++){
        $b=[Drawing.Bitmap]::new($files[$i].FullName)
        try{
            if($jpeg) {
                Assert ($b.Width -ge ($widths[$i] - 2) -and $b.Width -le ($widths[$i] + 4)) "JPEG trim wrong width page $i: $($b.Width)"
            } else {
                Assert ($b.Width -eq $widths[$i]) "margin not trimmed page $i: $($b.Width) expected $($widths[$i])"
            }
            Assert ($b.Height -eq 20) 'vertical resolution changed'
            $edge=$b.GetPixel([int]($b.Width/2),10)
            Assert ([Math]::Abs([int]$edge.R - [int]$colors[$i].R) -le 12) "page $i center red"
            Assert ([Math]::Abs([int]$edge.G - [int]$colors[$i].G) -le 12) "page $i center green"
            Assert ([Math]::Abs([int]$edge.B - [int]$colors[$i].B) -le 12) "page $i center blue"
        } finally {$b.Dispose()}
    }
}
try{
    $regular=Join-Path $temp 'margins25'
    Write-Source $regular 8 'png'
    $hash=(Get-FileHash -LiteralPath (Join-Path $regular '13DL.me_Net_0002.png') -Algorithm SHA256).Hash
    & pwsh.exe -NoLogo -NoProfile -File $split $regular
    Assert ($LASTEXITCODE -eq 0) 'processing edge margins failed'
    Check (Join-Path $temp 'margins25_裁断.cbz') @(24,24,24) $false
    Assert ($hash -eq (Get-FileHash -LiteralPath (Join-Path $regular '13DL.me_Net_0002.png') -Algorithm SHA256).Hash) 'source was modified'

    $jpeg=Join-Path $temp 'jpeg-margins'
    Write-Source $jpeg 8 'jpg'
    & pwsh.exe -NoLogo -NoProfile -File $split $jpeg
    Assert ($LASTEXITCODE -eq 0) 'JPEG processing failed'
    Check (Join-Path $temp 'jpeg-margins_裁断.cbz') @(24,24,24) $true

    $extreme=Join-Path $temp 'over35'
    Write-Source $extreme 14 'png'
    & pwsh.exe -NoLogo -NoProfile -File $split $extreme
    Assert ($LASTEXITCODE -eq 0) 'extreme margin should remain untrimmed'
    # Outside a 30% safety cap, leave those page images at half-width.
    Check (Join-Path $temp 'over35_裁断.cbz') @(18,32,32) $false
    Write-Host 'PASS: 25% alternating left/right margins, centered cover, JPEG, skip unsafe trims.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
