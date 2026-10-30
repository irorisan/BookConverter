# Literal paths only. This is not a PowerShell/cmd command-line parser.
function Split-MangaInput {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $lineText = $Line.Trim()
    $paths = [System.Collections.Generic.List[string]]::new()
    # A single unquoted absolute path can contain spaces. Multiple paths with
    # spaces must be quoted; a second absolute-path prefix separates bare paths.
    if (-not $lineText.Contains('"') -and $lineText -notmatch '\s+(?:[A-Za-z]:[\\/]|\\\\)') {
        $paths.Add($lineText)
    }
    else {
        $position = 0
        $pattern = '\G\s*(?:"(?<quoted>[^"]+)"|(?<bare>[^\s"]+))(?=\s|$)'
        while ($position -lt $lineText.Length) {
            # Match from the current cursor, without evaluating any input text.
            $token = ([regex]$pattern).Match($lineText, $position)
            if (-not $token.Success) { throw 'パスの引用符を確認してください。複数パスは各パスを "..." で囲んでください。' }
            $path = if ($token.Groups['quoted'].Success) { $token.Groups['quoted'].Value } else { $token.Groups['bare'].Value }
            $paths.Add($path)
            $position = $token.Index + $token.Length
        }
    }
    foreach ($path in $paths) {
        if ($path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)') {
            throw "絶対パスを入力してください: $path"
        }
    }
    foreach ($path in $paths) { Write-Output $path }
}

function Read-MangaResponse {
    param([string]$Prompt)
    if ([Console]::IsInputRedirected) {
        Write-Host $Prompt
        # Read-Host cannot distinguish EOF from an empty response.
        return [Console]::ReadLine()
    }
    return (Read-Host $Prompt)
}

function Read-MangaEncodingFormat {
    Write-Host 'エンコード形式を選択してください' -ForegroundColor Cyan
    Write-Host '  1. AVIF（GPU + CPU Hybrid）[デフォルト]'
    Write-Host '  2. WebP（CPUのみ）'
    while ($true) {
        $response = Read-MangaResponse '選択 [1/2]（Enterで1）'
        if ($null -eq $response -or $response.Trim() -in @('', '1')) { return 'AVIF' }
        if ($response.Trim() -eq '2') { return 'WebP' }
        Write-Host '1 または 2 を入力してください。' -ForegroundColor Yellow
    }
}
