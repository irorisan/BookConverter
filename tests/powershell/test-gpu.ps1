$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $repo 'GPU-Functions.ps1')

if ((Convert-GpuQualityToCq -Quality 30) -ne 50) { throw 'GPU quality low endpoint changed' }
if ((Convert-GpuQualityToCq -Quality 95) -ne 15) { throw 'GPU quality high endpoint changed' }
$previous = 100
foreach ($quality in 30..95) {
    $cq = Convert-GpuQualityToCq -Quality $quality
    if ($cq -gt $previous) { throw 'NVENC CQ mapping is non-monotonic' }
    $previous = $cq
}
$args = Get-GpuEncodeArguments -Quality 75 -InputPath 'C:\image.png' -OutputPath 'C:\image.avif'
foreach ($token in @('av1_nvenc', '-preset p4', '-f avif', '-pix_fmt yuv420p', '-frames:v 1', '-tune hq', '-rc vbr')) {
    if (-not $args.Contains($token)) { throw "GPU encoder argument missing: $token" }
}
foreach ($path in @((Join-Path $repo 'GPU-Functions.ps1'), (Join-Path $repo 'Convert-Manga.ps1'))) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw "PowerShell parse error in $path : $($errors[0])" }
}
foreach ($batch in @('Convert-Manga-GPU.bat', 'Convert-Manga-Magazine-GPU.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $repo $batch) -PathType Leaf)) {
        throw "Missing GPU BAT: $batch"
    }
}
Write-Host 'GPU quality mapping, command arguments, PowerShell syntax and BATs: OK'
