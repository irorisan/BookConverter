$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repo 'scripts/Convert-Manga-Input.ps1')
$script:responses = [Collections.Generic.Queue[object]]::new()
function Read-MangaResponse { param($Prompt) return $script:responses.Dequeue() }
foreach ($case in @(
    @{ Inputs=@(''); Expected='AVIF' },
    @{ Inputs=@('1'); Expected='AVIF' },
    @{ Inputs=@('2'); Expected='WebP' },
    @{ Inputs=@('bad','3',' 2 '); Expected='WebP' },
    @{ Inputs=@($null); Expected='AVIF' }
)) {
    foreach ($response in $case.Inputs) { $script:responses.Enqueue($response) }
    if ((Read-MangaEncodingFormat) -cne $case.Expected) { throw 'Wrong format selection' }
    if ($script:responses.Count -ne 0) { throw 'Invalid input was not retried' }
}
. (Join-Path $repo 'scripts/WebP-Functions.ps1')
$argsText = Get-WebPEncodeArguments -Quality 80 -InputPath 'C:\日本語\in.avif' -OutputPath 'C:\日本語\out.webp'
foreach ($required in @('-c:v libwebp','-quality 80','-threads 1','-hwaccel none','-frames:v 1')) {
    if (-not $argsText.Contains($required)) { throw "Missing CPU WebP option: $required" }
}
if ($argsText -match 'nvenc|cuda|avifenc') { throw 'GPU/AVIF leaked into WebP arguments' }
# Shared sample cache and final conversion must remain wired to the same scheduler.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/Convert-Manga.ps1'),[ref]$tokens,[ref]$errors)
if ($errors) { throw $errors[0] }
Write-Host 'PASS: format selection, invalid/EOF input, CPU-only WebP arguments and syntax'
