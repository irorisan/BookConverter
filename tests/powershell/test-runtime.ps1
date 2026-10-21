$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $PSVersionTable.PSEdition -ne 'Core' -or
    $PSVersionTable.PSVersion.Major -ne 7 -or $PSVersionTable.PSVersion.Minor -ne 6 -or
    [Environment]::Version.Major -ne 10) { throw 'Requires Windows PowerShell 7.6 / .NET 10' }
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
foreach ($bat in Get-ChildItem -LiteralPath $repo -Filter '*.bat') {
    $text = [IO.File]::ReadAllText($bat.FullName)
    if ($text -match '(?i)powershell\.exe' -or $text -notmatch '(?im)^pwsh\.exe -NoLogo -NoProfile') {
        throw "BAT must launch pwsh.exe: $bat"
    }
}
$benchmark = [IO.File]::ReadAllText((Join-Path $repo 'scripts/Benchmark-Hybrid.ps1'))
if (-not $benchmark.Contains("Join-Path `$PSHOME 'pwsh.exe'")) { throw 'Benchmark must use the current PowerShell installation' }
foreach ($entry in @('Convert-Manga.ps1','Benchmark-Hybrid.ps1','Update-BookConverter.ps1')) {
    $text = [IO.File]::ReadAllText((Join-Path $repo "scripts/$entry"))
    if ($text -notmatch '(?im)^#requires -Version 7\.6' -or
        -not $text.Contains('$PSVersionTable.PSVersion.Minor -ne 6') -or -not $text.Contains('$IsWindows')) {
        throw "Missing supported runtime guard: $entry"
    }
}
# JSON defaults changed from 5.1: verify both bytes and Japanese text on .NET 10.
$work = Join-Path ([IO.Path]::GetTempPath()) ('BookConvRuntime_' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $work | Out-Null
    $path = Join-Path $work '日本語.json'
    @{Name='漫画 空白'; Pages=243} | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'JSON unexpectedly has a BOM' }
    $json = [Text.UTF8Encoding]::new($false,$true).GetString($bytes) | ConvertFrom-Json
    if ($json.Name -cne '漫画 空白' -or $json.Pages -ne 243) { throw 'UTF-8 JSON roundtrip failed' }
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
Write-Host "PASS: Windows PowerShell $($PSVersionTable.PSVersion) / .NET $([Environment]::Version), BATs, benchmark, UTF-8 JSON"
