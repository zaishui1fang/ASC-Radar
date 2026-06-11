param(
  [string]$Root = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
$assetDir = Join-Path $Root "assets"
New-Item -ItemType Directory -Force -Path $assetDir | Out-Null

function New-RoundedRectanglePath([float]$X, [float]$Y, [float]$Width, [float]$Height, [float]$Radius) {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $diameter = $Radius * 2
  $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
  $path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
  $path.AddArc($X + $Width - $diameter, $Y + $Height - $diameter, $diameter, $diameter, 0, 90)
  $path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
  $path.CloseFigure()
  return $path
}

function New-LogoBitmap([int]$Size) {
  $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)

  $s = $Size / 1024.0
  function U([float]$Value) { return $Value * $s }
  function C([string]$Hex) { return [System.Drawing.ColorTranslator]::FromHtml($Hex) }
  function CA([int]$Alpha, [string]$Hex) {
    $c = C $Hex
    return [System.Drawing.Color]::FromArgb($Alpha, $c.R, $c.G, $c.B)
  }

  for ($i = 7; $i -ge 1; $i--) {
    $offset = U(86 - ($i * 4))
    $size = U(852 + ($i * 8))
    $shadow = New-RoundedRectanglePath $offset $offset $size $size (U(184 + ($i * 4)))
    $brush = New-Object System.Drawing.SolidBrush (CA ([Math]::Max(6, 42 - ($i * 4))) "#062A66")
    $g.FillPath($brush, $shadow)
    $brush.Dispose()
    $shadow.Dispose()
  }

  $tileRect = New-Object System.Drawing.RectangleF (U 86), (U 86), (U 852), (U 852)
  $tilePath = New-RoundedRectanglePath $tileRect.X $tileRect.Y $tileRect.Width $tileRect.Height (U 184)
  $tileBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $tileRect, (C "#2FA7FF"), (C "#005FD7"), 135
  $g.FillPath($tileBrush, $tilePath)
  $borderPen = New-Object System.Drawing.Pen (CA 116 "#72C8FF"), (U 22)
  $g.DrawPath($borderPen, $tilePath)

  $shinePath = New-Object System.Drawing.Drawing2D.GraphicsPath
  $shinePath.AddBezier((U 156), (U 166), (U 338), (U 90), (U 653), (U 82), (U 842), (U 276))
  $shinePath.AddLine((U 842), (U 276), (U 842), (U 108))
  $shinePath.AddLine((U 842), (U 108), (U 156), (U 108))
  $shinePath.CloseFigure()
  $shineBrush = New-Object System.Drawing.SolidBrush (CA 45 "#FFFFFF")
  $g.FillPath($shineBrush, $shinePath)

  $ringFill = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Transparent)
  $ringPen = New-Object System.Drawing.Pen (CA 64 "#FFFFFF"), (U 20)
  $g.DrawEllipse($ringPen, (U 228), (U 228), (U 568), (U 568))

  $dashPen = New-Object System.Drawing.Pen (CA 138 "#FFFFFF"), (U 18)
  $dashPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $dashPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $dashPen.DashPattern = @(17.0, 5.5)
  $g.DrawEllipse($dashPen, (U 307), (U 307), (U 410), (U 410))

  $innerPen = New-Object System.Drawing.Pen (CA 82 "#FFFFFF"), (U 14)
  $g.DrawEllipse($innerPen, (U 390), (U 390), (U 244), (U 244))

  $axisPen = New-Object System.Drawing.Pen (CA 62 "#FFFFFF"), (U 14)
  $axisPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $axisPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $g.DrawLine($axisPen, (U 512), (U 282), (U 512), (U 742))
  $g.DrawLine($axisPen, (U 282), (U 512), (U 742), (U 512))

  $sweep = New-Object System.Drawing.Drawing2D.GraphicsPath
  $sweep.AddPie((U 228), (U 228), (U 568), (U 568), -38, 52)
  $sweepBrush = New-Object System.Drawing.SolidBrush (CA 42 "#FFFFFF")
  $g.FillPath($sweepBrush, $sweep)

  $cardPath = New-RoundedRectanglePath (U 350) (U 354) (U 324) (U 318) (U 82)
  $cardBrush = New-Object System.Drawing.SolidBrush (CA 242 "#FFFFFF")
  $cardPen = New-Object System.Drawing.Pen (CA 0 "#FFFFFF"), (U 1)
  $g.FillPath($cardBrush, $cardPath)

  $curvePen = New-Object System.Drawing.Pen (C "#0A84FF"), (U 34)
  $curvePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $curvePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $curve = New-Object System.Drawing.Drawing2D.GraphicsPath
  $curve.AddBezier((U 424), (U 562), (U 468), (U 501), (U 536), (U 499), (U 594), (U 552))
  $g.DrawPath($curvePen, $curve)

  $checkPen = New-Object System.Drawing.Pen (C "#17B26A"), (U 38)
  $checkPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $checkPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $checkPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $g.DrawLines($checkPen, @(
    (New-Object System.Drawing.PointF (U 434), (U 610)),
    (New-Object System.Drawing.PointF (U 492), (U 668)),
    (New-Object System.Drawing.PointF (U 624), (U 436))
  ))

  $whitePen = New-Object System.Drawing.Pen (C "#FFFFFF"), (U 16)
  foreach ($node in @(
    @{ x = 360; y = 372; r = 34; color = "#FFFFFF" },
    @{ x = 682; y = 348; r = 38; color = "#FFFFFF" },
    @{ x = 704; y = 682; r = 42; color = "#17B26A" }
  )) {
    $nodeBrush = New-Object System.Drawing.SolidBrush (C $node.color)
    $g.FillEllipse($nodeBrush, (U ($node.x - $node.r)), (U ($node.y - $node.r)), (U ($node.r * 2)), (U ($node.r * 2)))
    $g.DrawEllipse($whitePen, (U ($node.x - $node.r)), (U ($node.y - $node.r)), (U ($node.r * 2)), (U ($node.r * 2)))
    $nodeBrush.Dispose()
  }

  foreach ($obj in @($whitePen, $checkPen, $curvePen, $curve, $cardPen, $cardBrush, $cardPath, $sweepBrush, $sweep, $axisPen, $innerPen, $dashPen, $ringPen, $ringFill, $shineBrush, $shinePath, $borderPen, $tileBrush, $tilePath)) {
    if ($null -ne $obj) { $obj.Dispose() }
  }
  $g.Dispose()
  return $bmp
}

