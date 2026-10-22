# Shared command builder used by all BookConverter conversion BAT launchers.
# Passing only Base64-encoded PowerShell code to wt.exe prevents file names with
# semicolons from being interpreted as Windows Terminal command separators.
function ConvertTo-BookConverterPowerShellLiteral {
    param([AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function New-BookConverterTerminalLaunch {
    param(
        [Parameter(Mandatory=$true)][string]$MainScript,
        [Parameter(Mandatory=$true)][string]$PowerShellPath,
        [Parameter(Mandatory=$true)][ValidateSet('Manga','Magazine','Split')][string]$Mode,
        [string[]]$DroppedPaths=@()
    )
    $modeArguments=if($Mode -eq 'Magazine'){'-Magazine'}else{''}

    $pathLiterals=[System.Collections.Generic.List[string]]::new()
    foreach($path in @($DroppedPaths)){
        $pathLiterals.Add((ConvertTo-BookConverterPowerShellLiteral -Value $path))
    }
    $pathsExpression='@('+($pathLiterals -join ', ')+')'
    $mainLiteral=ConvertTo-BookConverterPowerShellLiteral -Value $MainScript
    $rootLiteral=ConvertTo-BookConverterPowerShellLiteral -Value (Split-Path -Path $MainScript -Parent)
    $callArguments=if($Mode -eq 'Split'){"-Inputs $pathsExpression"}else{"$modeArguments -DroppedPaths $pathsExpression"}
    $source="Set-Location -LiteralPath $rootLiteral; & $mainLiteral $callArguments"
    # PowerShell -EncodedCommand expects UTF-16LE, even on UTF-8 consoles.
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($source))
    $args=@('-w','new','new-tab','--title',("BookConverter / "+$Mode),
        $PowerShellPath,'-NoLogo','-NoProfile')
    # An explicit exit/exception during a split must not hide diagnostics.
    if($Mode -eq 'Split'){$args+= '-NoExit'}
    $args+=@('-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
    return [pscustomobject]@{
        FileName='wt.exe'
        Arguments=$args
    }
}
