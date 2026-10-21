$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $root 'scripts\Convert-Manga-Zip.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$work = Join-Path ([IO.Path]::GetTempPath()) ('BookConverterZip_' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $work | Out-Null
    $source = Join-Path $work 'input.bin'
    [IO.File]::WriteAllBytes($source, [byte[]]@(0, 1, 127, 128, 255))
    $destination = Join-Path $work 'zip64.cbz'
    # ZIP64 entry-count boundary without creating a multi-gigabyte fixture.
    $paths = New-Object string[] 65535
    $names = New-Object string[] 65535
    for ($i = 0; $i -lt $paths.Length; $i++) {
        $paths[$i] = $source
        $names[$i] = '日本語 ページ{0:D5}.png' -f $i
    }
    [MangaStoredZip]::Write($destination, $paths, $names)
    $zip = [IO.Compression.ZipFile]::OpenRead($destination)
    try {
        if ($zip.Entries.Count -ne 65535) { throw 'ZIP64 count mismatch' }
        if ($zip.Entries[65534].FullName -cne $names[65534]) { throw 'UTF-8 name/order mismatch' }
        $entryStream = $zip.Entries[65534].Open()
        try {
            foreach ($expected in @(0, 1, 127, 128, 255)) {
                if ($entryStream.ReadByte() -ne $expected) { throw 'ZIP64 payload mismatch' }
            }
            if ($entryStream.ReadByte() -ne -1) { throw 'Unexpected payload bytes' }
        }
        finally { $entryStream.Dispose() }
    }
    finally { $zip.Dispose() }
    $before = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    $threw = $false
    try { [MangaStoredZip]::Write($destination, @($source), @('overwrite.png')) } catch { $threw = $true }
    if (-not $threw -or (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $before) {
        throw 'Existing ZIP was overwritten'
    }
    Write-Host 'PASS: ZIP64 count boundary, UTF-8 names, payload, no overwrite'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