function Get-PngBytes([System.Drawing.Bitmap]$Bitmap) {
  $stream = New-Object System.IO.MemoryStream
  $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
  $bytes = $stream.ToArray()
  $stream.Dispose()
  return $bytes
}

function Write-UInt16([System.IO.BinaryWriter]$Writer, [int]$Value) {
  $Writer.Write([byte]($Value -band 0xff))
  $Writer.Write([byte](($Value -shr 8) -band 0xff))
}

function Write-UInt32([System.IO.BinaryWriter]$Writer, [int]$Value) {
  $Writer.Write([byte]($Value -band 0xff))
  $Writer.Write([byte](($Value -shr 8) -band 0xff))
  $Writer.Write([byte](($Value -shr 16) -band 0xff))
  $Writer.Write([byte](($Value -shr 24) -band 0xff))
}

function Write-Ico([string]$Path, [int[]]$Sizes) {
  $entries = @()
  foreach ($size in $Sizes) {
    $bmp = New-LogoBitmap $size
    try {
      $entries += [pscustomobject]@{ Size = $size; Bytes = (Get-PngBytes $bmp) }
    } finally {
      $bmp.Dispose()
    }
  }

  $stream = [System.IO.File]::Create($Path)
  $writer = New-Object System.IO.BinaryWriter $stream
  try {
    Write-UInt16 $writer 0
    Write-UInt16 $writer 1
    Write-UInt16 $writer $entries.Count
    $offset = 6 + ($entries.Count * 16)
    foreach ($entry in $entries) {
      $directorySize = if ($entry.Size -ge 256) { 0 } else { $entry.Size }
      $writer.Write([byte]$directorySize)
      $writer.Write([byte]$directorySize)
      $writer.Write([byte]0)
      $writer.Write([byte]0)
      Write-UInt16 $writer 1
      Write-UInt16 $writer 32
      Write-UInt32 $writer $entry.Bytes.Length
      Write-UInt32 $writer $offset
      $offset += $entry.Bytes.Length
    }
    foreach ($entry in $entries) {
      $writer.Write([byte[]]$entry.Bytes)
    }
  } finally {
    $writer.Dispose()
    $stream.Dispose()
  }
}

$png512 = Join-Path $assetDir "app-logo.png"
$png128 = Join-Path $assetDir "app-logo-128.png"
$png32 = Join-Path $assetDir "app-logo-32.png"
$ico = Join-Path $assetDir "app-logo.ico"

$logo512 = New-LogoBitmap 512
try { $logo512.Save($png512, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $logo512.Dispose() }
$logo128 = New-LogoBitmap 128
try { $logo128.Save($png128, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $logo128.Dispose() }
$logo32 = New-LogoBitmap 32
try { $logo32.Save($png32, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $logo32.Dispose() }
Write-Ico $ico @(256, 128, 64, 48, 32, 24, 16)

Write-Host "Generated:"
Write-Host $png512
Write-Host $png128
Write-Host $png32
Write-Host $ico
