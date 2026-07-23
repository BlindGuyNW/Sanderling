<#
.SYNOPSIS
Capture the game client window to a PNG, without touching the game.

.DESCRIPTION
The memory-reading readout is the primary instrument: it is what the alternate UI renders,
and it is diffable. What it cannot answer is whether the *reading itself* missed something
the client is showing - and that question comes up exactly when comparing "what we render"
against "what a sighted player sees". This captures the pixels for that comparison.

Uses PrintWindow with PW_RENDERFULLCONTENT, so it captures the window's own surface even
while other windows cover it. The window must not be minimized (the same constraint the
input path has). Coordinates in the saved image are client-area coordinates - the same
space the UI tree's display regions and Send-MouseClick use.

.EXAMPLE
./tools/GameWindowScreenshot.ps1 -OutFile shot.png
Finds the EVE client window by title and saves its client area.

.EXAMPLE
./tools/GameWindowScreenshot.ps1 -OutFile lobby.png -CropX 1624 -CropY 16 -CropWidth 280 -CropHeight 920
Saves just the station window, using the display region from the UI tree.
#>
param(
    [string]$OutFile = "game-window.png",
    [long]$WindowId = 0,
    [int]$CropX = -1,
    [int]$CropY = 0,
    [int]$CropWidth = 0,
    [int]$CropHeight = 0
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class GameWindowShot
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
}
"@

if ($WindowId -eq 0) {
    $gameProcess = Get-Process |
        Where-Object { $_.MainWindowTitle -like 'EVE - *' } |
        Select-Object -First 1
    if (-not $gameProcess) { throw "no window with a title like 'EVE - *' found; pass -WindowId" }
    $WindowId = [long]$gameProcess.MainWindowHandle
    Write-Verbose "found '$($gameProcess.MainWindowTitle)' with window handle $WindowId"
}

$hwnd = [IntPtr]$WindowId

if ([GameWindowShot]::IsIconic($hwnd)) {
    throw "the game window is minimized; PrintWindow cannot capture it (and input would not land either)"
}

$clientRect = New-Object GameWindowShot+RECT
[void][GameWindowShot]::GetClientRect($hwnd, [ref]$clientRect)
$width = $clientRect.Right - $clientRect.Left
$height = $clientRect.Bottom - $clientRect.Top
if ($width -le 0 -or $height -le 0) { throw "window client area is empty ($width x $height)" }

<#
 PW_CLIENTONLY (1) keeps the image in the same coordinate space as the UI tree's display
 regions. PW_RENDERFULLCONTENT (2) asks DWM for the composited surface, which is what makes
 this work on a DirectX window that would otherwise come out black.
#>
$bitmap = New-Object System.Drawing.Bitmap($width, $height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$hdc = $graphics.GetHdc()
$captured = [GameWindowShot]::PrintWindow($hwnd, $hdc, 3)
$graphics.ReleaseHdc($hdc)
$graphics.Dispose()

if (-not $captured) {
    $bitmap.Dispose()
    throw "PrintWindow failed for window $WindowId"
}

if (0 -le $CropX) {
    if ($CropWidth -le 0 -or $CropHeight -le 0) { throw "give -CropWidth and -CropHeight along with -CropX" }
    $cropRect = New-Object System.Drawing.Rectangle($CropX, $CropY, $CropWidth, $CropHeight)
    $cropped = $bitmap.Clone($cropRect, $bitmap.PixelFormat)
    $bitmap.Dispose()
    $bitmap = $cropped
}

$resolvedPath =
    if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile }
    else { [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $OutFile)) }
$savedWidth = $bitmap.Width
$savedHeight = $bitmap.Height
$bitmap.Save($resolvedPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()

"saved $savedWidth x $savedHeight px to $resolvedPath"
