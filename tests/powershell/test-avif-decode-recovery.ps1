#requires -Version 7.6
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $root 'scripts/GPU-Functions.ps1')

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}

# A PowerShell child process simulates an FFmpeg decoder without a GPU.
# A multi-input crash must not blame all eight files; individual failures
# identify the one AVIF that needs CPU recovery.
$script:probeCounts=[System.Collections.Generic.List[int]]::new()
$script:failBatch=$true
function Get-GpuVerifyArguments {
    param([string[]]$Paths)
    $script:probeCounts.Add($Paths.Count)
    $bad=(@($Paths | Where-Object { $_ -like '*bad*' }).Count -gt 0)
    $fail=($script:failBatch -and $Paths.Count -gt 1) -or $bad
    $exitCode=if ($fail) { 1 } else { 0 }
    return ('-NoLogo -NoProfile -NonInteractive -Command "exit {0}"' -f $exitCode)
}
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
$batch=[string[]]@(0..7 | ForEach-Object { 'C:\sample\ok_{0:D2}.avif' -f $_ })
$failed=[string[]]@(Invoke-GpuVerifyAvifBatch -Paths $batch -FFmpeg $pwsh -Workers 1 -TimeoutSeconds 30 -ReturnFailedPaths)
Assert-True ($failed.Count -eq 0) 'A failed 8-input batch must pass after each singleton decodes successfully'
Assert-True ($script:probeCounts.Count -eq 9 -and $script:probeCounts[0] -eq 8 -and
    @($script:probeCounts | Where-Object { $_ -eq 1 }).Count -eq 8) 'Failed batch must isolate with eight singleton probes'

$script:failBatch=$false
$script:probeCounts.Clear()
$paths=[string[]]@('C:\sample\ok_00.avif','C:\sample\bad_01.avif','C:\sample\ok_02.avif')
$failed=[string[]]@(Invoke-GpuVerifyAvifBatch -Paths $paths -FFmpeg $pwsh -Workers 1 -TimeoutSeconds 30 -ReturnFailedPaths)
Assert-True ($failed.Count -eq 1 -and $failed[0] -eq $paths[1]) 'Only the truly invalid AVIF should be returned'
Assert-True ($script:probeCounts.Count -eq 4) 'Failed batch should trigger three singleton probes'

$originals=@(
    [pscustomobject]@{SourcePath='C:\original\0.png';EntryName='0.avif';Length=100L;NeedsConversion=$true;Extension='.png';EncodedBy=''},
    [pscustomobject]@{SourcePath='C:\original\1.png';EntryName='1.avif';Length=100L;NeedsConversion=$true;Extension='.png';EncodedBy=''},
    [pscustomobject]@{SourcePath='C:\original\2.avif';EntryName='2.avif';Length=100L;NeedsConversion=$false;Extension='.avif';EncodedBy=''}
)
$converted=@(
    [pscustomobject]@{SourcePath='C:\temp\0.avif';EntryName='0.avif';Length=40L;NeedsConversion=$false;Extension='.png';EncodedBy='Gpu'},
    [pscustomobject]@{SourcePath='C:\temp\1.avif';EntryName='1.avif';Length=40L;NeedsConversion=$false;Extension='.png';EncodedBy='Gpu'},
    [pscustomobject]@{SourcePath='C:\original\2.avif';EntryName='2.avif';Length=100L;NeedsConversion=$false;Extension='.avif';EncodedBy=''}
)
$plan=@(Get-AvifCpuRecoveryPlan -Entries $converted -OriginalEntries $originals -FailedPaths @('C:\temp\1.avif'))
Assert-True ($plan.Count -eq 1 -and $plan[0].Index -eq 1 -and
    $plan[0].Entry.SourcePath -eq 'C:\original\1.png' -and $plan[0].Entry.NeedsConversion) 'Recovery must point to the corresponding original page'
Assert-True ($converted[1].SourcePath -eq 'C:\temp\1.avif' -and $originals[1].SourcePath -eq 'C:\original\1.png') 'Planning must not mutate inputs'

$refused=$false
try {
    [void](Get-AvifCpuRecoveryPlan -Entries $converted -OriginalEntries $originals -FailedPaths @('C:\original\2.avif'))
} catch { $refused=($_.Exception.Message -match 'AVIF|原本|対象外') }
Assert-True $refused 'Preexisting AVIF must not silently be re-encoded'

Write-Host 'PASS: batch isolation, exact failures, original-based selective CPU recovery and source protection'
