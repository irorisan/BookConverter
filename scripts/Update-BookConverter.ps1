#requires -Version 7.6
# BookConverter personal main-branch updater (PowerShell 7.6 on Windows).
# Run via Update-BookConverter.bat in the BookConverter root.
# Replaces GitHub-managed files, never touches tools/, .git/, or manga input/output.

param([string]$ArchivePath = '')

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -ne 7 -or $PSVersionTable.PSVersion.Minor -ne 6) {
    throw 'BookConverter requires PowerShell 7.6.x on Windows (pwsh.exe).'
}
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$archiveUrl = 'https://github.com/irorisan/BookConverter/archive/refs/heads/main.zip'
$work = Join-Path ([IO.Path]::GetTempPath()) ('BookConverterUpdate_' + [guid]::NewGuid().ToString('N'))
$zip = Join-Path $work 'main.zip'
$unpacked = Join-Path $work 'unpacked'
$backupRoot = Join-Path $work 'backup'
$processed = New-Object 'System.Collections.Generic.List[string]'
$hadFile = @{}
try {
    Write-Host 'BookConverter: downloading latest GitHub main...' -ForegroundColor Cyan
    New-Item -Path $work -ItemType Directory -Force | Out-Null

    if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
        Invoke-WebRequest -Uri $archiveUrl -OutFile $zip -TimeoutSec 180
    }
    else {
        # Offline fixture injection for the CI smoke test.
        Copy-Item -LiteralPath $ArchivePath -Destination $zip -Force
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force

    $source = Join-Path $unpacked 'BookConverter-main'
    foreach ($mandatory in @(
        'Convert-Manga.bat',
        'Convert-Manga-Magazine.bat',
        'Update-BookConverter.bat',
        'scripts\Convert-Manga.ps1',
        'scripts\GPU-Functions.ps1',
        'scripts\Update-BookConverter.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $mandatory) -PathType Leaf)) {
            throw "Invalid GitHub main archive: missing $mandatory. No local files updated."
        }
    }

    $files = @(Get-ChildItem -LiteralPath $source -File -Recurse |
        Where-Object {
            $relative = $_.FullName.Substring($source.Length).TrimStart('\','/')
            $relative -notmatch '^(?i:tools|\.git)(\\|/)'
        })
    if ($files.Count -eq 0) { throw 'GitHub main archive contained no update files.' }

    # Back up any overwritten files before applying the main archive.
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($source.Length).TrimStart('\','/')
        $destination = Join-Path $root $relative
        $backup = Join-Path $backupRoot $relative
        $exists = Test-Path -LiteralPath $destination -PathType Leaf
        if ($exists) {
            New-Item -Path (Split-Path -Parent $backup) -ItemType Directory -Force | Out-Null
            Copy-Item -LiteralPath $destination -Destination $backup -Force
        }
        $hadFile[$relative] = $exists
        $processed.Add($relative)
        New-Item -Path (Split-Path -Parent $destination) -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }

    Write-Host ('Updated from GitHub main: {0} files.' -f $files.Count) -ForegroundColor Green
    Write-Host 'Preserved: tools/ (ffmpeg.exe, avifenc.exe, dwebp.exe), local data and .git'
    Write-Host 'Layout: root BATs; PowerShell scripts in scripts/.'
}
catch {
    Write-Warning ('Update failed: ' + $_.Exception.Message)
    Write-Warning 'Rolling back modified files...'
    for ($i = $processed.Count - 1; $i -ge 0; $i--) {
        $relative = $processed[$i]
        $destination = Join-Path $root $relative
        $backup = Join-Path $backupRoot $relative
        try {
            if ($hadFile[$relative] -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
                Copy-Item -LiteralPath $backup -Destination $destination -Force
            }
            elseif (-not $hadFile[$relative] -and (Test-Path -LiteralPath $destination -PathType Leaf)) {
                Remove-Item -LiteralPath $destination -Force
            }
        }
        catch {
            Write-Warning ("Rollback failed for $relative : $($_.Exception.Message)")
        }
    }
    exit 1
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
