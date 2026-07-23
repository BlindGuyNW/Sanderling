<#
.SYNOPSIS
Report the game client's window state, including the conditions that silently break input.

.DESCRIPTION
When posted input stops working, it is almost always one of these, and none of them are
visible from the UI tree - the tree keeps reading fine while every click is discarded:

  - the window is MINIMIZED (client rect 0x0). Nothing can be driven at all.
  - the real cursor is OUTSIDE the client area (title bar counts as outside). Mouse
    messages are dropped; keyboard still works.
  - the process is HUNG: its message pump has stopped, so every posted message queues
    forever - while ReadProcessMemory needs no message pump, so the UI tree keeps reading
    perfectly and the readings look completely healthy. Added 2026-07-23 after an episode
    of exactly that symptom whose cause was never confirmed; this check exists so the
    hung-pump hypothesis takes seconds to test instead of an hour.

Each cost real debugging time to find, so check here first.

.PARAMETER ProcessId
Game client process id. Defaults to the first process named 'exefile'.

.EXAMPLE
./tools/GameWindowProbe.ps1
#>
[CmdletBinding()]
param([int]$ProcessId)

Add-Type -Namespace GameWindowProbe -Name Api -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int max);
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int max);
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);
[DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr hWnd);
[StructLayout(LayoutKind.Sequential)]
public struct POINT { public int X, Y; }
'@

if (-not $ProcessId) {
    $process = Get-Process exefile -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $process) {
        Write-Error "No process named 'exefile' found. Pass -ProcessId explicitly."
        return
    }
    $ProcessId = $process.Id
}

$handles = New-Object System.Collections.ArrayList
$callback = [GameWindowProbe.Api+EnumWindowsProc] {
    param($hWnd, $lParam)
    $owner = 0
    [GameWindowProbe.Api]::GetWindowThreadProcessId($hWnd, [ref]$owner) | Out-Null
    if ($owner -eq $ProcessId) { [void]$handles.Add($hWnd) }
    return $true
}
[GameWindowProbe.Api]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null

Write-Host "Process id $ProcessId - $($handles.Count) top-level window(s)"
Write-Host ""

$gameWindow = $null

foreach ($handle in $handles) {
    $class = New-Object System.Text.StringBuilder 256
    [GameWindowProbe.Api]::GetClassName($handle, $class, 256) | Out-Null
    $title = New-Object System.Text.StringBuilder 256
    [GameWindowProbe.Api]::GetWindowText($handle, $title, 256) | Out-Null

    $clientRect = New-Object GameWindowProbe.Api+RECT
    [GameWindowProbe.Api]::GetClientRect($handle, [ref]$clientRect) | Out-Null
    $windowRect = New-Object GameWindowProbe.Api+RECT
    [GameWindowProbe.Api]::GetWindowRect($handle, [ref]$windowRect) | Out-Null

    $minimized = [GameWindowProbe.Api]::IsIconic($handle)

    Write-Host ("  handle 0x{0:X} ({1})" -f $handle.ToInt64(), $handle.ToInt64())
    Write-Host "    class      : $($class.ToString())"
    Write-Host "    title      : $($title.ToString())"
    Write-Host "    visible    : $([GameWindowProbe.Api]::IsWindowVisible($handle))   minimized: $minimized"
    Write-Host "    client     : $($clientRect.Right)x$($clientRect.Bottom)"
    Write-Host "    window rect: ($($windowRect.Left),$($windowRect.Top))-($($windowRect.Right),$($windowRect.Bottom))"
    Write-Host ""

    #  The class the EVE client uses for its single real window.
    if ($class.ToString() -eq 'trinityWindow') { $gameWindow = $handle }
}

$foreground = [GameWindowProbe.Api]::GetForegroundWindow()
$cursor = New-Object GameWindowProbe.Api+POINT
[GameWindowProbe.Api]::GetCursorPos([ref]$cursor) | Out-Null

Write-Host ("foreground window: 0x{0:X}" -f $foreground.ToInt64())
Write-Host "cursor           : ($($cursor.X),$($cursor.Y))"
Write-Host ""

if (-not $gameWindow) {
    Write-Host "VERDICT: no 'trinityWindow' found - cannot assess input readiness."
    return
}

$problems = New-Object System.Collections.ArrayList

<#
A hung process is the treacherous case: memory reads need no message pump, so the UI tree
keeps reading perfectly while every posted message queues unprocessed. Nothing about the
readings reveals it. IsHungAppWindow is Windows' own definition - no message processed in
about five seconds.
#>
if ([GameWindowProbe.Api]::IsHungAppWindow($gameWindow)) {
    [void]$problems.Add("Window is NOT RESPONDING (message pump stopped ~5s+ ago). Posted input queues forever while memory readings continue to look perfectly healthy. The client is hung or dying; input cannot work until it recovers or restarts.")
}

if ([GameWindowProbe.Api]::IsIconic($gameWindow)) {
    [void]$problems.Add("Window is MINIMIZED. No input of any kind can be delivered. Restoring it also steals focus, so this has to be resolved by hand.")
}
else {
    $clientRect = New-Object GameWindowProbe.Api+RECT
    [GameWindowProbe.Api]::GetClientRect($gameWindow, [ref]$clientRect) | Out-Null

    $topLeft = New-Object GameWindowProbe.Api+POINT
    $bottomRight = New-Object GameWindowProbe.Api+POINT
    $bottomRight.X = $clientRect.Right
    $bottomRight.Y = $clientRect.Bottom
    [GameWindowProbe.Api]::ClientToScreen($gameWindow, [ref]$topLeft) | Out-Null
    [GameWindowProbe.Api]::ClientToScreen($gameWindow, [ref]$bottomRight) | Out-Null

    Write-Host "client area on screen: ($($topLeft.X),$($topLeft.Y))-($($bottomRight.X),$($bottomRight.Y))"

    $cursorInside =
        $topLeft.X -le $cursor.X -and $cursor.X -lt $bottomRight.X -and
        $topLeft.Y -le $cursor.Y -and $cursor.Y -lt $bottomRight.Y

    if (-not $cursorInside) {
        [void]$problems.Add("Real cursor is OUTSIDE the client area, so posted mouse messages will be discarded. Keyboard is unaffected. The effect path parks the cursor itself, but anything posting messages directly must handle this.")
    }
}

Write-Host ""
if ($problems.Count -eq 0) {
    Write-Host "VERDICT: ready - input should be delivered normally."
}
else {
    Write-Host "VERDICT: input will NOT work:"
    foreach ($problem in $problems) { Write-Host "  - $problem" }
}
