# PowerShell 7.6 console-only startup art: pure strings and static ANSI color.
# Terminal progress remains handled by Write-Progress (Classic view).
function Test-MangaBannerAnsi {
    param(
        [switch]$IsConsole,
        [switch]$HasAnsi,
        [switch]$NoColor,
        [int]$Width = 80
    )
    return ($IsConsole -and $HasAnsi -and -not $NoColor -and $Width -ge 60)
}

function Get-MangaStartupBannerLines {
    param(
        [ValidateRange(0,1000)][int]$Width = 80,
        [switch]$EnableAnsi,
        [string]$ModeLabel = 'MANGA / CPU'
    )

    # Never emit escape codes or Unicode blocks to redirected/plain/narrow output.
    if (-not $EnableAnsi -or $Width -lt 60) {
        $name = if ($Width -ge 13) { 'BookConverter' } elseif ($Width -ge 4) { 'BOOK' } else { 'BC' }
        $caption = "AVIF / CBZ | $ModeLabel"
        if ($Width -lt $caption.Length) { $caption = 'AVIF / CBZ' }
        if ($Width -lt $caption.Length) { $caption = 'AVIF' }
        if ($Width -lt $caption.Length) { $caption = '' }
        if ($Width -lt $name.Length) { $name = $name.Substring(0,[Math]::Max(0,$Width)) }
        return @($name,$caption)
    }

    # Compact 5x5 pixel font; 2 words keep the width at 55 terminal cells.
    $glyphs = @{
        'B' = @('####.', '#...#', '####.', '#...#', '####.')
        'O' = @('.###.', '#...#', '#...#', '#...#', '.###.')
        'K' = @('#...#', '#..#.', '###..', '#..#.', '#...#')
        'C' = @('.####', '#....', '#....', '#....', '.####')
        'N' = @('#...#', '##..#', '#.#.#', '#..##', '#...#')
        'V' = @('#...#', '#...#', '#...#', '.#.#.', '..#..')
        'E' = @('#####', '#....', '####.', '#....', '#####')
        'R' = @('####.', '#...#', '####.', '#.#..', '#..##')
        'T' = @('#####', '..#..', '..#..', '..#..', '..#..')
    }
    # 24-bit terminal colors, darker outline at top/bottom and cyan in the middle.
    $gradient = @(
        '38;2;22;91;160',
        '38;2;29;124;195',
        '38;2;69;179;226',
        '38;2;33;134;205',
        '38;2;17;90;164'
    )
    $escape = [char]27
    $reset = "$escape" + '[0m'
    $lines = [System.Collections.Generic.List[string]]::new()

    foreach ($word in @('BOOK','CONVERTER')) {
        for ($row = 0; $row -lt 5; $row++) {
            $parts = [System.Collections.Generic.List[string]]::new()
            foreach ($letter in $word.ToCharArray()) {
                $parts.Add($glyphs[[string]$letter][$row])
            }
            $pixels = ($parts -join ' ').Replace('#', [string][char]0x2588).Replace('.', ' ')
            $color = "$escape" + '[' + $gradient[$row] + 'm'
            $lines.Add('  ' + $color + $pixels + $reset)
        }
        if ($word -eq 'BOOK') { $lines.Add('') }
    }

    $lines.Add('  ' + "$escape" + '[38;2;20;80;145m' + ('─' * 53) + $reset)
    $lines.Add('  ' + "$escape" + '[38;2;105;210;238m' +
        ('AVIF / CBZ  |  {0}' -f $ModeLabel) + $reset)
    return $lines.ToArray()
}

function Write-MangaStartupBanner {
    param(
        [ValidateSet('MANGA','MAGAZINE')][string]$Kind = 'MANGA',
        [ValidateSet('CPU','GPU','HYBRID')][string]$Engine = 'CPU',
        [ValidateSet('AVIF','WebP')][string]$EncodingFormat = 'AVIF'
    )

    $width = 80
    try {
        $reported = [Console]::WindowWidth
        if ($reported -gt 0) { $width = $reported }
    } catch {
        # Hosts without a real terminal get the ASCII fallback below.
    }

    $isConsole = $false
    $hasAnsi = $false
    try {
        $isConsole = ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected)
        $hasAnsi = ($Host.UI.SupportsVirtualTerminal -and
            $PSStyle.OutputRendering -ne 'PlainText' -and $env:TERM -ne 'dumb')
    } catch {
        $isConsole = $false
    }
    $enabled = Test-MangaBannerAnsi -IsConsole:$isConsole -HasAnsi:$hasAnsi `
        -NoColor:(Test-Path Env:NO_COLOR) -Width $width

    foreach ($line in @(Get-MangaStartupBannerLines -Width $width -EnableAnsi:$enabled `
            -ModeLabel "$Kind / $Engine")) {
        Write-Host ($line.Replace('AVIF', $EncodingFormat))
    }
    Write-Host ''
}
