$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) { throw 'Requires Windows PowerShell 5.1' }
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $root 'scripts\Convert-Manga-Input.ps1')
function Assert-Paths {
    param([string]$Line, [string[]]$Expected)
    $actual = @(Split-MangaInput -Line $Line)
    if ($actual.Count -ne $Expected.Count) { throw "Count mismatch: $Line" }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ($actual[$i] -cne $Expected[$i]) { throw "Path mismatch: $Line" }
    }
}
Assert-Paths '' @()
Assert-Paths '   ' @()
Assert-Paths 'C:\漫画\空 白.cbz' @('C:\漫画\空 白.cbz')
Assert-Paths '"C:\漫画\空 白.cbz" "D:\さんかく\v02.cbz"' @('C:\漫画\空 白.cbz', 'D:\さんかく\v02.cbz')
Assert-Paths 'C:\a.cbz D:\b.cbz' @('C:\a.cbz', 'D:\b.cbz')
Assert-Paths '"C:\漫画\"' @('C:\漫画\')
Assert-Paths '"\\server\share\日本語 空白\"' @('\\server\share\日本語 空白\')
Assert-Paths '"C:\$(throw 1); & 漫画.cbz"' @('C:\$(throw 1); & 漫画.cbz')
foreach ($invalid in @('"C:\unclosed', '"C:\a"junk', 'relative.cbz', 'C:relative.cbz', '\rooted.cbz')) {
    $threw = $false
    try { $null = @(Split-MangaInput -Line $invalid) } catch { $threw = $true }
    if (-not $threw) { throw "Invalid input accepted: $invalid" }
}
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1') + @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1')) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ($bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw "Missing UTF-8 BOM: $file" }
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Syntax errors in ${file}: $errors" }
}
Write-Host 'PASS: literal input parser, PS1 syntax and UTF-8 BOM'
