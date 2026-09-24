# ============================================================================
#  make-icon.ps1  -  生成 assets\icon.ico（可重复执行，无外部依赖）
#  用一个 256x256 的矢量式绘制结果，缩放成多尺寸 PNG 打包进 ICO。
# ============================================================================

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\Core.ps1')
Import-NetAssemblies -Name @('System.Drawing') | Out-Null

$outPath = Join-Path $PSScriptRoot 'icon.ico'

function New-RoundedPath {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$Radius)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
    $p.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
    $p.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-BaseBitmap {
    $size = 256
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)

    # 背景：圆角深蓝渐变
    $path = New-RoundedPath -X 10 -Y 10 -W 236 -H 236 -Radius 44
    $rect = New-Object System.Drawing.Rectangle(10, 10, 236, 236)
    $c1 = [System.Drawing.Color]::FromArgb(255, 44, 96, 150)
    $c2 = [System.Drawing.Color]::FromArgb(255, 18, 44, 74)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 45.0)
    $g.FillPath($brush, $path)

    # 顶部一条高光
    $hl = New-RoundedPath -X 10 -Y 10 -W 236 -H 110 -Radius 44
    $hlBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(28, 255, 255, 255))
    $g.FillPath($hlBrush, $hl)

    # 文字 API
    $font = New-Object System.Drawing.Font('Segoe UI', 84, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $textRect = New-Object System.Drawing.RectangleF(0, 14, 256, 190)
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.DrawString('API', $font, $white, $textRect, $sf)

    # 右下角绿色勾徽标（表示「已测试 / 通过」）
    $okBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 34, 160, 107))
    $g.FillEllipse($okBrush, 150, 150, 92, 92)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 12)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pts = New-Object 'System.Drawing.Point[]' 3
    $pts[0] = New-Object System.Drawing.Point(172, 197)
    $pts[1] = New-Object System.Drawing.Point(189, 214)
    $pts[2] = New-Object System.Drawing.Point(220, 178)
    $g.DrawLines($pen, $pts)

    $g.Dispose()
    return $bmp
}

function Get-IconImageBytes {
    <#
      生成 ICO 内部使用的经典 DIB（BMP）图像块：
        BITMAPINFOHEADER(40B) + XOR 位图(BGRA, 自下而上) + AND 掩码(全 0)
      为什么不用 PNG 压缩条目：.NET Framework 的 System.Drawing.Icon 读不了 PNG 条目，
      用 DIB 才能被资源管理器 / 任务栏 / 快捷方式图标稳定加载。
    #>
    param([System.Drawing.Bitmap]$Source, [int]$Size)

    $dst = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($Source, 0, 0, $Size, $Size)
    $g.Dispose()

    $rect = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
    $data = $dst.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    if ($stride -lt 0) { $stride = -$stride }
    $pixels = New-Object byte[] ($stride * $Size)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    $dst.UnlockBits($data)
    $dst.Dispose()

    $maskRow = [int]([Math]::Floor(($Size + 31) / 32) * 4)
    $xorSize = $Size * $Size * 4
    $maskSize = $maskRow * $Size
    $out = New-Object byte[] (40 + $xorSize + $maskSize)

    $header = New-Object byte[] 40
    [System.BitConverter]::GetBytes([int]40).CopyTo($header, 0)
    [System.BitConverter]::GetBytes([int]$Size).CopyTo($header, 4)
    [System.BitConverter]::GetBytes([int]($Size * 2)).CopyTo($header, 8)
    [System.BitConverter]::GetBytes([int16]1).CopyTo($header, 12)
    [System.BitConverter]::GetBytes([int16]32).CopyTo($header, 14)
    [System.BitConverter]::GetBytes([int]0).CopyTo($header, 16)
    [System.BitConverter]::GetBytes([int]$xorSize).CopyTo($header, 20)
    [System.Array]::Copy($header, 0, $out, 0, 40)

    for ($y = 0; $y -lt $Size; $y++) {
        $srcRow = ($Size - 1 - $y) * $stride
        [System.Array]::Copy($pixels, $srcRow, $out, (40 + $y * $Size * 4), ($Size * 4))
    }
    # AND 掩码保持全 0：透明度完全交给 alpha 通道
    # 注意：必须用 ,$out 返回，否则 PowerShell 会把 byte[] 展开成逐字节对象，
    #       后续 BinaryWriter.Write 每张图只会写出 1 个字节（曾因此生成 91 字节的坏 ico）。
    return , $out
}

$sizes = @(256, 64, 48, 32, 16)
$base = New-BaseBitmap
$payloads = @()
foreach ($s in $sizes) { $payloads += , (Get-IconImageBytes -Source $base -Size $s) }
$base.Dispose()

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([uint16]0)
$bw.Write([uint16]1)
$bw.Write([uint16]$sizes.Count)

$offset = 6 + (16 * $sizes.Count)
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $wb = 0
    if ($s -lt 256) { $wb = $s }
    $bw.Write([byte]$wb)
    $bw.Write([byte]$wb)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]$payloads[$i].Length)
    $bw.Write([uint32]$offset)
    $offset += $payloads[$i].Length
}
foreach ($p in $payloads) { $bw.Write([byte[]]$p) }
$bw.Flush()

[System.IO.File]::WriteAllBytes($outPath, $ms.ToArray())
$written = (Get-Item $outPath).Length
$expected = 6 + (16 * $sizes.Count) + (($payloads | ForEach-Object { $_.Length }) | Measure-Object -Sum).Sum
$bw.Dispose()
$ms.Dispose()

if ($written -ne $expected) {
    throw ('ico 写入不完整: written=' + $written + ' expected=' + $expected)
}

# 回读校验
$icon = New-Object System.Drawing.Icon($outPath)
$report = @(
    ('icon written : ' + $outPath)
    ('bytes        : ' + $written + ' (expected ' + $expected + ')')
    ('sizes        : ' + ($sizes -join ', '))
    ('load test    : ' + $icon.Width + 'x' + $icon.Height + ' ok')
)
$icon.Dispose()
$report | Set-Content -Path (Join-Path $PSScriptRoot '_icon-build.txt') -Encoding UTF8
$report | ForEach-Object { Write-Host $_ }
