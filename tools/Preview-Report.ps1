#requires -Version 7.4
param(
    [ValidateRange(32,200)][int]$Columns=100,
    [string]$OutputDirectory=(Join-Path $PSScriptRoot '../outputs'),
    [string]$Fixture=(Join-Path $PSScriptRoot '../tests/fixtures/report-v2.json'),
    [switch]$PlainAscii
)

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../ipregion.ps1') -NoColor -NoProgress -Width $Columns -Ascii:$PlainAscii
$source=Get-Content -LiteralPath $Fixture -Raw | ConvertFrom-Json
$rows=@(foreach ($groupEntry in $source.results.PSObject.Properties) {
    foreach ($row in $groupEntry.Value) {
        $row | Add-Member group $groupEntry.Name
        $row
    }
})
$report=[pscustomobject]@{ network=$source.network; ipv4=$source.ipv4; ipv6=$source.ipv6; rows=$rows; verdict=$source.verdict; attention=$source.attention }
$segments=[Collections.Generic.List[object]]::new()
$writer=[IO.StringWriter]::new()

function Write-ColorText {
    param([string]$Text, [ConsoleColor]$Color=[ConsoleColor]::Gray, [switch]$NoNewline)
    $previous=$writer.ToString()
    $lineStart=$previous.LastIndexOf("`n")+1
    $segments.Add([pscustomobject]@{ X=(Get-DisplayWidth $previous.Substring($lineStart)); Y=[regex]::Matches($previous,"`n").Count; Text=$Text; Color=$Color })
    if ($NoNewline) { $writer.Write($Text) } else { $writer.WriteLine($Text) }
}

$previousOutput=[Console]::Out
try { [Console]::SetOut($writer); Write-IpReport $report } finally { [Console]::SetOut($previousOutput) }
$text=$writer.ToString(); $writer.Dispose()
[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
$stem=Join-Path $OutputDirectory "report-$Columns"
$text | Set-Content -LiteralPath "$stem.txt" -Encoding utf8NoBOM

# Rasterize the actual renderer's text and color segments, using a monospace terminal font.
Add-Type -AssemblyName System.Drawing
$font=[Drawing.Font]::new('Consolas',16,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$probe=[Drawing.Bitmap]::new(1,1); $measurement=[Drawing.Graphics]::FromImage($probe)
$format=[Drawing.StringFormat]::GenericTypographic.Clone()
$cellWidth=$measurement.MeasureString('M',$font,100,$format).Width
$measurement.Dispose(); $probe.Dispose()
$lineHeight=22; $padding=24; $titleHeight=42
$lineCount=[regex]::Matches($text,"`n").Count+1
$bitmap=[Drawing.Bitmap]::new([int][Math]::Ceiling($Columns*$cellWidth+2*$padding),[int]($lineCount*$lineHeight+2*$padding+$titleHeight))
$graphics=[Drawing.Graphics]::FromImage($bitmap)
$brushes=[Collections.Generic.List[Drawing.SolidBrush]]::new()
try {
    $graphics.Clear([Drawing.ColorTranslator]::FromHtml('#0d1524'))
    $graphics.TextRenderingHint=[Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $palette=@{ Gray='#c5cfdf'; White='#eef4ff'; DarkGray='#7c8da9'; Cyan='#58d5eb'; DarkCyan='#356f89'; Green='#9addad'; Yellow='#f2c97d'; Red='#f48a96' }
    $titleBrush=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#7c8da9')); $brushes.Add($titleBrush)
    $graphics.DrawString('pwsh  /  IPRegion  /  example data',$font,$titleBrush,[single]$padding,[single]16,$format)
    foreach ($segment in $segments) {
        $hex=$palette[[string]$segment.Color]; if (-not $hex) { $hex='#c5cfdf' }
        $brush=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($hex)); $brushes.Add($brush)
        $graphics.DrawString($segment.Text,$font,$brush,[single]($padding+$segment.X*$cellWidth),[single]($padding+$titleHeight+$segment.Y*$lineHeight),$format)
    }
    $bitmap.Save("$stem.png",[Drawing.Imaging.ImageFormat]::Png)
} finally {
    foreach ($brush in $brushes) { $brush.Dispose() }
    $graphics.Dispose(); $bitmap.Dispose(); $font.Dispose(); $format.Dispose()
}
Write-Output "$stem.png"
