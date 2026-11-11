# The HP1 app's bubble and LiveArea pictures from the game's own art (images/branding): the cover (coverhq.jpg) with the port's
# watermark for the LiveArea, GamePlayButton.jpg for the gate, icon.png (the game's Snitch icon) for the bubble. Writes full colour
# PNGs; make_livearea.py --from <folder> turns them into the 8 bit palette PNGs the Vita wants. Windows PowerShell (System.Drawing):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File make_livearea_cover.ps1 <branding folder> <output folder>
param([string]$Branding, [string]$Out)

Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $Out | Out-Null

$cover = [System.Drawing.Image]::FromFile((Join-Path $Branding 'coverhq.jpg'))

function New-Canvas([int]$w, [int]$h) {
	$bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp)
	$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
	$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
	$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
	$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
	return $bmp, $g
}

# A part of the cover (source rectangle) scaled into the whole picture
function Draw-Cover($g, [int]$w, [int]$h, [int]$sx, [int]$sy, [int]$sw, [int]$sh) {
	$attr = New-Object System.Drawing.Imaging.ImageAttributes
	$attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)   # no dark seam at the edges
	$g.DrawImage($cover, (New-Object System.Drawing.Rectangle 0, 0, $w, $h), $sx, $sy, $sw, $sh, [System.Drawing.GraphicsUnit]::Pixel, $attr)
}

# Right-aligned text with a soft dark shadow, its baseline box ending at (right, bottom)
function Draw-Label($g, [string]$text, $font, $brush, [float]$right, [float]$bottom) {
	$size = $g.MeasureString($text, $font)
	$x = $right - $size.Width
	$y = $bottom - $size.Height
	$shadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(170, 0, 0, 0))
	foreach ($d in @(@(2, 2), @(1, 1), @(2, 1), @(1, 2))) { $g.DrawString($text, $font, $shadow, $x + $d[0], $y + $d[1]) }
	$g.DrawString($text, $font, $brush, $x, $y)
}

# LiveArea background, 840 x 500: the cover cut to the LiveArea's shape (the faces kept), a dark band at the bottom right and
# the watermark in it (the gate sits in the middle, the corner stays free)
$bmp, $g = New-Canvas 840 500
Draw-Cover $g 840 500 0 62 1509 898
$band = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Point 0, 410), (New-Object System.Drawing.Point 0, 500), ([System.Drawing.Color]::FromArgb(0, 0, 0, 0)), ([System.Drawing.Color]::FromArgb(185, 0, 0, 0))
$g.FillRectangle($band, 0, 410, 840, 90)
$gold = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 240, 200, 90))
$white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 235, 235, 235))
$big = New-Object System.Drawing.Font 'Georgia', 22, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$small = New-Object System.Drawing.Font 'Segoe UI', 16, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
Draw-Label $g 'port by 31zzard' $big $gold 826 466
Draw-Label $g 'https://t.me/hp1psvita' $small $white 826 492
$bmp.Save((Join-Path $Out 'bg.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

# The gate, 280 x 158: GamePlayButton.jpg (the title on Hogwarts at night, 1370 x 784), a few rows cut to the gate's shape
$button = [System.Drawing.Image]::FromFile((Join-Path $Branding 'GamePlayButton.jpg'))
$bmp, $g = New-Canvas 280 158
$rows = [int][math]::Round($button.Width * 158 / 280)
$attr = New-Object System.Drawing.Imaging.ImageAttributes
$attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
$g.DrawImage($button, (New-Object System.Drawing.Rectangle 0, 0, 280, 158), 0, [int](($button.Height - $rows) / 2), $button.Width, $rows, [System.Drawing.GraphicsUnit]::Pixel, $attr)
$bmp.Save((Join-Path $Out 'startup.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose(); $button.Dispose()

# The bubble, 128 x 128: icon.png (the game's Snitch icon, made larger) as it is, scaled down (the Vita masks it to a circle)
$iconArt = [System.Drawing.Image]::FromFile((Join-Path $Branding 'icon.png'))
$bmp, $g = New-Canvas 128 128
$attr = New-Object System.Drawing.Imaging.ImageAttributes
$attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
$g.DrawImage($iconArt, (New-Object System.Drawing.Rectangle 0, 0, 128, 128), 0, 0, $iconArt.Width, $iconArt.Height, [System.Drawing.GraphicsUnit]::Pixel, $attr)
$bmp.Save((Join-Path $Out 'icon0.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose(); $iconArt.Dispose()
$cover.Dispose()
