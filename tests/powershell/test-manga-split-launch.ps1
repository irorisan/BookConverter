#requires -Version 7.6
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $root 'scripts/BookConverter-TerminalLaunch.ps1')
function Assert([bool]$ok,[string]$message){if(-not $ok){throw $message}}
$paths=@(
    'D:\漫画\第01巻',
    'D:\漫画\記号 & 1;test (2026) ! ''quote''',
    '\\server\share\日本語 書籍'
)
$entry=Get-Content -LiteralPath (Join-Path $root 'MangaSplit.bat') -Raw
Assert ($entry -match 'Start-BookConverter-Terminal\.ps1') 'MangaSplit BAT must use same Windows Terminal entrypoint as other converters'
Assert ($entry -match '\-Mode Split') 'MangaSplit BAT must explicitly choose Split mode'
Assert ($entry -match '%\*') 'MangaSplit BAT must preserve drag-and-drop paths'
Assert ($entry -match 'DisableDelayedExpansion') 'Exclamation marks in paths must remain literal'
$launcher=Get-Content -LiteralPath (Join-Path $root 'scripts/Start-BookConverter-Terminal.ps1') -Raw
Assert ($launcher -match 'MangaSplit\.ps1') 'Terminal launcher must route Split to MangaSplit'
$main=Join-Path $root 'scripts/MangaSplit.ps1'
$plan=New-BookConverterTerminalLaunch -MainScript $main -PowerShellPath 'C:\Program Files\PowerShell\7\pwsh.exe' -Mode Split -DroppedPaths $paths
Assert ($plan.Arguments -contains '-NoExit') 'New Terminal must stay open after the split command'
Assert ($plan.Arguments -contains '-EncodedCommand') 'Split must not pass unescaped paths as WT commands'
Assert ($plan.Arguments[0] -eq '-w' -and $plan.Arguments[1] -eq 'new') 'Use a new Terminal window'
$decoded=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($plan.Arguments[-1]))
Assert ($decoded.Contains('-Inputs')) 'Split must bind input folder names'
$tokens=$null
$errors=$null
[void][Management.Automation.Language.Parser]::ParseInput($decoded,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Encoded split script has syntax errors'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('MangaSplitLaunch_'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try{
    $receiver=Join-Path $temp 'receiver.ps1'
    [IO.File]::WriteAllText($receiver,@'
param([string[]]$Inputs)
@($Inputs) | ConvertTo-Json -Compress
'@,[Text.UTF8Encoding]::new($false))
    $check=New-BookConverterTerminalLaunch -MainScript $receiver -PowerShellPath 'pwsh.exe' -Mode Split -DroppedPaths $paths
    $actual=& pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $check.Arguments[-1] | ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0) 'Encoded child command failed'
    Assert (@($actual).Count -eq $paths.Count) 'Argument count changed'
    for($i=0;$i -lt $paths.Count;$i++){
        Assert (@($actual)[$i] -ceq $paths[$i]) "Path $i was altered"
    }
} finally{
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS: MangaSplit uses a durable Terminal window and literal input paths'
