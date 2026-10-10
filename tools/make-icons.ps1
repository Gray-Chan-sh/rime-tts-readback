#Requires -Version 5.1
<#
    make-icons.ps1 - generate rime-tts-readback icons (sound waves + keyboard).

    Produces multi-size .ico files:
        icons\rime-tts-readback.ico   app icon (brand colour)
        icons\tray-ok.ico             tray: available   (green)
        icons\tray-warn.ico           tray: not ready   (orange)
        icons\tray-off.ico            tray: disabled    (grey)

    -Preview writes PNGs (for eyeballing) instead of ico files.
#>
param(
    [switch]$Preview,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$script:Root    = Split-Path -Parent $PSScriptRoot     # repo root (script lives in tools\)
$IconDir        = Join-Path $script:Root 'icons'
$Sizes          = @(16, 20, 24, 32, 40, 48, 64, 128, 256)   # full set (app icon)
$TraySizes      = @(16, 20, 24, 32, 48)                     # tray only needs small

$BrandBg   = [System.Drawing.Color]::FromArgb(41, 121, 190)
$TrayOk    = [System.Drawing.Color]::FromArgb(46, 160, 67)
$TrayWarn  = [System.Drawing.Color]::FromArgb(224, 150, 0)
$TrayOff   = [System.Drawing.Color]::FromArgb(150, 150, 150)
$Fg        = [System.Drawing.Color]::White

function New-RoundedRectPath([double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    if ($d -gt $w) { $d = $w }
    if ($d -gt $h) { $d = $h }
    $p.AddArc([float]$x, [float]$y, [float]$d, [float]$d, 180, 90)
    $p.AddArc([float]($x + $w - $d), [float]$y, [float]$d, [float]$d, 270, 90)
    $p.AddArc([float]($x + $w - $d), [float]($y + $h - $d), [float]$d, [float]$d, 0, 90)
    $p.AddArc([float]$x, [float]($y + $h - $d), [float]$d, [float]$d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Draw the glyph: a keyboard with sound waves rising from it.
function New-IconBitmap([int]$size, [System.Drawing.Color]$bg, [System.Drawing.Color]$fg) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = [double]$size

    # rounded-square background
    $bgPath = New-RoundedRectPath 0 0 $s $s ($s * 0.22)
    $bgBrush = New-Object System.Drawing.SolidBrush $bg
    $g.FillPath($bgBrush, $bgPath)

    $stroke = [Math]::Max(1.0, $s * 0.068)
    if ($size -le 20) { $stroke = 1.0 }
    $pen = New-Object System.Drawing.Pen $fg, ([float]$stroke)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $brush = New-Object System.Drawing.SolidBrush $fg

    # keyboard body, filled so it stays readable when small
    $small = ($size -le 20)
    $kx = $s * 0.16; $kw = $s * 0.68
    if ($small) { $ky = $s * 0.60; $kh = $s * 0.22 } else { $ky = $s * 0.57; $kh = $s * 0.24 }
    $kbPath = New-RoundedRectPath $kx $ky $kw $kh ($s * 0.05)
    $g.FillPath($brush, $kbPath)

    # carve keys / spacebar in the background colour
    if ($size -ge 20) {
        $kz = $s * 0.052
        $y1 = $ky + $kh * 0.34
        foreach ($fx in 0.24, 0.46, 0.68, 0.86) {
            $cx = $kx + $kw * $fx
            $g.FillEllipse($bgBrush, [float]($cx - $kz / 2), [float]($y1 - $kz / 2), [float]$kz, [float]$kz)
        }
        if ($size -ge 32) {
            $bw = $kw * 0.40
            $g.FillRectangle($bgBrush, [float]($kx + ($kw - $bw) / 2), [float]($ky + $kh * 0.62), [float]$bw, [float]($kh * 0.18))
        }
    }

    # sound waves above the keyboard, opening upward
    $cx = $s * 0.50
    if ($small) { $cy = $s * 0.58; $arcs = @(0.18, 0.36) }
    elseif ($size -lt 32) { $cy = $s * 0.56; $arcs = @(0.17, 0.34) }
    else { $cy = $s * 0.56; $arcs = @(0.15, 0.25, 0.35) }
    foreach ($rr in $arcs) {
        $r = $s * $rr
        $g.DrawArc($pen, [float]($cx - $r), [float]($cy - $r), [float]($r * 2), [float]($r * 2), -142, 104)
    }

    $pen.Dispose(); $brush.Dispose(); $bgBrush.Dispose(); $bgPath.Dispose(); $kbPath.Dispose(); $g.Dispose()
    return $bmp
}

function Get-IcoDib([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $bytes = New-Object byte[] ($stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $bmp.UnlockBits($data)

    $maskRow  = [int][Math]::Ceiling($w / 32.0) * 4
    $maskSize = $maskRow * $h
    $xorSize  = $w * 4 * $h

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    # BITMAPINFOHEADER (height doubled: XOR bitmap + AND mask)
    $bw.Write([UInt32]40); $bw.Write([Int32]$w); $bw.Write([Int32]($h * 2))
    $bw.Write([UInt16]1);  $bw.Write([UInt16]32)
    $bw.Write([UInt32]0);  $bw.Write([UInt32]($xorSize + $maskSize))
    $bw.Write([Int32]0);   $bw.Write([Int32]0); $bw.Write([UInt32]0); $bw.Write([UInt32]0)
    # XOR bitmap, bottom-up
    for ($y = $h - 1; $y -ge 0; $y--) { $bw.Write($bytes, $y * $stride, $w * 4) }
    # AND mask (all zero; alpha channel carries transparency)
    $bw.Write((New-Object byte[] $maskSize))
    $bw.Flush()
    return ,([byte[]]$ms.ToArray())
}

function Build-Ico([System.Drawing.Color]$bg, [System.Drawing.Color]$fg, [string]$path, [int[]]$sizes) {
    $dibs = @{}
    foreach ($sz in $sizes) {
        $bmp = New-IconBitmap $sz $bg $fg
        $dibs[$sz] = [byte[]](Get-IcoDib $bmp)
        $bmp.Dispose()
    }
    $fs = [System.IO.File]::Create($path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    foreach ($sz in $sizes) {
        $dim = if ($sz -ge 256) { 0 } else { $sz }
        $bw.Write([Byte]$dim); $bw.Write([Byte]$dim); $bw.Write([Byte]0); $bw.Write([Byte]0)
        $bw.Write([UInt16]1); $bw.Write([UInt16]32)
        $bw.Write([UInt32]$dibs[$sz].Length); $bw.Write([UInt32]$offset)
        $offset += $dibs[$sz].Length
    }
    foreach ($sz in $sizes) { $bw.Write([byte[]]$dibs[$sz]) }
    $bw.Flush(); $bw.Close(); $fs.Dispose()
}

if ($Preview) {
    if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'rime-tts-icon-preview' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    foreach ($sz in @(16, 24, 32, 48, 256)) {
        $b = New-IconBitmap $sz $BrandBg $Fg
        $b.Save((Join-Path $OutDir ("app-$sz.png")), [System.Drawing.Imaging.ImageFormat]::Png)
        $b.Dispose()
    }
    # scaled-up small sizes to judge legibility
    foreach ($sz in @(16, 24, 32)) {
        $b = New-IconBitmap $sz $BrandBg $Fg
        $big = New-Object System.Drawing.Bitmap ($sz * 8), ($sz * 8)
        $g = [System.Drawing.Graphics]::FromImage($big)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $g.DrawImage($b, 0, 0, $sz * 8, $sz * 8)
        $g.Dispose()
        $big.Save((Join-Path $OutDir ("app-$sz-x8.png")), [System.Drawing.Imaging.ImageFormat]::Png)
        $big.Dispose(); $b.Dispose()
    }
    foreach ($p in @(@('ok', $TrayOk), @('warn', $TrayWarn), @('off', $TrayOff))) {
        $b = New-IconBitmap 48 $p[1] $Fg
        $b.Save((Join-Path $OutDir ("state-$($p[0])-48.png")), [System.Drawing.Imaging.ImageFormat]::Png)
        $b.Dispose()
    }
    Write-Output "preview written to $OutDir"
    exit 0
}

if (-not (Test-Path $IconDir)) { New-Item -ItemType Directory -Force -Path $IconDir | Out-Null }
Build-Ico $BrandBg  $Fg (Join-Path $IconDir 'rime-tts-readback.ico') $Sizes
Build-Ico $TrayOk   $Fg (Join-Path $IconDir 'tray-ok.ico')   $TraySizes
Build-Ico $TrayWarn $Fg (Join-Path $IconDir 'tray-warn.ico') $TraySizes
Build-Ico $TrayOff  $Fg (Join-Path $IconDir 'tray-off.ico')  $TraySizes
Get-ChildItem $IconDir -Filter *.ico | Select-Object Name, Length | Format-Table -AutoSize
