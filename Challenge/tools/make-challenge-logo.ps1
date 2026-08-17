# Regenerates UI/Assets/ChallengeLogo.png - the SNES pad on the challenge title screen
# (UI/Windows/ChallengeTitleWindow.axaml). Run it from anywhere:
#
#     pwsh Challenge/tools/make-challenge-logo.ps1
#
# The pad is drawn at native pixel-art resolution (64x30), then nearest-neighbour
# upscaled. Keep SCALE an integer and keep the window showing the result at Stretch="None":
# any non-integer rescale with interpolation off destroys the 1px outline.
#
# It also writes a theme-check PNG next to itself, compositing the logo over a white and a
# dark ground - the palette has to stay readable on both, since Mesen ships both themes.
#
# The silhouette is built as ONE winding-filled GraphicsPath (body slab + two round end
# caps + two shoulder bumps) so the shapes union instead of showing their seams. Drawing
# it twice - once at inset 0 in the outline colour, once at inset 1 in the body colour -
# gives a clean 1px outline all the way around.
Add-Type -AssemblyName System.Drawing

# SCALE 4 -> 256x120, which is exactly how the title screen displays it (Stretch="None").
# Rendering at display size keeps every pixel square: any non-integer rescale with
# interpolation off would eat the 1px outline that carries the whole silhouette.
$W = 64; $H = 33; $SCALE = 4
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$out = Join-Path $repo 'UI\Assets\ChallengeLogo.png'

function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }

# Kept deliberately punchy: body-to-highlight and body-to-outline both need to carry at a
# 4x-scaled 64px silhouette. The outline stays a touch above pure black so it still reads as
# an edge against Mesen's dark theme instead of merging into it.
$cOutline = C '#2E2158'
$cBody    = C '#8163CE'
$cHi      = C '#B49CF5'
$cDark    = C '#5A3FA0'
$cPad     = C '#1E1930'
$cA       = C '#FF4D4D'
$cB       = C '#FFD11A'
$cX       = C '#3D8BFF'
$cY       = C '#35D25C'

# Silhouette geometry, as [x, y, w, h] at inset 0. The shoulders are deliberately small -
# on the real pad they are narrow tabs, and oversized ones read as a second body.
$BODY     = @(12, 7, 40, 24)
$CAP_L    = @(2, 7, 20, 24)
$CAP_R    = @(42, 7, 20, 24)
$SHOULD_L = @(9, 2, 13, 6)
$SHOULD_R = @(42, 2, 13, 6)

function New-PadPath([int]$i) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.FillMode = [System.Drawing.Drawing2D.FillMode]::Winding
    $p.AddRectangle((New-Object System.Drawing.Rectangle(($BODY[0] + $i), ($BODY[1] + $i), ($BODY[2] - 2 * $i), ($BODY[3] - 2 * $i))))
    $p.AddEllipse(($CAP_L[0] + $i), ($CAP_L[1] + $i), ($CAP_L[2] - 2 * $i), ($CAP_L[3] - 2 * $i))
    $p.AddEllipse(($CAP_R[0] + $i), ($CAP_R[1] + $i), ($CAP_R[2] - 2 * $i), ($CAP_R[3] - 2 * $i))
    # Shoulders keep their full height so they merge into the body instead of floating.
    $p.AddRectangle((New-Object System.Drawing.Rectangle(($SHOULD_L[0] + $i), ($SHOULD_L[1] + $i), ($SHOULD_L[2] - 2 * $i), ($SHOULD_L[3] - $i))))
    $p.AddRectangle((New-Object System.Drawing.Rectangle(($SHOULD_R[0] + $i), ($SHOULD_R[1] + $i), ($SHOULD_R[2] - 2 * $i), ($SHOULD_R[3] - $i))))
    return $p
}

$bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$g.Clear([System.Drawing.Color]::Transparent)

function Fill($col, $x, $y, $w, $h) {
    $br = New-Object System.Drawing.SolidBrush($col)
    $g.FillRectangle($br, [int]$x, [int]$y, [int]$w, [int]$h)
    $br.Dispose()
}
function Dot($col, $x, $y, $w, $h) {
    $br = New-Object System.Drawing.SolidBrush($col)
    $g.FillEllipse($br, [int]$x, [int]$y, [int]$w, [int]$h)
    $br.Dispose()
}
function FillPath($col, $path) {
    $br = New-Object System.Drawing.SolidBrush($col)
    $g.FillPath($br, $path)
    $br.Dispose()
}

# ---- silhouette: outline, then body inset by 1 ---------------------------------------
$outer = New-PadPath 0
$inner = New-PadPath 1
FillPath $cOutline $outer
FillPath $cBody $inner

# ---- top highlight / bottom shading, clipped to the body so they follow the curve -----
$g.SetClip($inner)
Fill $cHi 0 3 $W 2      # catches the shoulder tops
Fill $cHi 0 8 $W 2      # catches the body top
Fill $cDark 0 28 $W 3
$g.ResetClip()

# ---- d-pad (left): plus with 3px arms, centred on (16.5, 19.5) ------------------------
Fill $cPad 9 18 15 3
Fill $cPad 15 12 3 15

# ---- face buttons (right): diamond around (50, 19) - X top, Y left, A right, B bottom -
Dot $cX 47 10 6 6
Dot $cY 41 16 6 6
Dot $cA 53 16 6 6
Dot $cB 47 22 6 6

# ---- select / start -------------------------------------------------------------------
Fill $cPad 25 24 6 2
Fill $cPad 33 24 6 2

$outer.Dispose(); $inner.Dispose(); $g.Dispose()

# ---- upscale with nearest neighbour so the pixel grid survives ------------------------
$big = New-Object System.Drawing.Bitmap(($W * $SCALE), ($H * $SCALE), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$gb = [System.Drawing.Graphics]::FromImage($big)
$gb.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$gb.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$gb.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
$gb.DrawImage($bmp, 0, 0, ($W * $SCALE), ($H * $SCALE))
$gb.Dispose()

$big.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$big.Dispose(); $bmp.Dispose()
"wrote $out ($($W * $SCALE)x$($H * $SCALE))"

# ---- theme check: composite the logo over Mesen's light and dark window grounds -------
$preview = Join-Path $PSScriptRoot 'logo-themecheck.png'
$src = [System.Drawing.Image]::FromFile($out)
$pw = $src.Width; $ph = $src.Height
$chk = New-Object System.Drawing.Bitmap($pw, ($ph * 2), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$gc = [System.Drawing.Graphics]::FromImage($chk)
$gc.FillRectangle((New-Object System.Drawing.SolidBrush((C '#FFFFFF'))), 0, 0, $pw, $ph)
$gc.FillRectangle((New-Object System.Drawing.SolidBrush((C '#202020'))), 0, $ph, $pw, $ph)
$gc.DrawImage($src, 0, 0, $pw, $ph)
$gc.DrawImage($src, 0, $ph, $pw, $ph)
$gc.Dispose(); $chk.Save($preview, [System.Drawing.Imaging.ImageFormat]::Png)
$chk.Dispose(); $src.Dispose()
"wrote $preview"
