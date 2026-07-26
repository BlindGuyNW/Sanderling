using System;
using System.Runtime.InteropServices;

namespace AlternateUiHost;

public static class WinApi
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Point
    {
        public int x;
        public int y;

        public Point(int x, int y)
        {
            this.x = x;
            this.y = y;
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    static public extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    static public extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    /*
    https://stackoverflow.com/questions/19867402/how-can-i-use-enumwindows-to-find-windows-with-a-specific-caption-title/20276701#20276701
    https://stackoverflow.com/questions/295996/is-the-order-in-which-handles-are-returned-by-enumwindows-meaningful/296014#296014
    */
    public static System.Collections.Generic.IReadOnlyList<IntPtr> ListWindowHandlesInZOrder()
    {
        var windowHandles = new System.Collections.Generic.List<IntPtr>();

        EnumWindows(delegate (IntPtr wnd, IntPtr param)
        {
            windowHandles.Add(wnd);

            // return true here so that we iterate all windows
            return true;
        }, IntPtr.Zero);

        return windowHandles;
    }

    [DllImport("user32.dll")]
    static public extern IntPtr GetWindowRect(IntPtr hWnd, ref Rect rect);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    static public extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    static public extern bool ClientToScreen(IntPtr hWnd, ref Point lpPoint);

    [DllImport("user32.dll", SetLastError = true)]
    static public extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", SetLastError = true)]
    static public extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static public extern bool GetCursorPos(out Point lpPoint);

    [DllImport("user32.dll")]
    static public extern bool GetClientRect(IntPtr hWnd, ref Rect rect);

    [DllImport("user32.dll")]
    static public extern uint MapVirtualKey(uint code, uint mapType);
}

/*
Delivers input by posting window messages instead of moving the real cursor and synthesizing global
input. This is what lets the alternative UI act on the game client without bringing its window to the
foreground, so the user keeps keyboard focus in the browser (and in their screen reader).

Measured against a live client on 2026-07-21; two constraints found empirically:

1. Mouse messages are only processed while the real cursor sits inside the window's *client* area.
   Focus does not matter, but cursor geometry does: with the cursor over the title bar or the window
   border, every posted click is discarded. Keyboard messages are not affected by this.

2. A button-down posted immediately after a move is discarded, because the client hit-tests the click
   against the pointer position it held on its previous frame. 0 ms fails; >= 60 ms works.

3. The client derives the typed character from WM_KEYDOWN by itself, so a key-down and a WM_CHAR for
   the same character enter it twice. The two are therefore alternatives, not a pair: `KeyDown`/`KeyUp`
   for keys that act (Backspace, Return, the arrows), `TypeCharacter` for text.
*/
public static class InputViaWindowMessages
{
    const uint WM_MOUSEMOVE = 0x0200;
    const uint WM_LBUTTONDOWN = 0x0201;
    const uint WM_LBUTTONUP = 0x0202;
    const uint WM_RBUTTONDOWN = 0x0204;
    const uint WM_RBUTTONUP = 0x0205;
    const uint WM_MOUSEWHEEL = 0x020A;
    const uint WM_KEYDOWN = 0x0100;
    const uint WM_KEYUP = 0x0101;
    const uint WM_CHAR = 0x0102;

    const int WHEEL_DELTA = 120;

    const int MK_LBUTTON = 0x0001;
    const int MK_RBUTTON = 0x0002;

    const int VK_LBUTTON = 0x01;
    const int VK_RBUTTON = 0x02;

    static public int MinMillisecondsFromMouseMoveToButtonDown = 80;

    static readonly object mutex = new object();

    static WinApi.Point lastMouseLocation = new WinApi.Point(0, 0);

    static readonly System.Diagnostics.Stopwatch sinceLastMouseMove = new System.Diagnostics.Stopwatch();

    static int mouseButtonsDown = 0;

    static IntPtr LParamFromLocation(int x, int y) =>
        new IntPtr((long)((((uint)y & 0xFFFF) << 16) | ((uint)x & 0xFFFF)));

    static IntPtr LParamForKey(int virtualKeyCode, bool keyUp)
    {
        var scanCode = WinApi.MapVirtualKey((uint)virtualKeyCode, 0);

        //  Repeat count 1, plus the scan code. On key-up also set the transition and previous-state bits.
        var lParam = 1u | (scanCode << 16);

        if (keyUp)
            lParam |= 0xC0000000u;

        return new IntPtr((long)lParam);
    }

    static public bool IsMouseButton(int virtualKeyCode) =>
        virtualKeyCode == VK_LBUTTON || virtualKeyCode == VK_RBUTTON;

    /*
    Only moves the real cursor when it is outside the client area, so in the common case (the game
    window covering the screen) this is a no-op and the user's pointer is left alone.
    */
    static public void EnsureCursorInsideClientArea(IntPtr windowHandle)
    {
        var clientRect = new WinApi.Rect();

        if (!WinApi.GetClientRect(windowHandle, ref clientRect))
            return;

        if (clientRect.right <= 0 || clientRect.bottom <= 0)
            return; //  Minimized: there is no client area to park the cursor in.

        var topLeft = new WinApi.Point(0, 0);
        var bottomRight = new WinApi.Point(clientRect.right, clientRect.bottom);

        if (!WinApi.ClientToScreen(windowHandle, ref topLeft))
            return;

        if (!WinApi.ClientToScreen(windowHandle, ref bottomRight))
            return;

        if (!WinApi.GetCursorPos(out var cursor))
            return;

        var alreadyInside =
            topLeft.x <= cursor.x && cursor.x < bottomRight.x &&
            topLeft.y <= cursor.y && cursor.y < bottomRight.y;

        if (alreadyInside)
            return;

        WinApi.SetCursorPos(
            (topLeft.x + bottomRight.x) / 2,
            (topLeft.y + bottomRight.y) / 2);
    }

    static public void MouseMoveTo(IntPtr windowHandle, int x, int y)
    {
        lock (mutex)
        {
            EnsureCursorInsideClientArea(windowHandle);

            lastMouseLocation = new WinApi.Point(x, y);

            WinApi.PostMessage(
                windowHandle, WM_MOUSEMOVE, new IntPtr(mouseButtonsDown), LParamFromLocation(x, y));

            sinceLastMouseMove.Restart();
        }
    }

    static public void MouseButtonDown(IntPtr windowHandle, int virtualKeyCode)
    {
        lock (mutex)
        {
            WaitForClientToPickUpMouseMove();

            var isLeft = virtualKeyCode == VK_LBUTTON;

            mouseButtonsDown |= isLeft ? MK_LBUTTON : MK_RBUTTON;

            WinApi.PostMessage(
                windowHandle,
                isLeft ? WM_LBUTTONDOWN : WM_RBUTTONDOWN,
                new IntPtr(mouseButtonsDown),
                LParamFromLocation(lastMouseLocation.x, lastMouseLocation.y));
        }
    }

    static public void MouseButtonUp(IntPtr windowHandle, int virtualKeyCode)
    {
        lock (mutex)
        {
            var isLeft = virtualKeyCode == VK_LBUTTON;

            mouseButtonsDown &= ~(isLeft ? MK_LBUTTON : MK_RBUTTON);

            WinApi.PostMessage(
                windowHandle,
                isLeft ? WM_LBUTTONUP : WM_RBUTTONUP,
                new IntPtr(mouseButtonsDown),
                LParamFromLocation(lastMouseLocation.x, lastMouseLocation.y));
        }
    }

    /*
    Rotates the mouse wheel over the given client-area location. The client scrolls the container
    under that position; measured against the settings window on 2026-07-23, one tick moves the
    content 50 px, several ticks in one message accumulate, and the client clamps cleanly at both
    ends of the content. Negative ticks scroll the view down (reveal content below), as on a
    physical wheel.

    Two things differ from the button messages: WM_MOUSEWHEEL carries SCREEN coordinates in its
    lParam where every other mouse message carries client coordinates, and the wheel delta rides
    in the high word of wParam. The preceding WM_MOUSEMOVE and the settle wait are kept because
    the client hit-tests the wheel against its pointer position the same way it does a click.
    */
    static public void VerticalScroll(IntPtr windowHandle, int x, int y, int deltaTicks)
    {
        lock (mutex)
        {
            EnsureCursorInsideClientArea(windowHandle);

            lastMouseLocation = new WinApi.Point(x, y);

            WinApi.PostMessage(
                windowHandle, WM_MOUSEMOVE, new IntPtr(mouseButtonsDown), LParamFromLocation(x, y));

            sinceLastMouseMove.Restart();

            WaitForClientToPickUpMouseMove();

            var screenPoint = new WinApi.Point(x, y);

            if (!WinApi.ClientToScreen(windowHandle, ref screenPoint))
                return;

            var wParam = new IntPtr((long)(((uint)(deltaTicks * WHEEL_DELTA) & 0xFFFF) << 16));

            WinApi.PostMessage(
                windowHandle, WM_MOUSEWHEEL, wParam, LParamFromLocation(screenPoint.x, screenPoint.y));
        }
    }

    static public void KeyDown(IntPtr windowHandle, int virtualKeyCode)
    {
        WinApi.PostMessage(
            windowHandle, WM_KEYDOWN, new IntPtr(virtualKeyCode), LParamForKey(virtualKeyCode, false));
    }

    static public void KeyUp(IntPtr windowHandle, int virtualKeyCode)
    {
        WinApi.PostMessage(
            windowHandle, WM_KEYUP, new IntPtr(virtualKeyCode), LParamForKey(virtualKeyCode, true));
    }

    /// <summary>
    /// Enter one character of text, whatever key would produce it.
    /// </summary>
    /// <remarks>
    /// Typing by posting key-downs can only reach what an unmodified key produces: a posted modifier
    /// does not register as held (a posted Ctrl+A typed a literal "a", measured 2026-07-23), so
    /// uppercase and every shifted symbol were unreachable, and text arrived lowercase and unpunctuated.
    /// That is tolerable in a search box and not in a corporation application someone has to read.
    ///
    /// WM_CHAR carries the character itself rather than a key, so it needs no modifier state. Measured
    /// on a live client 2026-07-26: posted alone into the application text area, "XY, it's!" arrived
    /// exactly, capitals, comma, apostrophe and all. Alone is the operative word - see note 3 above.
    /// </remarks>
    static public void TypeCharacter(IntPtr windowHandle, int characterCode)
    {
        WinApi.PostMessage(windowHandle, WM_CHAR, new IntPtr(characterCode), new IntPtr(1));
    }

    static void WaitForClientToPickUpMouseMove()
    {
        if (!sinceLastMouseMove.IsRunning)
            return;

        var remaining = MinMillisecondsFromMouseMoveToButtonDown - (int)sinceLastMouseMove.ElapsedMilliseconds;

        if (0 < remaining)
            System.Threading.Thread.Sleep(remaining);
    }
}
