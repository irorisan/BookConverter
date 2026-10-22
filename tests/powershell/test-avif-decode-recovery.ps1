#requires -Version 7.6
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repo 'scripts/GPU-Functions.ps1')

function Assert-True {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('AvifCpuDecodeTest_' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp -Force)
try {
    # Real child-process test: fake avifdec, never load FFmpeg or GPU codecs.
    $fakeDecoder=Join-Path $temp 'fake_decoder.ps1'
    @'
param([string]$InputPath,[string]$OutputPath)
if ($InputPath -match 'bad|absent') {
    if ($InputPath -match 'absent') { exit 0 }
    exit 4
}
[IO.File]::WriteAllBytes($OutputPath, [byte[]](137,80,78,71,13,10,26,10))
exit 0
'@ | Set-Content -LiteralPath $fakeDecoder -Encoding UTF8

    # Replace only the argument builder; the production process lifecycle executes.
    $script:decoderCommandCount=0
    function Get-AvifDecodeArguments {
        param([string]$InputPath,[string]$OutputPath)
        $script:decoderCommandCount++
        return ('-NoLogo -NoProfile -NonInteractive -File "{0}" "{1}" "{2}"' -f $fakeDecoder,$InputPath,$OutputPath)
    }
    $pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
    $paths=[string[]]@('C:\test\正常 01.avif','C:\test\bad_02.avif','C:\test\absent_03.avif','C:\test\good_04.avif')
    $failed=[string[]]@(Invoke-CpuVerifyAvifSamples -Paths $paths -Avifdec $pwsh `
        -ScratchDir $temp -TimeoutSeconds 30 -ReturnFailedPaths)
    Assert-True ($failed.Count -eq 2 -and $failed[0] -eq $paths[1] -and $failed[1] -eq $paths[2]) 'CPU decoder must report only bad or no-output AVIF'
    Assert-True ($script:decoderCommandCount -eq 4) 'Every sample must invoke the CPU decoder exactly once'
    Assert-True (@(Get-ChildItem -LiteralPath $temp -Recurse -Filter '*.png' -File).Count -eq 0) 'Temporary verification PNGs must be deleted'
    Assert-True (@(Get-ChildItem -LiteralPath $temp -Directory -Filter 'avif_verify_*').Count -eq 0) 'Temporary verification directories must be deleted'

    $failed=[string[]]@(Invoke-CpuVerifyAvifSamples -Paths ([string[]]@($paths[0])) -Avifdec $pwsh `
        -ScratchDir $temp -TimeoutSeconds 30 -ReturnFailedPaths)
    Assert-True ($failed.Count -eq 0) 'Valid AVIF must pass CPU-only verification'
    $refused=$false
    try {
        Invoke-CpuVerifyAvifSamples -Paths ([string[]]@($paths[1])) -Avifdec $pwsh `
            -ScratchDir $temp -TimeoutSeconds 30
    } catch { $refused=$_.Exception.Message -match 'AVIF|デコード' }
    Assert-True $refused 'Invalid AVIF must stop commit when failures are not returned'

    $cancel=Join-Path $temp 'cancel.flag'
    [IO.File]::WriteAllText($cancel,'1')
    $refused=$false
    try {
        Invoke-CpuVerifyAvifSamples -Paths ([string[]]@($paths[0])) -Avifdec $pwsh `
            -ScratchDir $temp -TimeoutSeconds 30 -CancelFile $cancel -ReturnFailedPaths | Out-Null
    } catch { $refused=$_.Exception.Message -match 'cancel' }
    Assert-True $refused 'Cancellation must fail rather than treat AVIF as invalid'

    # Existing CPU recovery retains original source identity and refuses source AVIF.
    $originals=@(
        [pscustomobject]@{SourcePath='C:\orig\a.png';EntryName='a.avif';Length=100L;NeedsConversion=$true;Extension='.png';EncodedBy=''},
        [pscustomobject]@{SourcePath='C:\orig\b.avif';EntryName='b.avif';Length=100L;NeedsConversion=$false;Extension='.avif';EncodedBy=''}
    )
    $converted=@(
        [pscustomobject]@{SourcePath='C:\temp\a.avif';EntryName='a.avif';Length=40L;NeedsConversion=$false;Extension='.png';EncodedBy='Gpu'},
        [pscustomobject]@{SourcePath='C:\orig\b.avif';EntryName='b.avif';Length=100L;NeedsConversion=$false;Extension='.avif';EncodedBy=''}
    )
    $plan=@(Get-AvifCpuRecoveryPlan -Entries $converted -OriginalEntries $originals -FailedPaths ([string[]]@('C:\temp\a.avif')))
    Assert-True ($plan.Count -eq 1 -and $plan[0].Entry.SourcePath -eq 'C:\orig\a.png') 'CPU recovery must take intact original data'
    $refused=$false
    try { [void](Get-AvifCpuRecoveryPlan -Entries $converted -OriginalEntries $originals -FailedPaths ([string[]]@('C:\orig\b.avif'))) } catch { $refused=$true }
    Assert-True $refused 'Preexisting AVIF may not be recompressed'

    # Final production caller may not invoke FFmpeg to validate AVIF.
    $source=Get-Content -LiteralPath (Join-Path $repo 'scripts/Convert-Manga.ps1') -Raw -Encoding UTF8
    Assert-True ($source -match 'Invoke-CpuVerifyAvifSamples' -and $source -match 'Find-OrInstall-Avifdec') 'Production must use CPU avifdec'
    Assert-True ($source -notmatch 'Invoke-GpuVerifyAvifBatch') 'FFmpeg validation caller must be removed'
    Assert-True (-not (Get-Command 'Get-GpuVerifyArguments' -CommandType Function -ErrorAction SilentlyContinue)) 'FFmpeg verification helper must be removed'
    Write-Host 'PASS: CPU libavif isolation, failures, missing output, cleanup, cancellation and recovery'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
