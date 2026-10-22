#requires -Version 7.6
<#
MangaSplit: first image -> centered cover; subsequent images -> right/left pages.
Sources are never modified. Output is a new sibling _裁断.cbz.
#>
param(
    [Parameter(Position=0, ValueFromRemainingArguments=$true)]
    [string[]]$Inputs
)
$ErrorActionPreference='Stop'
if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -ne 7 -or
    $PSVersionTable.PSVersion.Minor -ne 6) {
    throw 'Windows and PowerShell 7.6.x are required.'
}
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$jpegCodec = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
    Where-Object MimeType -eq 'image/jpeg' | Select-Object -First 1
if ($null -eq $jpegCodec) { throw 'JPEG encoder is unavailable.' }

function Get-NaturalKey([string]$name) {
    $pad=[Text.RegularExpressions.MatchEvaluator] {
        param($match)
        $match.Value.PadLeft(15, '0')
    }
    [regex]::Replace($name, '\d+', $pad)
}

function Get-Unrar {
    $candidates=@(
        "$env:ProgramFiles\WinRAR\UnRAR.exe",
        "$env:ProgramFiles\WinRAR\WinRAR.exe",
        "${env:ProgramFiles(x86)}\WinRAR\UnRAR.exe",
        "${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe"
    )
    foreach($p in $candidates){
        if($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
    }
    foreach($name in @('UnRAR.exe','WinRAR.exe')){
        $p=Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if($p){return $p.Source}
    }
    throw 'RAR files require WinRAR or UnRAR.'
}

function Expand-Manga([IO.FileSystemInfo]$item, [string]$destination) {
    if($item -is [IO.DirectoryInfo]) { return $item.FullName }
    switch($item.Extension.ToLowerInvariant()){
        {$_ -in @('.zip','.cbz')} {
            [IO.Compression.ZipFile]::ExtractToDirectory($item.FullName, $destination)
            return $destination
        }
        '.rar' {
            $extractor=Get-Unrar
            $info=[Diagnostics.ProcessStartInfo]::new()
            $info.FileName=$extractor
            $info.UseShellExecute=$false
            foreach($arg in @('x','-y','-o+','-inul',$item.FullName,($destination.TrimEnd('\')+'\'))){
                [void]$info.ArgumentList.Add($arg)
            }
            $process=[Diagnostics.Process]::Start($info)
            if($null -eq $process){throw 'Unable to launch WinRAR/UnRAR.'}
            try{
                $process.WaitForExit()
                if($process.ExitCode -ne 0){throw "RAR extractor failed ($($process.ExitCode))."}
            } finally {$process.Dispose()}
            return $destination
        }
        default { throw "Unsupported file: $($item.Extension)" }
    }
}

function Save-Page(
    [Drawing.Bitmap]$source, [Drawing.Rectangle]$selection, [string]$path, [string]$format
) {
    if($selection.Width -lt 1 -or $selection.Height -lt 1){throw 'Invalid crop rectangle.'}
    $pixelFormat=if($format -eq 'png'){
        [Drawing.Imaging.PixelFormat]::Format32bppArgb
    } else {
        [Drawing.Imaging.PixelFormat]::Format24bppRgb
    }
    $copy=[Drawing.Bitmap]::new($selection.Width,$selection.Height,$pixelFormat)
    try{
        $g=[Drawing.Graphics]::FromImage($copy)
        try{
            $g.CompositingMode=[Drawing.Drawing2D.CompositingMode]::SourceCopy
            $g.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
            $g.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::Half
            $target=[Drawing.Rectangle]::new(0,0,$selection.Width,$selection.Height)
            $g.DrawImage($source,$target,$selection,[Drawing.GraphicsUnit]::Pixel)
        } finally {$g.Dispose()}
        if($format -eq 'png'){
            $copy.Save($path,[Drawing.Imaging.ImageFormat]::Png)
        } else {
            $options=[Drawing.Imaging.EncoderParameters]::new(1)
            try {
                $options.Param[0]=[Drawing.Imaging.EncoderParameter]::new(
                    [Drawing.Imaging.Encoder]::Quality,[long]95)
                $copy.Save($path,$script:jpegCodec,$options)
            } finally {$options.Dispose()}
        }
    } finally {$copy.Dispose()}
}

function Get-Output([string]$parent,[string]$base){
    $candidate=Join-Path $parent ($base+'_裁断.cbz')
    $i=2
    while(Test-Path -LiteralPath $candidate){
        $candidate=Join-Path $parent ("{0}_裁断 ({1}).cbz" -f $base,$i)
        $i++
    }
    return $candidate
}

function Copy-Metadata([IO.FileInfo[]]$files,[string]$to){
    $xml=@($files | Where-Object Name -ieq 'ComicInfo.xml' |
        Sort-Object FullName | Select-Object -First 1)
    if($xml.Count -eq 0){return}
    try {
        $document=[Xml.XmlDocument]::new()
        $document.Load($xml[0].FullName)
        $node=$document.SelectSingleNode('/*[local-name()="ComicInfo"]/*[local-name()="Pages"]')
        if($node){[void]$node.ParentNode.RemoveChild($node)}
        $document.Save((Join-Path $to 'ComicInfo.xml'))
    } catch {
        Write-Warning "ComicInfo.xml not preserved: $($_.Exception.Message)"
    }
}

function Process-Manga([string]$path){
    $item=Get-Item -LiteralPath $path -ErrorAction Stop
    if(-not ($item -is [IO.DirectoryInfo]) -and
        $item.Extension.ToLowerInvariant() -notin @('.zip','.cbz','.rar')){
        throw 'Drop a folder, ZIP, CBZ or RAR file.'
    }
    $parent=Split-Path -Parent $item.FullName
    $base=if($item -is [IO.DirectoryInfo]){$item.Name}else{$item.BaseName}
    if($base -match '_裁断(?: \(\d+\))?$'){
        throw 'Already-split input is not supported.'
    }
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('MangaSplit_'+[guid]::NewGuid().ToString('N'))
    $unpacked=Join-Path $temp 'unpacked'
    $pages=Join-Path $temp 'pages'
    $packed=Join-Path $temp 'result.cbz'
    $stage=$null
    [void][IO.Directory]::CreateDirectory($unpacked)
    [void][IO.Directory]::CreateDirectory($pages)
    try{
        $root=Expand-Manga $item $unpacked
        $images=@(Get-ChildItem -LiteralPath $root -Recurse -File |
            Where-Object {
                $_.Extension.ToLowerInvariant() -in @('.jpg','.jpeg','.png') -and
                $_.Name -notlike '._*' -and
                $_.FullName -notmatch '[\\/]__MACOSX[\\/]'
            } | Sort-Object @{Expression={Get-NaturalKey $_.FullName}})
        if($images.Count -eq 0){throw 'No JPG/JPEG/PNG images found.'}
        # Image names are not standardized: the first page in natural order
        # is the cover, whether called 001, 01, 0001 or title-prefixed.
        $cover=$images[0]
        $spreads=@($images | Select-Object -Skip 1)
        Write-Host ("Cover (first image): {0}" -f $cover.Name)
        Write-Host ('Images: {0}, output pages: {1}' -f $images.Count,(1+2*$spreads.Count))
        $index=1
        foreach($file in @($cover)+$spreads){
            $image=[Drawing.Bitmap]::new($file.FullName)
            try{
                $width=$image.Width
                $height=$image.Height
                if($width -lt 2 -or $height -lt 1){throw "Image is too small: $($file.Name)"}
                $half=[int][Math]::Floor($width/2)
                $format=if($file.Extension.ToLowerInvariant() -in @('.jpg','.jpeg')){'jpg'}else{'png'}
                $selections=if($file.FullName -eq $cover.FullName){
                    @([Drawing.Rectangle]::new([int][Math]::Floor(($width-$half)/2),0,$half,$height))
                } else {
                    @(
                        [Drawing.Rectangle]::new($half,0,$width-$half,$height),
                        [Drawing.Rectangle]::new(0,0,$half,$height)
                    )
                }
                foreach($selection in $selections){
                    $name=('{0:D4}.{1}' -f $index,$format)
                    Save-Page $image $selection (Join-Path $pages $name) $format
                    $index++
                }
            } finally {$image.Dispose()}
        }
        $files=@(Get-ChildItem -LiteralPath $root -Recurse -File)
        Copy-Metadata $files $pages
        [IO.Compression.ZipFile]::CreateFromDirectory(
            $pages,$packed,[IO.Compression.CompressionLevel]::Optimal,$false)
        $output=Get-Output $parent $base
        $stage=Join-Path $parent ('.MangaSplit_'+[guid]::NewGuid().ToString('N')+'.tmp')
        [IO.File]::Copy($packed,$stage,$false)
        [IO.File]::Move($stage,$output)
        $stage=$null
        Write-Host "Saved: $output" -ForegroundColor Green
    } finally {
        if($stage -and (Test-Path -LiteralPath $stage)){
            Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        }
        if(Test-Path -LiteralPath $temp){
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if(-not $Inputs -or $Inputs.Count -eq 0){
    throw 'Drop folders, ZIP, CBZ or RAR files onto MangaSplit.bat.'
}
$failed=0
foreach($path in $Inputs){
    Write-Host "`nInput: $path" -ForegroundColor Cyan
    try { Process-Manga $path }
    catch {
        $failed++
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}
Write-Host ("`nResult: {0} succeeded, {1} failed" -f ($Inputs.Count-$failed),$failed)
if($failed -ne 0){throw ("MangaSplit: {0} input(s) failed. See errors above." -f $failed)}
