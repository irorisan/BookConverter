#requires -Version 7.6
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Manga','Magazine','GPU','MagazineGPU','Hybrid')]
    [string]$Mode,
    [Parameter(Position=0,ValueFromRemainingArguments=$true)]
    [string[]]$DroppedPaths
)
$ErrorActionPreference='Stop'
try {
    if(-not $IsWindows -or $PSVersionTable.PSVersion.Major -ne 7 -or
        $PSVersionTable.PSVersion.Minor -ne 6){
        throw 'BookConverterにはWindowsとPowerShell 7.6.xが必要です。'
    }
    $terminal=Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue
    if($null -eq $terminal){
        throw 'Windows Terminal（wt.exe）が見つかりません。Windows Terminalをインストールし、Windowsの設定でwt.exeのアプリ実行エイリアスを有効にしてください。'
    }
    $main=Join-Path $PSScriptRoot 'Convert-Manga.ps1'
    if(-not (Test-Path -LiteralPath $main -PathType Leaf)){
        throw "変換スクリプトがありません: $main"
    }
    . (Join-Path $PSScriptRoot 'BookConverter-TerminalLaunch.ps1')

    # The launcher itself runs under the pinned PowerShell 7.6 binary.
    # Reuse this exact executable rather than a profile name in WT settings.
    $pwsh=Join-Path $PSHOME 'pwsh.exe'
    $launch=New-BookConverterTerminalLaunch -MainScript $main -PowerShellPath $pwsh `
        -Mode $Mode -DroppedPaths $DroppedPaths
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$terminal.Source
    $info.UseShellExecute=$false
    $info.WorkingDirectory=(Split-Path $PSScriptRoot -Parent)
    foreach($argument in $launch.Arguments){[void]$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($info)
    if($null -eq $process){throw 'Windows Terminalを起動できませんでした。'}
    $process.Dispose()
}
catch {
    [Console]::Error.WriteLine(('BookConverter Windows Terminal起動エラー: {0}' -f $_.Exception.Message))
    exit 1
}
