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
function Write-Scanned([string]$folder) {
    # Off-white paper, nombre marks in the outer margins and gray scanner edges.
    [void][IO.Directory]::CreateDirectory($folder)
    $paper=[Drawing.Color]::FromArgb(236,229,212)
    $shapes=@(
        @(@([Drawing.Color]::Lime,125,0,150,200)),
        @(
            @([Drawing.Color]::Gray,0,0,2,200),
            @([Drawing.Color]::Gray,398,0,2,200),
            @([Drawing.Color]::Red,50,0,150,200),
            @([Drawing.Color]::Blue,200,0,150,200),
            @([Drawing.Color]::Black,20,185,8,5),
            @([Drawing.Color]::Black,372,185,8,5)
        )
    )
    for($page=1;$page -le 2;$page++){
        $b=[Drawing.Bitmap]::new(400,200)
        try {
            $g=[Drawing.Graphics]::FromImage($b)
            try {
                $g.Clear($paper)
                foreach($shape in $shapes[$page-1]){
                    $brush=[Drawing.SolidBrush]::new($shape[0])
                    try { $g.FillRectangle($brush,$shape[1],$shape[2],$shape[3],$shape[4]) }
                    finally { $brush.Dispose() }
                }
            } finally {$g.Dispose()}
            $b.Save((Join-Path $folder ('{0:D4}.png' -f $page)),[Drawing.Imaging.ImageFormat]::Png)
        } finally {$b.Dispose()}
    }
}
function Write-Blank([string]$folder) {
    [void][IO.Directory]::CreateDirectory($folder)
    foreach($page in @(1,2)){
        $b=[Drawing.Bitmap]::new(64,20)
        try {
            $g=[Drawing.Graphics]::FromImage($b)
            try { $g.Clear([Drawing.Color]::White) } finally {$g.Dispose()}
            $b.Save((Join-Path $folder ('{0:D4}.png' -f $page)),[Drawing.Imaging.ImageFormat]::Png)
        } finally {$b.Dispose()}
    }
}
function Get-Widths([string]$path) {
    $out=Join-Path $temp ([guid]::NewGuid().ToString('N'))
    [IO.Compression.ZipFile]::ExtractToDirectory($path,$out)
    foreach($file in @(Get-ChildItem -LiteralPath $out -File -Filter '*.png' | Sort-Object Name)){
        $b=[Drawing.Bitmap]::new($file.FullName)
        try { $b.Width } finally {$b.Dispose()}
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
                Assert ($b.Width -ge ($widths[$i] - 2) -and $b.Width -le ($widths[$i] + 4)) "JPEG trim wrong width page ${i}: $($b.Width)"
            } else {
                Assert ($b.Width -eq $widths[$i]) "margin not trimmed page ${i}: $($b.Width) expected $($widths[$i])"
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

    $wide=Join-Path $temp 'wide44'
    Write-Source $wide 14 'png'
    & pwsh.exe -NoLogo -NoProfile -File $split $wide
    Assert ($LASTEXITCODE -eq 0) 'wide margin processing failed'
    # 14px of a 32px half-page (about 44%) is still under the 45% cap.
    Check (Join-Path $temp 'wide44_裁断.cbz') @(18,18,18) $false

    $blank=Join-Path $temp 'blank'
    Write-Blank $blank
    & pwsh.exe -NoLogo -NoProfile -File $split $blank
    Assert ($LASTEXITCODE -eq 0) 'blank page processing failed'
    $widths=@(Get-Widths (Join-Path $temp 'blank_裁断.cbz'))
    Assert (($widths -join ',') -eq '32,32,32') "blank pages must keep their width: $($widths -join ',')"

    $scanned=Join-Path $temp 'scanned'
    Write-Scanned $scanned
    & pwsh.exe -NoLogo -NoProfile -File $split $scanned
    Assert ($LASTEXITCODE -eq 0) 'scanned margin processing failed'
    # Content 150px plus the 2px safety cushion on each trimmed side.
    $widths=@(Get-Widths (Join-Path $temp 'scanned_裁断.cbz'))
    Assert (($widths -join ',') -eq '154,152,152') "scanned outer margins not trimmed: $($widths -join ',')"
    Write-Host 'PASS: alternating outer margins, centered cover, JPEG, wide margins, blank pages, nombre/paper tint/scan edges.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
