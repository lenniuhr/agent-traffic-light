# Agent Traffic Light
#
# An always-on-top card showing the live state of every coding agent session.
# See README.md for why it works the way it does. The short version:
#
# The source of truth is the set of Windows Terminal windows, not
# ~/.claude/sessions/*.json. The session files are written on state change and
# never heartbeated (measured 892 s stale on a live session), so they can never
# tell us a session died. Windows can: the window closes and the row goes away.
#
# Run with -Probe to get stage-1 console output instead of the card.

param(
    [switch]$Probe,
    # Probe passes to run before exiting. 0 runs until Ctrl+C.
    [int]$Passes = 0,
    # With -Probe: print the repos the New session menus offer, and every
    # project folder left out and why, instead of the windows.
    [switch]$Launch,
    # With -Probe -Launch: read this folder in place of ~/.claude/projects, so
    # the list can be checked against a made-up one.
    [string]$ProjectsDir = '',
    # Set by the card on the copy of itself it hands over to; see below.
    [switch]$Detached
)

# The card never hangs off a terminal. Started from one, by hand or by an
# agent, its console is a terminal window whose closing ends the card, and
# -WindowStyle Hidden cannot hide that window once Windows Terminal hosts the
# console. So every start but a probe hands over to a copy of itself made with
# no console window at all, and the starting process ends at once. The copy
# has a console of its own, which no terminal closing can reach.
if (-not $Probe -and -not $Detached) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "' + $PSCommandPath + '" -Detached'
    $psi.WorkingDirectory = $PSScriptRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [void][System.Diagnostics.Process]::Start($psi)
    exit 0
}

$ErrorActionPreference = 'Stop'

# The widget runs with its console hidden, so an unhandled error would otherwise
# vanish without a trace. Everything that escapes lands in state/error.log.
$errorLog = Join-Path $PSScriptRoot 'state\error.log'
function Write-ErrorLog {
    param([string]$Where, $Problem)
    try {
        $line = "{0} [{1}] {2}" -f (Get-Date -Format 'o'), $Where, ($Problem | Out-String).Trim()
        Add-Content -Path $errorLog -Value $line -Encoding UTF8
    } catch { }
}
trap {
    Write-ErrorLog -Where 'startup' -Problem $_
    break
}

$stateDir = Join-Path $PSScriptRoot 'state'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }
$positionFile = Join-Path $stateDir 'window-position.json'

# ---------------------------------------------------------------------------
# Tuning. Sizes and colours live in the presets folder; only timings live here,
# because they are driven from code rather than from storyboards.
# ---------------------------------------------------------------------------
$titlePollMs   = 400    # reading titles of known handles costs 0.35 ms
$windowSweepMs = 3000   # a full EnumWindows sweep costs 6.2 ms, peaks at 36 ms
$ctxHighMark   = 0.8  # fraction of the window at which the bar turns amber
$transcriptTail = 98304  # bytes read from the end of a transcript
$transcriptTailMax = 1572864  # furthest back the read widens to find a usage record
$shadowMargin  = 12
$flipMs        = 180    # colour change and slide when a row changes state
$blinkMs       = 600    # one beat of the three-beat permission alarm
$breatheMs     = 2000   # permission settles into this after the beats
$spinTurnMs    = 1400   # one turn of the working ring, the only motion on a calm card
$endlessFps    = 60     # the ring and the alarm's breathe never stop; unset, each redraws the whole card at the screen's rate, 180 a second on a 180 Hz screen, which cost a third of a core
$soundSettleMs = 1200   # a stop must outlast this before its sound plays, so a title that flickers between tools stays silent
$marshalStaleMin = 40   # Marshal rounds every 15 minutes, so a report this old means two missed rounds and a Marshal that has stopped

# ---------------------------------------------------------------------------
# Glyph vocabulary. Written as code points on purpose: PowerShell 5.1 reads a
# script file as ANSI unless it has a BOM, which would mangle these characters
# if they appeared literally.
# ---------------------------------------------------------------------------
$glyphWorking = @([char]0x25D0, [char]0x25D1, [char]0x25D2, [char]0x25D3, [char]0x00B7)
$glyphWaiting = @([char]0x2733)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public class TlNative {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder s, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    // The link that makes workspaces knowable. A session's shell owns a hidden
    // PseudoConsoleWindow, and that window's parent is exactly the Windows
    // Terminal window showing it. Verified against known session/window pairs.
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool doAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();

    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO {
        public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout;
    }
    [DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    // Parent-pid lookup via a process snapshot. The obvious PowerShell way,
    // Get-CimInstance Win32_Process, measured 300-470 ms, which is a visible
    // hitch on the UI thread every time the map is rebuilt. This is under 10.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PROCESSENTRY32W {
        public uint dwSize; public uint cntUsage; public uint th32ProcessID;
        public IntPtr th32DefaultHeapID; public uint th32ModuleID; public uint cntThreads;
        public uint th32ParentProcessID; public int pcPriClassBase; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll")] public static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32W pe);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32W pe);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);

    // Every process with its parent and exe name, from one snapshot. The whole
    // table rather than claude.exe alone, because what a remote session is can
    // only be told from its ancestry: one started over ssh or through WSL
    // descends from a service, and an ssh client in a terminal sits under that
    // terminal's shell.
    public class ProcEntry { public int Parent; public string Name; }

    public static System.Collections.Generic.Dictionary<int, ProcEntry> ProcessTable() {
        var map = new System.Collections.Generic.Dictionary<int, ProcEntry>();
        IntPtr snap = CreateToolhelp32Snapshot(0x00000002, 0); // TH32CS_SNAPPROCESS
        if (snap == new IntPtr(-1)) { return map; }
        PROCESSENTRY32W pe = new PROCESSENTRY32W();
        pe.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
        if (Process32FirstW(snap, ref pe)) {
            do {
                ProcEntry e = new ProcEntry();
                e.Parent = (int)pe.th32ParentProcessID;
                e.Name = pe.szExeFile;
                map[(int)pe.th32ProcessID] = e;
            } while (Process32NextW(snap, ref pe));
        }
        CloseHandle(snap);
        return map;
    }

    // The window scan, done here rather than in PowerShell. EnumWindows calls
    // its callback once per top-level window, a few hundred times on a normal
    // desktop, and a PowerShell scriptblock as that callback cost about 40 ms
    // per sweep. The same walk in C# is a couple of milliseconds.
    public class ScanResult {
        public System.Collections.Generic.List<IntPtr> Terminals = new System.Collections.Generic.List<IntPtr>();
        public System.Collections.Generic.Dictionary<int, IntPtr> ShellToWindow = new System.Collections.Generic.Dictionary<int, IntPtr>();
    }

    public static ScanResult Scan(string terminalClass) {
        ScanResult res = new ScanResult();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            StringBuilder cls = new StringBuilder(256);
            GetClassNameW(h, cls, 256);
            string name = cls.ToString();
            if (name == terminalClass) {
                if (IsWindowVisible(h)) { res.Terminals.Add(h); }
            } else if (name == "PseudoConsoleWindow") {
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                IntPtr parent = GetParent(h);
                if (parent != IntPtr.Zero) { res.ShellToWindow[(int)owner] = parent; }
            }
            return true;
        }, IntPtr.Zero);
        return res;
    }

    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int index, int newLong);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);

    // Flash the taskbar button as the fallback when Windows refuses to hand over
    // the foreground. FLASHW_ALL | FLASHW_TIMERNOFG.
    public static void Flash(IntPtr hWnd) {
        FLASHWINFO fi = new FLASHWINFO();
        fi.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        fi.hwnd = hWnd;
        fi.dwFlags = 0x00000003 | 0x0000000C;
        fi.uCount = 3;
        fi.dwTimeout = 0;
        FlashWindowEx(ref fi);
    }

    // Windows refuses SetForegroundWindow from a process that does not own the
    // foreground. Clicking the card makes us the foreground process, which is
    // allowed to hand it on, but attaching to the current foreground thread
    // first is what makes it reliable. Returns false if Windows still says no,
    // and the caller falls back to flashing.
    public static bool Focus(IntPtr hWnd) {
        if (!IsWindow(hWnd)) { return false; }
        if (IsIconic(hWnd)) { ShowWindow(hWnd, 9); } // SW_RESTORE

        IntPtr fg = GetForegroundWindow();
        uint fgPid;
        uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
        uint myThread = GetCurrentThreadId();

        bool attached = false;
        if (fgThread != myThread) { attached = AttachThreadInput(myThread, fgThread, true); }
        BringWindowToTop(hWnd);
        bool ok = SetForegroundWindow(hWnd);
        if (attached) { AttachThreadInput(myThread, fgThread, false); }

        if (!ok) { Flash(hWnd); }
        return ok;
    }

    // Asks a window to close, the way its own close button does. Windows
    // Terminal then ends what runs in it.
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    public static bool Close(IntPtr hWnd) {
        return IsWindow(hWnd) && PostMessage(hWnd, 0x0010, IntPtr.Zero, IntPtr.Zero);
    }

    // Double-click maximize. The window is put back later exactly where it was,
    // so a snapshot of it is taken first: its placement, which holds the
    // display, the restore position and size, and whether it is normal,
    // minimized or maximized; and the rectangle it really covers. The two
    // differ for a window snapped to a screen edge, whose placement still holds
    // the size it had before the snap.
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT {
        public uint length; public uint flags; public uint showCmd;
        public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO { public uint cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT wp);
    [DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT wp);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rc);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO mi);

    public class WindowSpot {
        public WINDOWPLACEMENT Placement;
        public RECT Bounds;
    }

    // Where a window is right now, or null if it has closed.
    public static WindowSpot GetSpot(IntPtr hWnd) {
        if (!IsWindow(hWnd)) { return null; }
        WindowSpot spot = new WindowSpot();
        spot.Placement.length = (uint)Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        if (!GetWindowPlacement(hWnd, ref spot.Placement)) { return null; }
        GetWindowRect(hWnd, out spot.Bounds);
        return spot;
    }

    // 0,0 is on the primary display by definition. MONITOR_DEFAULTTOPRIMARY.
    static IntPtr PrimaryMonitor() { return MonitorFromPoint(new POINT(), 1); }

    // True while a window is still maximized on the primary display, the way a
    // double-click left it. Anything else means it was moved by hand since.
    public static bool IsMaximizedOnPrimary(IntPtr hWnd) {
        return IsWindow(hWnd) && IsZoomed(hWnd) && MonitorFromWindow(hWnd, 2) == PrimaryMonitor();
    }

    // Maximizing fills whichever display the window is on, so a window on
    // another display is first brought onto the primary one in its normal
    // state, centred at its own size. A placement with SW_SHOWNORMAL does that
    // from maximized or minimized too. Returns false if the window has closed.
    public static bool MaximizeOnPrimary(IntPtr hWnd) {
        if (!IsWindow(hWnd)) { return false; }
        IntPtr primary = PrimaryMonitor();
        if (MonitorFromWindow(hWnd, 2) != primary) { // MONITOR_DEFAULTTONEAREST
            MONITORINFO mi = new MONITORINFO();
            mi.cbSize = (uint)Marshal.SizeOf(typeof(MONITORINFO));
            WINDOWPLACEMENT wp = new WINDOWPLACEMENT();
            wp.length = (uint)Marshal.SizeOf(typeof(WINDOWPLACEMENT));
            if (GetMonitorInfo(primary, ref mi) && GetWindowPlacement(hWnd, ref wp)) {
                int workW = mi.rcWork.Right - mi.rcWork.Left;
                int workH = mi.rcWork.Bottom - mi.rcWork.Top;
                int w = Math.Min(wp.rcNormalPosition.Right - wp.rcNormalPosition.Left, workW);
                int h = Math.Min(wp.rcNormalPosition.Bottom - wp.rcNormalPosition.Top, workH);
                // Placements are in workspace coordinates, in which the
                // primary display's work area starts at 0,0.
                wp.rcNormalPosition.Left = (workW - w) / 2;
                wp.rcNormalPosition.Top = (workH - h) / 2;
                wp.rcNormalPosition.Right = wp.rcNormalPosition.Left + w;
                wp.rcNormalPosition.Bottom = wp.rcNormalPosition.Top + h;
                wp.flags = 0;
                wp.showCmd = 1; // SW_SHOWNORMAL
                SetWindowPlacement(hWnd, ref wp);
            }
        }
        ShowWindow(hWnd, 3); // SW_MAXIMIZE
        Focus(hWnd);
        return true;
    }

    // Puts a window back exactly where a snapshot found it. Through its normal
    // state on its own display first, then maximized or minimized from there,
    // because maximizing a window already maximized on another display leaves
    // it where it is. A window maximized where it already was is not touched,
    // so it does not flicker through its normal size. Returns false if the
    // window has closed.
    public static bool RestoreSpot(IntPtr hWnd, WindowSpot spot) {
        if (spot == null || !IsWindow(hWnd)) { return false; }
        WINDOWPLACEMENT wp = spot.Placement;
        bool minimized = wp.showCmd == 2; // SW_SHOWMINIMIZED, as GetWindowPlacement reports it
        bool maximized = wp.showCmd == 3 || (minimized && (wp.flags & 2) != 0); // WPF_RESTORETOMAXIMIZED

        WINDOWPLACEMENT now = new WINDOWPLACEMENT();
        now.length = (uint)Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        GetWindowPlacement(hWnd, ref now);
        RECT a = now.rcNormalPosition, b = wp.rcNormalPosition;
        bool untouched = IsZoomed(hWnd) && a.Left == b.Left && a.Top == b.Top && a.Right == b.Right && a.Bottom == b.Bottom;

        if (!(maximized && untouched)) {
            wp.flags = 0;
            wp.showCmd = 4; // SW_SHOWNOACTIVATE: restored without taking the focus
            SetWindowPlacement(hWnd, ref wp);
            if (maximized) {
                ShowWindow(hWnd, 3); // SW_MAXIMIZE, on the display it is now back on
            } else if (!minimized) {
                RECT r = spot.Bounds;
                SetWindowPos(hWnd, IntPtr.Zero, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, 0x0014); // SWP_NOZORDER | SWP_NOACTIVATE
            }
        }
        // SW_MINIMIZE hands the focus on, as minimizing by hand does.
        if (minimized) { ShowWindow(hWnd, 6); }
        return true;
    }
}

// The Windows job objects that hold a Unity editor's CPU limit; why is under
// "CPU limits on Unity editors". In the same compile as TlNative, because each
// Add-Type costs the card's start a compile of its own.
public static class TlUnityCap {
    // JOBOBJECT_CPU_RATE_CONTROL_INFORMATION. The struct cannot share its name
    // with its CpuRate field, C# refuses that.
    [StructLayout(LayoutKind.Sequential)]
    struct CpuRateInfo { public uint ControlFlags; public uint CpuRate; }

    // JOBOBJECT_BASIC_LIMIT_INFORMATION. Only LimitFlags and PriorityClass are set.
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimitInfo {
        public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref CpuRateInfo info, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref BasicLimitInfo info, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

    // Opens the editor's job, creating it the first time. The name carries the
    // editor's process id, so a card that restarts opens the job it made before
    // instead of making a second one.
    public static IntPtr Open(int editorId) {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, "AgentTrafficLight-Unity-" + editorId);
        if (job == IntPtr.Zero) { throw new Exception("CreateJobObject error " + Marshal.GetLastWin32Error()); }
        return job;
    }

    // Percent is the most CPU every process in the job may use together, in
    // percent of the whole machine; 0 lifts the cap. Idle holds every process in
    // the job at idle priority, the ones started later included. Never sets
    // KILL_ON_JOB_CLOSE: the editors must outlive the card.
    public static void SetLimits(IntPtr job, int percent, bool idle) {
        CpuRateInfo rate = new CpuRateInfo();
        if (percent > 0) {
            rate.ControlFlags = 0x1 | 0x4; // ENABLE | HARD_CAP
            rate.CpuRate = (uint)(percent * 100); // in hundredths of a percent
        }
        if (!SetInformationJobObject(job, 15, ref rate, Marshal.SizeOf(typeof(CpuRateInfo)))) {
            throw new Exception("CPU rate limit error " + Marshal.GetLastWin32Error());
        }
        BasicLimitInfo basic = new BasicLimitInfo();
        if (idle) {
            basic.LimitFlags = 0x20; // JOB_OBJECT_LIMIT_PRIORITY_CLASS
            basic.PriorityClass = 0x40; // IDLE_PRIORITY_CLASS
        }
        if (!SetInformationJobObject(job, 2, ref basic, Marshal.SizeOf(typeof(BasicLimitInfo)))) {
            throw new Exception("Priority limit error " + Marshal.GetLastWin32Error());
        }
    }

    // Puts a process in the job. False when it was in it already, which is
    // every sweep after the first, so the check is cheap and nothing is redone.
    public static bool Add(IntPtr job, int pid) {
        IntPtr process = OpenProcess(0x0100 | 0x0001 | 0x1000, false, pid); // SET_QUOTA | TERMINATE | QUERY_LIMITED_INFORMATION
        if (process == IntPtr.Zero) { throw new Exception("OpenProcess " + pid + " error " + Marshal.GetLastWin32Error()); }
        try {
            bool inJob;
            if (IsProcessInJob(process, job, out inJob) && inJob) { return false; }
            if (!AssignProcessToJobObject(job, process)) {
                throw new Exception("AssignProcessToJobObject " + pid + " error " + Marshal.GetLastWin32Error());
            }
            return true;
        } finally { CloseHandle(process); }
    }

    public static void Close(IntPtr job) { CloseHandle(job); }
}
"@

# Keeps the card at its own height while Windows moves it. A drag runs in
# Windows' move loop, which on every step proposes the window at the size it
# had when the drag began, so a row closing or opening mid-drag resized the
# card's layout but not its window: a strip of empty card, or a cut-off one,
# stayed until the drag ended. Each step's proposal (WM_MOVING) passes through
# this hook, which gives it the card's current height. In C#, because it runs
# on every step of the drag, where a PowerShell handler made the move stutter.
Add-Type -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

public static class TlMoveSize {
    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    const int WM_MOVING = 0x0216;
    static Window card;
    static HwndSourceHook hook;

    public static void Attach(Window window) {
        card = window;
        hook = Hook;
        HwndSource.FromHwnd(new WindowInteropHelper(window).Handle).AddHook(hook);
    }

    static IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
        if (msg != WM_MOVING || card == null) return IntPtr.Zero;
        PresentationSource source = PresentationSource.FromVisual(card);
        if (source == null || source.CompositionTarget == null) return IntPtr.Zero;
        int height = (int)Math.Round(card.Height * source.CompositionTarget.TransformToDevice.M22);
        RECT r = (RECT)Marshal.PtrToStructure(lParam, typeof(RECT));
        if (r.Bottom - r.Top != height) {
            r.Bottom = r.Top + height;
            Marshal.StructureToPtr(r, lParam, false);
        }
        return IntPtr.Zero;
    }
}
"@

$GWL_EXSTYLE       = -20
$WS_EX_TOOLWINDOW  = 0x00000080
$SW_HIDE           = 0
$TERMINAL_CLASS    = 'CASCADIA_HOSTING_WINDOW_CLASS'

# Parsed session files, keyed by path, invalidated by last-write time.
$script:sessionFileCache = @{}

# Transcript lookups. Paths are resolved once per session; the facts read out of
# each transcript are invalidated by last-write time, so an idle session costs
# nothing beyond a stat.
$script:transcriptPaths = @{}
$script:transcriptCache = @{}

# Claude reports no exact context figure anywhere, so the window is a fixed
# assumption. It used to be read from the default model in settings.json, once
# at startup, and was wrong both ways: /model rewrites that default while the
# widget runs, so a card started under "fable" kept dividing by 200k after the
# default went back to "opus[1m]", and the [1m] suffix never decided the window
# anyway. Every /context reading recorded on this machine showed 1m for Opus 5,
# Fable 5 and Fable 5.1 alike, with or without the suffix.
$script:contextWindow = 1000000

# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------

# One enumeration, two answers: which terminal windows exist, and which shell
# process owns which of them. Both are needed on every sweep and walking the
# whole window list twice was the single biggest cost in it.
#
# Runs on the slow timer. It decides which windows exist, never what state they
# are in; that comes from the titles on the fast timer.
function Scan-Windows {
    return [TlNative]::Scan($TERMINAL_CLASS)
}

function Get-WindowTitle {
    param([IntPtr]$Handle)
    if (-not [TlNative]::IsWindow($Handle)) { return $null }
    $sb = New-Object System.Text.StringBuilder 512
    [TlNative]::GetWindowTextW($Handle, $sb, 512) | Out-Null
    return $sb.ToString()
}

# A title is ours only if it starts with a glyph we know. That filter is what
# keeps a plain terminal window, or someone's unrelated shell, off the card.
function Read-SessionTitle {
    param([string]$Title)
    if ([string]::IsNullOrEmpty($Title)) { return $null }
    $lead = $Title[0]
    $state = $null
    if ($glyphWorking -contains $lead) { $state = 'Working' }
    elseif ($glyphWaiting -contains $lead) { $state = 'Waiting' }
    else { return $null }
    $label = $Title.Substring(1).Trim()
    # A window showing a tmux session on another machine ends its title with
    # "  @" and the session's name, which says exactly which session it is.
    $tmuxName = ''
    $tail = [regex]::Match($label, '\s{2}@([A-Za-z0-9_.-]+)$')
    if ($tail.Success) {
        $tmuxName = $tail.Groups[1].Value
        $label = $label.Substring(0, $tail.Index).Trim()
    }
    if ($label -eq '') { $label = 'Session' }
    return @{ State = $state; Label = $label; TmuxName = $tmuxName }
}

# Live interactive sessions, whether or not their window could be resolved.
# Only used to notice that the card is showing fewer rows than there are
# sessions, which is the tabbed-window failure the plan warns about.
function Get-LiveSessionCount {
    $dir = Join-Path $env:USERPROFILE '.claude\sessions'
    if (-not (Test-Path $dir)) { return 0 }
    $n = 0
    foreach ($f in (Get-ChildItem $dir -Filter *.json -ErrorAction SilentlyContinue)) {
        try {
            $s = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if ($s.kind -ne 'interactive') { continue }
            if (Get-Process -Id $s.pid -ErrorAction SilentlyContinue) { $n++ }
        } catch { }
    }
    return $n
}

# ---------------------------------------------------------------------------
# Remote sessions, both ways.
#
# Incoming: a session on this PC that someone drives from another machine. It
# was started by ssh or through WSL, not from a desktop the user sits at, so it
# owns no terminal window and has no title to read. Its row is keyed by a
# negative number made from its pid instead of a window handle, and its state
# comes from the session file's busy/idle and its title from the transcript.
#
# Outgoing: a terminal on this PC running ssh to another machine, with a Claude
# session at the far end. Its title already carries the remote session's glyph,
# so it was always a row; it only lacked a workspace, because no session file
# here belongs to it. It is now filed under the host it connects to.
# ---------------------------------------------------------------------------

# Processes only a session started from elsewhere descends from. A session a
# person starts at this desktop descends from explorer.exe instead. Positive
# evidence rather than "no explorer above it", because a session whose launcher
# has exited loses its ancestry and would otherwise read as remote.
$remoteAncestors = @('sshd.exe', 'wslhost.exe', 'wslservice.exe', 'services.exe')

# How a session got here, or '' for one started at this desktop.
function Get-IncomingVia {
    param($Table, [int]$ProcessId)
    $seen = @{}
    $p = $ProcessId
    for ($i = 0; $i -lt 16; $i++) {
        if ($seen.ContainsKey($p) -or -not $Table.ContainsKey($p)) { return '' }
        $seen[$p] = $true
        $name = [string]$Table[$p].Name
        if ($name -ieq 'explorer.exe') { return '' }
        if ($remoteAncestors -contains $name.ToLowerInvariant()) {
            if ($name -ieq 'sshd.exe') { return 'ssh' }
            if ($name -like 'wsl*') { return 'wsl' }
            return 'service'
        }
        $p = $Table[$p].Parent
    }
    return ''
}

# The host an ssh command line connects to, without its user@. Options that
# take a value are skipped with their value, so "-p 2222 -i key office-pc"
# gives office-pc. Read once per ssh process: the command line comes from WMI,
# which is far too slow for every sweep.
$script:sshHostCache = @{}
$sshValueOptions = 'BbcDEeFIiJLlmOoPpQRSWw'

function Get-SshHost {
    param([int]$ProcessId)
    if ($script:sshHostCache.ContainsKey($ProcessId)) { return $script:sshHostCache[$ProcessId] }
    $hostName = 'remote'
    try {
        $line = (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop).CommandLine
        $tokens = @([regex]::Matches([string]$line, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') })
        for ($i = 1; $i -lt $tokens.Count; $i++) {
            $t = $tokens[$i]
            if ($t.StartsWith('-')) {
                # "-p 2222" takes the next token; "-p2222" carries its own.
                if ($t.Length -eq 2 -and $sshValueOptions.Contains($t[1])) { $i++ }
                continue
            }
            $hostName = ($t -split '@')[-1]
            break
        }
        # A session reached through tmux at the far end outlives this window.
        $script:sshKeepsCache[$ProcessId] = [bool]($line -match $keepsPattern)
    } catch { }
    $script:sshHostCache[$ProcessId] = $hostName
    return $hostName
}

# Whether the far end of an ssh command line runs in tmux, so the session keeps
# running when its window here closes: the launcher, the session list, or a
# plain tmux attach.
$script:sshKeepsCache = @{}
$keepsPattern = '\b(claude-in|office-sessions|tmux|agent)\b'

# Window key -> host, for every terminal window that holds a running ssh. The
# ssh is either the tab's own process, owning the console, or a child or
# grandchild of the shell that does.
function Get-OutgoingWindows {
    param($Table, $ShellToWindow)
    $out = @{}
    $keeps = @{}
    foreach ($id in @($Table.Keys)) {
        if ($Table[$id].Name -ine 'ssh.exe') { continue }
        $p = $id
        for ($i = 0; $i -lt 4; $i++) {
            if ($ShellToWindow.ContainsKey($p)) {
                $key = [string][int64]$ShellToWindow[$p]
                $out[$key] = Get-SshHost -ProcessId $id
                $keeps[$key] = [bool]$script:sshKeepsCache[$id]
                break
            }
            if (-not $Table.ContainsKey($p)) { break }
            $p = $Table[$p].Parent
        }
    }
    foreach ($id in @($script:sshHostCache.Keys)) {
        if (-not $Table.ContainsKey($id)) { $script:sshHostCache.Remove($id); $script:sshKeepsCache.Remove($id) }
    }
    $script:outgoingKeeps = $keeps
    return $out
}

# ---------------------------------------------------------------------------
# Kept sessions: Claude sessions that run in tmux, on another machine or in WSL
# here, and so keep running after the window that opened them closes. Without
# this they vanish from the card the moment their window closes, which is
# exactly when they need finding again.
#
# state\remotes.txt says where to look, one place per line: an ssh target such
# as jonathan@office, or "wsl" or "wsl:Ubuntu" for this PC's own WSL. Each place is asked for
# its list with "office-sessions --list" every few seconds, in a process of its
# own so the card never waits on the network. A line of that list is
#   name|window|state|claude session id|title|helpers
# where window is "remote", "local" or "" for no window anywhere, and helpers
# is how many helper agents the session has running, from a place new enough.
#
# A session with no window gets a row of its own, keyed by a large negative
# number so it can collide with neither a window handle nor an incoming row's
# negated pid; a click on it opens a terminal attached to it. A session whose
# window is open on another PC needs no row on this one.
# ---------------------------------------------------------------------------
$remotesFile  = Join-Path $stateDir 'remotes.txt'
$keptPollSec  = 6
$keptLimitSec = 20
$keptFade     = 0.5   # opacity of a row with no window connected, so it reads as not connected
$keptFadeMs   = 160   # how long that fade, and the Reconnect veil's, takes
$script:keptSources = @{}     # place -> its poll: process, start time, last list, problem
$script:keptByKey = @{}       # row key -> the kept session or the place's problem behind that row
$script:keptKeyOf = @{}       # "place|name" -> row key, so a session keeps its row between polls
$script:keptBySessionId = @{} # Claude session id -> kept session, for this PC's incoming rows
$script:nextKeptKey = [int64]-1000000000000
$script:outgoingKeeps = @{}
$script:keptPlaces = @()
$script:keptOpening = @{}     # "place|name" -> when its row was clicked to reopen it
$script:keptEnding = @{}      # "place|name" -> when it was asked to end

function Get-KeptPlaces {
    if (-not (Test-Path $remotesFile)) { return @() }
    return @(Get-Content $remotesFile -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

# Whether a place is this PC's WSL: "wsl" for the default distribution, or
# "wsl:<name>" for a named one. The default is not always the one running the
# sessions; Docker Desktop makes itself the default, for one.
function Test-WslPlace {
    param([string]$Place)
    return ($Place -eq 'wsl' -or $Place -like 'wsl:*')
}

# The wsl.exe arguments that reach a WSL place's distribution.
function Get-WslPrefix {
    param([string]$Place)
    if ($Place -like 'wsl:*') { return '-d ' + $Place.Substring(4) + ' -e ' }
    return '-e '
}

# The name a place goes by on the card: the host of an ssh target, the same
# name its outgoing windows are grouped under, or "this PC" for WSL.
function Get-KeptPlaceName {
    param([string]$Place)
    if (Test-WslPlace -Place $Place) { return 'this PC' }
    return ($Place -split '@')[-1]
}

# The same place in a sentence: "the office PC", or "this PC" for WSL.
function Get-KeptPlaceLong {
    param([string]$Place)
    if (Test-WslPlace -Place $Place) { return 'this PC' }
    return 'the ' + (Get-KeptPlaceName -Place $Place) + ' PC'
}

# Runs one short command at a place, hidden, without waiting for it.
function Invoke-AtKeptPlace {
    param([string]$Place, [string]$Command)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if (Test-WslPlace -Place $Place) {
        $psi.FileName = 'wsl.exe'
        $psi.Arguments = (Get-WslPrefix -Place $Place) + $Command
    } else {
        $psi.FileName = 'ssh.exe'
        $psi.Arguments = '-n -o BatchMode=yes -o ConnectTimeout=5 ' + $Place + ' ' + $Command
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [void][System.Diagnostics.Process]::Start($psi)
}

# Lets go of a kept session without ending it: every window showing it closes,
# and Claude keeps running where it is. Its row turns faded a moment later.
function Disconnect-KeptSession {
    param($Kept)
    Invoke-AtKeptPlace -Place $Kept.Place -Command ('tmux detach-client -s =' + $Kept.Name)
    $poll = $script:keptSources[$Kept.Place]
    if ($null -ne $poll) { $poll.NextAt = (Get-Date).AddSeconds(1) }
}

function Start-KeptPoll {
    param([string]$Place)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if (Test-WslPlace -Place $Place) {
        $psi.FileName = 'wsl.exe'
        $psi.Arguments = (Get-WslPrefix -Place $Place) + 'office-sessions --list'
    } else {
        $psi.FileName = 'ssh.exe'
        # -n gives ssh empty input. Without it the far end waits for input the card never sends,
        # the poll runs into its time limit, and the place shows as "Cannot reach it".
        $psi.Arguments = '-n -o BatchMode=yes -o ConnectTimeout=5 ' + $Place + ' office-sessions --list'
    }
    # --helpers adds each session's running helper agents. --mine leaves out the
    # sessions other people started there. A place too old to know either
    # ignores it.
    $psi.Arguments += ' --helpers'
    if (-not $script:settings.ShowOthersSessions) { $psi.Arguments += ' --mine' }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    return [System.Diagnostics.Process]::Start($psi)
}

function ConvertFrom-KeptList {
    param([string]$Place, [string]$Text)
    $list = New-Object System.Collections.ArrayList
    foreach ($line in ($Text -split "`n")) {
        $parts = $line.TrimEnd("`r").Split('|', 5)
        if ($parts.Count -lt 5 -or -not $parts[0]) { continue }
        # Asked with --helpers, a place adds how many helper agents each
        # session has running as a last field, after the title. A place too old
        # to know it leaves the title last and its sessions at 0.
        $title = $parts[4]
        $helpers = 0
        if ($title -match '^(.*)\|(\d+)$') { $title = $matches[1]; $helpers = [int]$matches[2] }
        [void]$list.Add(@{
            Place = $Place; Name = $parts[0]; Window = $parts[1]
            State = $(if ($parts[2] -eq 'working') { 'Working' } else { 'Waiting' })
            SessionId = $parts[3]; Title = $title; Helpers = $helpers
        })
    }
    return $list
}

# Asks a host again as soon as it can: a window to it opened or closed here, so
# a session there has just gained or lost its window. Without this the row sat
# missing, or doubled, until the next round came up.
function Request-KeptPoll {
    param([string]$HostName)
    foreach ($place in @($script:keptSources.Keys)) {
        if ((Get-KeptPlaceName -Place $place) -eq $HostName) { $script:keptSources[$place].NextAt = [datetime]::MinValue }
    }
}

# Collects finished polls and starts the next ones. Runs on the fast timer as
# well as the slow one, so an answer is shown the moment it arrives; with no
# poll finished and none due it costs next to nothing. The places are read
# from their file on the slow timer only.
function Update-KeptSessions {
    param([switch]$ReadPlaces)
    $now = Get-Date
    if ($ReadPlaces) { $script:keptPlaces = Get-KeptPlaces }
    $places = @($script:keptPlaces)
    foreach ($place in @($script:keptSources.Keys)) {
        if ($places -notcontains $place) { $script:keptSources.Remove($place) }
    }
    $changed = $false
    foreach ($place in $places) {
        $poll = $script:keptSources[$place]
        if ($null -eq $poll) {
            $poll = @{ Proc = $null; StartedAt = $now; NextAt = [datetime]::MinValue; Sessions = @(); Problem = '' }
            $script:keptSources[$place] = $poll
        }
        if ($null -ne $poll.Proc) {
            $done = $poll.Proc.HasExited
            if (-not $done -and ($now - $poll.StartedAt).TotalSeconds -gt $keptLimitSec) {
                try { $poll.Proc.Kill() } catch { }
                $done = $true
            }
            if ($done) {
                $out = ''; $err = ''
                try { $out = $poll.Proc.StandardOutput.ReadToEnd(); $err = $poll.Proc.StandardError.ReadToEnd() } catch { }
                $ok = $poll.Proc.HasExited -and $poll.Proc.ExitCode -eq 0
                $poll.Proc.Dispose()
                $poll.Proc = $null
                if ($ok) {
                    $poll.Sessions = @(ConvertFrom-KeptList -Place $place -Text $out)
                    $poll.Problem = ''
                } else {
                    # Tailscale asks for a fresh sign-in now and then and waits
                    # for it, which a poll cannot give. Any other failure means
                    # the place cannot be reached: switched off, or asleep.
                    $poll.Sessions = @()
                    $poll.Problem = $(if ($err -match 'additional check|login\.tailscale|tailscale\.com/') { 'signin' } else { 'unreachable' })
                }
                $changed = $true
            }
        }
        if ($null -eq $poll.Proc -and $now -ge $poll.NextAt) {
            $poll.StartedAt = $now
            $poll.NextAt = $now.AddSeconds($keptPollSec)
            try { $poll.Proc = Start-KeptPoll -Place $place } catch { $poll.Problem = 'unreachable'; $changed = $true }
        }
    }
    if (-not $changed -and -not $ReadPlaces) { return }
    Update-KeptRows
}

# The rows the last lists call for: every kept session, and one row for a place
# that cannot be asked, so its sessions are never silently missing. A session
# that a window here shows is left to that window's row, which the card works
# out on each tick (Update-Card). For WSL here, an incoming row stands for a
# session that has a Claude session id.
function Update-KeptRows {
    $byKey = @{}
    $bySession = @{}
    foreach ($place in @($script:keptPlaces)) {
        $poll = $script:keptSources[$place]
        if ($null -eq $poll) { continue }
        if ($poll.Problem) {
            $byKey[(Get-KeptKey -Id "$place|?")] = @{ Place = $place; Problem = $poll.Problem }
        }
        foreach ($s in $poll.Sessions) {
            if ($s.SessionId) { $bySession[$s.SessionId] = $s }
            if ((Test-WslPlace -Place $place) -and $s.SessionId) { continue }
            $byKey[(Get-KeptKey -Id "$place|$($s.Name)")] = $s
        }
    }
    $script:keptByKey = $byKey
    $script:keptBySessionId = $bySession
}

# A window here showing a kept session has just closed. Until the next list
# says otherwise, the session is taken to be running with no window, so its
# faded row takes the window row's place in the same moment instead of a
# second later. A session being ended is left to vanish.
function Set-KeptWindowClosed {
    param([string]$HostName, [string]$Name)
    foreach ($place in @($script:keptSources.Keys)) {
        if ((Get-KeptPlaceName -Place $place) -ne $HostName) { continue }
        $ending = $script:keptEnding["$place|$Name"]
        foreach ($s in $script:keptSources[$place].Sessions) {
            if ($s.Name -ne $Name) { continue }
            if ($null -ne $ending -and ((Get-Date) - $ending).TotalSeconds -lt 20) {
                $script:keptSources[$place].Sessions = @($script:keptSources[$place].Sessions | Where-Object { $_.Name -ne $Name })
            } else {
                $s.Window = ''
            }
        }
    }
    Update-KeptRows
}

# One row per session, whichever row stands for it: when a kept session's
# window opens, the window's new row takes the faded row's place, and when the
# window closes the faded row takes the window's. The newcomer inherits the
# slot, its place in a dragged order, and its timers, so the row seems to stay
# put and only change its look. $Id is "host|session name".
$script:slotRec = @{}
function Use-SessionSlot {
    param($Rec, [string]$Id)
    $old = $script:slotRec[$Id]
    if ($null -ne $old -and -not [object]::ReferenceEquals($old, $Rec)) {
        $Rec.Seq = $old.Seq
        $Rec.Since = $old.Since
        $Rec.WorkSince = $old.WorkSince
        $Rec.FinishedAt = $old.FinishedAt
        $Rec.Top = $old.Top
        if ($old.Top -ge 0) {
            # A finished slide keeps holding the row where it ended, over any
            # SetTop, and the layout then sees the row already in its slot. A
            # window row that slid in before its session resolved stayed drawn
            # there, over the next group, with its real slot left empty.
            $Rec.Element.BeginAnimation([System.Windows.Controls.Canvas]::TopProperty, $null)
            [System.Windows.Controls.Canvas]::SetTop($Rec.Element, $old.Top)
        }
        $oldKey = [string][int64]$old.Handle
        $at = $script:userOrder.IndexOf($oldKey)
        if ($at -ge 0) {
            $script:userOrder[$at] = [string][int64]$Rec.Handle
            Update-OrderIndex
        }
    }
    $script:slotRec[$Id] = $Rec
}

# Whether a window here showing this label is one of that host's kept sessions,
# for a window whose ssh command line does not say so: one that started a shell
# and attached to tmux from there. tmux passes the session's title on to the
# window, so the two titles are the same.
function Test-KeptTitle {
    param([string]$HostName, [string]$Label)
    foreach ($place in @($script:keptSources.Keys)) {
        if ((Get-KeptPlaceName -Place $place) -ne $HostName) { continue }
        foreach ($s in $script:keptSources[$place].Sessions) {
            if ($s.Window -eq 'remote' -and $s.Title -eq $Label) { return $true }
        }
    }
    return $false
}

# The helper agents running in the kept session a window here shows, as its
# place last listed them: the session its title names, or else the one session
# there whose title is the window's. 0 when neither is found.
function Get-OutgoingHelpers {
    param([string]$HostName, [string]$TmuxName, [string]$Label)
    foreach ($place in @($script:keptSources.Keys)) {
        if ((Get-KeptPlaceName -Place $place) -ne $HostName) { continue }
        $sessions = @($script:keptSources[$place].Sessions)
        if ($TmuxName) {
            $found = @($sessions | Where-Object { $_.Name -eq $TmuxName })
        } else {
            $found = @($sessions | Where-Object { $_.Window -eq 'remote' -and $_.Title -eq $Label })
        }
        if ($found.Count -eq 1) { return [int]$found[0].Helpers }
    }
    return 0
}

# The kept session a row's click should open, or $null: one of the rows above,
# or an incoming row whose tmux session here has no window. A row for a place
# that could not be asked counts too: its click retries, or lets the sign-in
# Tailscale wants happen in a terminal.
function Get-RowKept {
    param($Element)
    $key = [string][int64]$Element.Tag
    if ($script:keptByKey.ContainsKey($key)) { return $script:keptByKey[$key] }
    $info = $script:sessionByHwnd[$key]
    if ($null -ne $info -and $info.Remote -eq 'In') {
        $kept = $script:keptBySessionId[$info.SessionId]
        if ($null -ne $kept -and $kept.Window -eq '') { return $kept }
    }
    return $null
}

# The kept session a row's Kill and Disconnect act on, or $null: a row with no
# window, an incoming row that runs in tmux here, or a window here whose title
# is that of exactly one of its host's kept sessions.
function Get-RowEndable {
    param($Element)
    $key = [string][int64]$Element.Tag
    $kept = $script:keptByKey[$key]
    if ($null -ne $kept) {
        if ($kept.Problem) { return $null }
        return $kept
    }
    $info = $script:sessionByHwnd[$key]
    if ($null -ne $info -and $info.Remote -eq 'In') { return $script:keptBySessionId[$info.SessionId] }
    if ($script:outgoingByHwnd.ContainsKey($key) -and $rows.ContainsKey($key)) {
        # The window's title names its tmux session; one of the places this
        # card asks is that host.
        $rec = $rows[$key]
        $hostName = $script:outgoingByHwnd[$key]
        foreach ($place in @($script:keptSources.Keys)) {
            if ((Get-KeptPlaceName -Place $place) -ne $hostName) { continue }
            if ($rec.TmuxName) { return @{ Place = $place; Name = $rec.TmuxName } }
            $found = @($script:keptSources[$place].Sessions | Where-Object { $_.Window -eq 'remote' -and $_.Title -eq $rec.Label })
            if ($found.Count -eq 1) { return $found[0] }
        }
    }
    return $null
}

# Fades a row, or the Reconnect veil over it, to an opacity instead of jumping.
function Set-Fade {
    param($Element, [double]$To)
    if ([Math]::Abs($Element.Opacity - $To) -lt 0.01 -and -not $Element.HasAnimatedProperties) { return }
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.To = $To
    $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($keptFadeMs))
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
}

# Ends a kept session where it runs, after asking: Claude stops there and any
# work it is doing stops with it. office-sessions --end asks Claude to quit the
# way Ctrl+C does at its prompt, and closes the session outright only if Claude
# has not quit after ten seconds.
function Stop-KeptSession {
    param($Kept)
    $where = Get-KeptPlaceLong -Place $Kept.Place
    if ($script:settings.AskBeforeKill) {
        $answer = [System.Windows.MessageBox]::Show($window,
            "Kill the session $($Kept.Name) on $where?`n`nClaude stops there, and anything it is doing stops with it. Any window showing it closes.",
            'Kill session', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }
    $script:keptEnding["$($Kept.Place)|$($Kept.Name)"] = Get-Date
    Invoke-AtKeptPlace -Place $Kept.Place -Command ('office-sessions --end ' + $Kept.Name)
    $poll = $script:keptSources[$Kept.Place]
    if ($null -ne $poll) { $poll.NextAt = (Get-Date).AddSeconds(2) }
}

function Get-KeptKey {
    param([string]$Id)
    if (-not $script:keptKeyOf.ContainsKey($Id)) {
        $script:keptKeyOf[$Id] = [string]$script:nextKeptKey
        $script:nextKeptKey--
    }
    return $script:keptKeyOf[$Id]
}

# Opens a terminal attached to a kept session, or for a place that wants a
# sign-in, one that runs the session list there so the sign-in can happen.
function Open-KeptSession {
    param($Kept)
    if ($Kept.Problem) {
        $remote = @('office-sessions')
    } else {
        # -u: the login at the far end may name no locale, and without it tmux
        # draws every symbol as "_".
        $remote = @('tmux', '-u', 'attach', '-t', ('=' + $Kept.Name))
    }
    if (Test-WslPlace -Place $Kept.Place) {
        $command = @('wsl.exe') + @((Get-WslPrefix -Place $Kept.Place).Trim() -split ' ') + $remote
    } else {
        $command = @('ssh.exe', '-t', $Kept.Place) + $remote
    }
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) {
        Start-Process -FilePath $wt.Source -ArgumentList $command
    } else {
        Start-Process -FilePath $command[0] -ArgumentList @($command | Select-Object -Skip 1)
    }
    # The row stays where it is, saying it is connecting, until the window's
    # own row takes its place. The place is asked again soon.
    if (-not $Kept.Problem) { $script:keptOpening["$($Kept.Place)|$($Kept.Name)"] = Get-Date }
    $poll = $script:keptSources[$Kept.Place]
    if ($null -ne $poll) { $poll.NextAt = (Get-Date).AddSeconds(2) }
}

# ---------------------------------------------------------------------------
# Closed sessions: Claude sessions of this PC whose terminal has closed, or
# whose Claude has ended in it. Each keeps its row, faded, until it is resumed
# or killed, so closing a window never loses a session from the card. A click
# resumes it: a new terminal in its folder runs claude --resume with its id,
# and the new window's row takes the closed row's place, since a resumed
# session keeps its id. Kill takes it off the card. The list outlives the card
# in state\closed.json, one entry per session:
#   SessionId, Cwd, Label, Workspace, Model, Prompt, ClosedAt, Key
# Key is the row's key, a large negative number of its own range, so it can
# collide with neither a window handle, an incoming row's negated pid nor a
# kept session's key.
# ---------------------------------------------------------------------------
#
# The sessions open now are kept too, in state\open.json, so a session that
# ends while the card is not running, the PC shutting down above all, becomes
# a closed row when the card next starts.
$closedFile = Join-Path $stateDir 'closed.json'
$openFile   = Join-Path $stateDir 'open.json'
$script:closedSessions = @{}   # session id -> entry
$script:closedByKey = @{}      # row key -> entry
$script:nextClosedKey = [int64]-2000000000000
$script:forgetSessions = @{}   # session id -> $true for a session killed here, which leaves no closed row, until its Claude has stopped
$script:keepSessions = @{}     # session id -> $true for a session its row's Close is closing, kept whatever KeepClosedWindows says
$script:localSeen = @{}        # session id -> how its row last looked: Cwd, Label, Workspace, Model, Prompt
$script:openSaved = ''         # open.json as last written
$script:openAtStart = $null    # the sessions open when the card last ran, until the first sweep

function Save-ClosedSessions {
    $list = @($script:closedSessions.Values | ForEach-Object {
        [pscustomobject]@{ SessionId = $_.SessionId; Cwd = $_.Cwd; Label = $_.Label; Workspace = $_.Workspace
                           Model = $_.Model; Prompt = $_.Prompt; ClosedAt = $_.ClosedAt; Key = $_.Key } })
    try {
        Set-Content -Path $closedFile -Value (ConvertTo-Json -InputObject $list -Depth 3) -Encoding UTF8
    } catch { Write-ErrorLog -Where 'closed' -Problem $_ }
}

function Save-OpenSessions {
    $list = @($script:localSeen.Keys | Sort-Object | ForEach-Object {
        $s = $script:localSeen[$_]
        [pscustomobject]@{ SessionId = $_; Cwd = $s.Cwd; Label = $s.Label; Workspace = $s.Workspace; Model = $s.Model; Prompt = $s.Prompt } })
    $text = ConvertTo-Json -InputObject $list -Depth 3
    if ($text -eq $script:openSaved) { return }
    try {
        Set-Content -Path $openFile -Value $text -Encoding UTF8
        $script:openSaved = $text
    } catch { Write-ErrorLog -Where 'closed' -Problem $_ }
}

# Both files hold a JSON list. Windows PowerShell hands a parsed list down a
# pipeline as one object, so each is held in a variable before it is walked.
function Read-ClosedSessions {
    if (Test-Path $openFile) {
        try {
            $open = Get-Content $openFile -Raw | ConvertFrom-Json
            $script:openAtStart = @(foreach ($e in @($open)) {
                if (-not $e.SessionId) { continue }
                @{ SessionId = [string]$e.SessionId; Cwd = [string]$e.Cwd; Label = [string]$e.Label
                   Workspace = [string]$e.Workspace; Model = [string]$e.Model; Prompt = [int]$e.Prompt } })
        } catch { Write-ErrorLog -Where 'closed' -Problem $_ }
    }
    if (-not (Test-Path $closedFile)) { return }
    try {
        $closed = Get-Content $closedFile -Raw | ConvertFrom-Json
        foreach ($e in @($closed)) {
            if (-not $e.SessionId -or -not $e.Key) { continue }
            $entry = @{ SessionId = [string]$e.SessionId; Cwd = [string]$e.Cwd; Label = [string]$e.Label
                        Workspace = [string]$e.Workspace; Model = [string]$e.Model; Prompt = [int]$e.Prompt
                        ClosedAt = [string]$e.ClosedAt; Key = [string]$e.Key; Resuming = $null }
            $script:closedSessions[$entry.SessionId] = $entry
            $script:closedByKey[$entry.Key] = $entry
            $script:nextClosedKey = [Math]::Min($script:nextClosedKey, [int64]$entry.Key - 1)
        }
    } catch { Write-ErrorLog -Where 'closed' -Problem $_ }
}

# A session of this PC has lost its window or its Claude: it becomes a closed
# row, unless it was killed here or is closed already. Its row, or else how its
# row last looked, gives the label and the rest. A killed session comes here
# twice, once for its window and once for its Claude, so its mark stays until
# the sweep finds its Claude stopped; taken on the first, the second made it a
# closed row after all.
function Add-ClosedSession {
    param($Info, $Rec)
    $sid = [string]$Info.SessionId
    if (-not $sid) { return }
    if ($script:forgetSessions.ContainsKey($sid)) { return }
    if ($script:closedSessions.ContainsKey($sid)) { return }
    $look = $script:localSeen[$sid]
    if ($null -ne $Rec -and $Rec.Label) {
        $look = @{ Label = $Rec.Label; Workspace = $Rec.Workspace; Model = $Rec.Model; Prompt = $Rec.Prompt }
    }
    $script:localSeen.Remove($sid)
    if ($null -eq $look) { $look = @{ Label = (Split-Path -Leaf ([string]$Info.Cwd)); Workspace = $Info.Workspace; Model = ''; Prompt = 0 } }
    $entry = @{ SessionId = $sid; Cwd = [string]$Info.Cwd; Label = [string]$look.Label; Workspace = [string]$look.Workspace
                Model = [string]$look.Model; Prompt = [int]$look.Prompt; ClosedAt = (Get-Date).ToString('o')
                Key = [string]$script:nextClosedKey; Resuming = $null }
    $script:nextClosedKey--
    $script:closedSessions[$sid] = $entry
    $script:closedByKey[$entry.Key] = $entry
    Save-ClosedSessions
}

function Remove-ClosedSession {
    param([string]$SessionId)
    $entry = $script:closedSessions[$SessionId]
    if ($null -eq $entry) { return }
    $script:closedSessions.Remove($SessionId)
    $script:closedByKey.Remove($entry.Key)
    Save-ClosedSessions
}

# The closed session behind a row, or $null.
function Get-RowClosed {
    param($Element)
    return $script:closedByKey[[string][int64]$Element.Tag]
}

# Opens a closed session again. Its row stays, saying so, until the new
# window's row takes its place.
function Resume-ClosedSession {
    param($Entry)
    $Entry.Resuming = Get-Date
    Start-ClaudeSession -Folder $Entry.Cwd -Resume $Entry.SessionId
}

# The session of this PC a row's window shows, as its session file has it, or
# $null for any other row.
function Get-RowLocal {
    param($Element)
    $key = [string][int64]$Element.Tag
    if ([int64]$Element.Tag -le 0) { return $null }
    $info = $script:sessionByHwnd[$key]
    if ($null -eq $info -or $info.Remote -eq 'In' -or -not $info.SessionId) { return $null }
    return $info
}

# Close: the session's window closes, which ends its Claude, and its row turns
# into a closed row to resume later, even with KeepClosedWindows off.
function Close-LocalSession {
    param($Element)
    $info = Get-RowLocal -Element $Element
    if ($null -ne $info) { $script:keepSessions[[string]$info.SessionId] = $true }
    [TlNative]::Close([IntPtr]$Element.Tag) | Out-Null
}

# Kill, after asking: the window closes and the session leaves the card. A
# closed row is only taken off; nothing runs there to stop.
function Stop-LocalSession {
    param($Element)
    $closed = Get-RowClosed -Element $Element
    if ($null -ne $closed) {
        Remove-ClosedSession -SessionId $closed.SessionId
        return
    }
    $info = Get-RowLocal -Element $Element
    if ($null -eq $info) { return }
    if ($script:settings.AskBeforeKill) {
        $answer = [System.Windows.MessageBox]::Show($window,
            "Kill this session?`n`nIts window closes, Claude stops, and anything it is doing stops with it. It leaves the card; Claude's own /resume can still find it.",
            'Kill session', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }
    $script:forgetSessions[[string]$info.SessionId] = $true
    [TlNative]::Close([IntPtr]$Element.Tag) | Out-Null
}

Read-ClosedSessions

# Which session is behind which window, resolved exactly rather than guessed.
#
# The chain is: session file gives a pid and a cwd -> that claude.exe's parent
# is its shell -> the shell owns a hidden PseudoConsoleWindow -> that window's
# parent is the terminal window on screen. Every step is an identity, so there
# is no matching on titles and no time correlation anywhere in it.
#
# Runs on the slow timer because of the one process query it needs.
function Sync-SessionMap {
    param($ShellToWindow)

    $shellToWindow = $ShellToWindow
    $table = [TlNative]::ProcessTable()
    $claudeParents = @{}
    foreach ($id in $table.Keys) {
        if ($table[$id].Name -ieq 'claude.exe') { $claudeParents[$id] = $table[$id].Parent }
    }

    $map = @{}
    $live = 0
    $pending = New-Object System.Collections.ArrayList
    $dir = Join-Path $env:USERPROFILE '.claude\sessions'
    if (Test-Path $dir) {
        foreach ($f in (Get-ChildItem $dir -Filter *.json -ErrorAction SilentlyContinue)) {
            try {
                # ConvertFrom-Json costs about ten milliseconds a file in
                # PowerShell 5.1, which is most of the sweep. Nothing in a
                # session file that this cares about changes without the file
                # being rewritten, so parse only what actually moved.
                $cached = $script:sessionFileCache[$f.FullName]
                if ($null -eq $cached -or $cached.Mtime -ne $f.LastWriteTimeUtc.Ticks) {
                    $s = Get-Content $f.FullName -Raw | ConvertFrom-Json
                    $cached = @{
                        Mtime     = $f.LastWriteTimeUtc.Ticks
                        Pid       = [int]$s.pid
                        Kind      = [string]$s.kind
                        SessionId = [string]$s.sessionId
                        Cwd       = [string]$s.cwd
                        Workspace = Split-Path -Leaf ([string]$s.cwd)
                        StartedAt = [double]$s.startedAt
                        # busy or idle, and when that last changed. Claude
                        # writes this itself, so it is the one record of when
                        # a session finished that outlives a widget restart.
                        Status          = [string]$s.status
                        StatusUpdatedAt = [double]$s.statusUpdatedAt
                    }
                    $script:sessionFileCache[$f.FullName] = $cached
                }
                if ($cached.Kind -ne 'interactive') { continue }

                # A pid that is gone means a stale file. The file's age says
                # nothing, since these are written on state change and never
                # heartbeated.
                if (-not $claudeParents.ContainsKey($cached.Pid)) { continue }
                $live++

                $shell = $claudeParents[$cached.Pid]
                if (-not $shellToWindow.ContainsKey($shell)) {
                    # No window of its own because it was started from another
                    # machine: an incoming remote row, keyed by its negated pid
                    # so the key can never collide with a window handle's.
                    $via = Get-IncomingVia -Table $table -ProcessId $cached.Pid
                    if ($via) {
                        $cached.Remote = 'In'
                        $cached.Via = $via
                        $map[[string](-[int64]$cached.Pid)] = $cached
                        continue
                    }
                    # Windows Terminal has two hosting modes. Usually the shell
                    # itself owns the hidden console window, which is the exact
                    # join. Sometimes a separate OpenConsole.exe owns it instead,
                    # and then nothing links that window back to the shell.
                    # Park the session and pair it up below.
                    [void]$pending.Add(@{ Shell = $shell; Info = $cached })
                    continue
                }
                $hwnd = $shellToWindow[$shell]
                $map[[string][int64]$hwnd] = $cached
            } catch { }
        }
    }
    # Sessions whose window is hosted by an OpenConsole rather than by their own
    # shell. Nothing links the two by identity, so they are paired by start time:
    # a console host is created in the same instant as the shell it serves, which
    # was an exact same-second match when this was measured.
    #
    # Deliberately conservative. A session is only paired to a window if that
    # window is its nearest in time AND within five seconds. Anything ambiguous
    # is left unresolved, because a row labelled with the wrong workspace is
    # worse than a row labelled with none.
    if ($pending.Count -gt 0) {
        $unclaimed = New-Object System.Collections.ArrayList
        foreach ($hostPid in $shellToWindow.Keys) {
            $hwnd = $shellToWindow[$hostPid]
            if ($map.ContainsKey([string][int64]$hwnd)) { continue }
            $startedAt = $null
            try { $startedAt = (Get-Process -Id $hostPid -ErrorAction Stop).StartTime } catch { }
            if ($null -ne $startedAt) {
                [void]$unclaimed.Add(@{ Hwnd = $hwnd; Started = $startedAt; Taken = $false })
            }
        }

        foreach ($item in $pending) {
            $shellStart = $null
            try { $shellStart = (Get-Process -Id $item.Shell -ErrorAction Stop).StartTime } catch { }
            if ($null -eq $shellStart) { continue }

            $best = $null
            $bestGap = [double]::MaxValue
            foreach ($candidate in $unclaimed) {
                if ($candidate.Taken) { continue }
                $gap = [Math]::Abs(($candidate.Started - $shellStart).TotalSeconds)
                if ($gap -lt $bestGap) { $bestGap = $gap; $best = $candidate }
            }
            if ($null -ne $best -and $bestGap -le 5) {
                $best.Taken = $true
                $map[[string][int64]$best.Hwnd] = $item.Info
            }
        }
    }

    # A session of this PC whose Claude has ended since the last sweep, with
    # its window still open or not, becomes a closed row. A window closing is
    # caught sooner, on the poll that finds it gone (Update-Card).
    if (-not $Probe) {
        foreach ($key in @($script:sessionByHwnd.Keys)) {
            $old = $script:sessionByHwnd[$key]
            if ($old.Remote -eq 'In' -or $claudeParents.ContainsKey($old.Pid)) { continue }
            Add-ClosedSession -Info $old -Rec $rows[$key]
        }

        # Every session whose Claude runs here now, a window found for it or not.
        $liveIds = @{}
        foreach ($c in $script:sessionFileCache.Values) {
            if ($c.Kind -eq 'interactive' -and $claudeParents.ContainsKey($c.Pid)) { $liveIds[$c.SessionId] = $true }
        }
        # The first sweep turns the sessions open when the card last ran, and
        # gone since, into closed rows.
        if ($null -ne $script:openAtStart) {
            foreach ($e in $script:openAtStart) {
                if ($liveIds.ContainsKey($e.SessionId)) { continue }
                $script:localSeen[$e.SessionId] = $e
                Add-ClosedSession -Info @{ SessionId = $e.SessionId; Cwd = $e.Cwd; Workspace = $e.Workspace } -Rec $null
            }
            $script:openAtStart = $null
        }
        foreach ($sid in @($script:localSeen.Keys)) {
            if (-not $liveIds.ContainsKey($sid)) { $script:localSeen.Remove($sid) }
        }
        # A killed session's Claude has stopped and both its endings are seen:
        # the one above, and its window's, which came first or finds no session
        # behind the window from here on.
        foreach ($sid in @($script:forgetSessions.Keys)) {
            if (-not $liveIds.ContainsKey($sid)) { $script:forgetSessions.Remove($sid) }
        }
        Save-OpenSessions
    }

    $script:sessionByHwnd = $map
    # A window to another machine opening or closing changes which of its
    # sessions have a window, so that machine is asked again straight away.
    $before = $script:outgoingByHwnd
    $script:outgoingByHwnd = Get-OutgoingWindows -Table $table -ShellToWindow $shellToWindow
    foreach ($key in @($script:outgoingByHwnd.Keys)) {
        if (-not $before.ContainsKey($key)) { Request-KeptPoll -HostName $script:outgoingByHwnd[$key] }
    }
    foreach ($key in @($before.Keys)) {
        if (-not $script:outgoingByHwnd.ContainsKey($key)) {
            Request-KeptPoll -HostName $before[$key]
            # Its ssh ended a moment before its window closes, so this is where
            # the session is first known to have lost its window here.
            if ($rows.ContainsKey($key) -and $rows[$key].TmuxName) {
                Set-KeptWindowClosed -HostName $before[$key] -Name $rows[$key].TmuxName
            }
        }
    }
    # Cached rather than recounted on the fast timer: this used to run a
    # Get-Process per session every 400 ms for a number that changes only when
    # a session opens or closes.
    $script:liveSessionCount = $live
}

# The repository a path lies in, as its root folder, or '' for none. A
# repository is a folder holding .git, or .plastic for a Plastic workspace,
# which is what the Unity projects are; the nearest one wins, so a git repo
# nested in another counts as itself. A git worktree counts as the repository
# it was made from. Folders are looked up once and remembered, because the same
# few come up in every transcript.
$script:repoRootCache = @{}

function Get-RepoRoot {
    param([string]$Path)
    try {
        $dir = ($Path -replace '/', '\').Trim().TrimEnd('\')
        if ($dir -notmatch '^[A-Za-z]:\\') { return '' }
        # The path may name a file, a pattern or a folder made later, so start
        # from the deepest part of it that exists.
        while ($dir.Length -gt 3 -and -not [System.IO.Directory]::Exists($dir)) {
            $dir = [System.IO.Path]::GetDirectoryName($dir)
        }
        $visited = New-Object System.Collections.ArrayList
        $root = ''
        while ($dir -and $dir.Length -gt 3) {
            if ($script:repoRootCache.ContainsKey($dir)) { $root = $script:repoRootCache[$dir]; break }
            [void]$visited.Add($dir)
            $git = Join-Path $dir '.git'
            if ([System.IO.Directory]::Exists((Join-Path $dir '.plastic')) -or [System.IO.Directory]::Exists($git)) {
                $root = $dir
            } elseif ([System.IO.File]::Exists($git)) {
                $root = $dir
                $made = [regex]::Match([System.IO.File]::ReadAllText($git), 'gitdir:\s*(.+?)[\\/]\.git[\\/]worktrees[\\/]')
                if ($made.Success) { $root = $made.Groups[1].Value.Trim() -replace '/', '\' }
            }
            if ($root) {
                # The name as it is on disk, not as a command happened to type it:
                # Git Bash writes /d/draxon/..., and the heading should not change
                # case with whoever typed it.
                $parent = [System.IO.Path]::GetDirectoryName($root)
                $real = @([System.IO.Directory]::GetDirectories($parent, (Split-Path -Leaf $root)))
                if ($real.Count -eq 1) { $root = $real[0] }
                break
            }
            $dir = [System.IO.Path]::GetDirectoryName($dir)
        }
        foreach ($v in $visited) { $script:repoRootCache[$v] = $root }
        return $root
    } catch { return '' }
}

# One JSON string value, as the transcript holds it, back to plain text.
# Regex.Unescape knows every escape JSON uses, and does it in .NET: the same
# thing done with a PowerShell callback per escape cost 40 ms per transcript.
function ConvertFrom-JsonText {
    param([string]$Raw)
    if ($Raw.IndexOf('\') -lt 0) { return $Raw }
    try { return [regex]::Unescape($Raw) } catch { return $Raw }
}

# The repository a session is really working in, which is often not the folder
# its terminal was opened in: every terminal may start in one project while
# its agent works in another. Read from transcripts, so it needs no hook and
# nothing from the agent, and works on sessions that were already open: the
# session's own, and those of the helper agents it starts, which Claude keeps
# in a subagents folder beside it. A session that hands its work to helpers
# writes little but messages itself; its helpers are the ones touching files.
# In each transcript these are votes:
#   - the files its tools read and write (file_path, notebook_path, path),
#   - the folders named in its shell commands, as D:\..., D:/... or /d/...,
#   - the shell's own folder (cwd) whenever it has moved off the launch folder.
# Each one that lies in a repository counts. Paths outside any repository, such
# as temp files, the Unity editor or ~/.claude, do not.
#
# The votes are a running list per session, newest last, fed every sweep with
# the lines each file has gained since. Judging only the end of the session's
# own transcript went wrong: a session busy talking to its helpers had no votes
# there at all and kept whatever an early look at the launch folder's rules
# had said. When a session is first seen, each of its files changed in the
# last two hours is read from the end back until it gives enough votes, oldest
# file first, so the list starts out as it would have grown.
#
# Of the last 48 votes the repository with the most wins; on a tie the current
# one stays, so a row does not flap between two groups, and otherwise the latest
# of the leaders wins. '' means no votes yet, which leaves the row on its launch
# folder.
$workVotes = 48
$workLookbackHours = 2
$script:workState = @{}

# The repositories one stretch of transcript votes for, in order.
function Get-WorkVotes {
    param([string]$Text, [string]$Launch)
    $votes = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Text, '"(file_path|notebook_path|path|cwd|command)":"((?:[^"\\]|\\.)*)"')) {
        $kind = $m.Groups[1].Value
        $value = ConvertFrom-JsonText -Raw $m.Groups[2].Value
        $paths = @()
        if ($kind -eq 'command') {
            foreach ($p in [regex]::Matches($value, '(?i)(?<![\w])[a-z]:[\\/][^\s"''`<>|;&*?]*')) { $paths += $p.Value }
            foreach ($p in [regex]::Matches($value, '(?i)(?<![\w/.~-])/([a-z])/[^\s"''`<>|;&*?]*')) {
                $paths += $p.Groups[1].Value + ':' + $p.Value.Substring(2)
            }
        } elseif ($kind -eq 'cwd') {
            if (($value -replace '/', '\').TrimEnd('\') -eq $Launch) { continue }
            $paths = @($value)
        } else {
            $paths = @($value)
        }
        foreach ($p in $paths) {
            $root = Get-RepoRoot -Path $p
            if ($root) { [void]$votes.Add($root) }
        }
    }
    return ,$votes
}

# A transcript from byte Start to its last complete line, as @{ Text; Next },
# Next being the offset just past that line. A record being written right now
# is left for the next sweep. FileShare must allow writing: its session is
# appending to it.
function Read-TranscriptLines {
    param([string]$Path, [long]$Start)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $length = $stream.Length
        if ($Start -ge $length) { return @{ Text = ''; Next = $Start } }
        [void]$stream.Seek($Start, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] ($length - $Start)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return @{ Text = ''; Next = $Start } }
        $end = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
        if ($end -lt 0) { return @{ Text = ''; Next = $Start } }
        return @{ Text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $end + 1); Next = $Start + $end + 1 }
    } finally { $stream.Dispose() }
}

# Brings one session's votes up to date and returns the repository it is
# working in, as a root folder, or ''.
function Update-WorkRepo {
    param([string]$SessionId, [string]$MainPath, [string]$LaunchCwd)
    $launch = ($LaunchCwd -replace '/', '\').TrimEnd('\')
    $state = $script:workState[$SessionId]
    $first = ($null -eq $state)
    if ($first) {
        $state = @{ Votes = New-Object System.Collections.ArrayList; Offsets = @{}; Root = '' }
        $script:workState[$SessionId] = $state
    }

    $files = New-Object System.Collections.ArrayList
    $main = New-Object System.IO.FileInfo $MainPath
    if ($main.Exists) { [void]$files.Add($main) }
    $helpers = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($MainPath),
                                         [System.IO.Path]::GetFileNameWithoutExtension($MainPath), 'subagents')
    if ([System.IO.Directory]::Exists($helpers)) {
        foreach ($f in (New-Object System.IO.DirectoryInfo $helpers).GetFiles('*.jsonl')) { [void]$files.Add($f) }
    }
    $since = [DateTime]::UtcNow.AddHours(-$workLookbackHours)

    if ($first) {
        # First sight of the session: what it did lately, newest file first,
        # each read from the end back in growing steps, until there are enough
        # votes. Older votes go in front, so the list reads as it would have
        # grown. Everything is marked read up to its end either way.
        foreach ($f in @($files | Sort-Object LastWriteTimeUtc -Descending)) {
            $state.Offsets[$f.FullName] = $f.Length
            $need = $workVotes - $state.Votes.Count
            if ($need -le 0 -or $f.LastWriteTimeUtc -lt $since) { continue }
            $take = [Math]::Min([long]$transcriptTail, $f.Length)
            while ($true) {
                $chunk = Read-TranscriptLines -Path $f.FullName -Start ($f.Length - $take)
                $votes = Get-WorkVotes -Text $chunk.Text -Launch $launch
                if ($votes.Count -ge $need -or $take -ge $f.Length -or $take -ge $transcriptTailMax) { break }
                $take = [Math]::Min([Math]::Min($take * 4, [long]$transcriptTailMax), $f.Length)
            }
            if ($votes.Count -gt 0) { $state.Votes.InsertRange(0, $votes) }
            $state.Offsets[$f.FullName] = $chunk.Next
        }
        $files = @()
    }

    foreach ($f in $files) {
        $offset = $state.Offsets[$f.FullName]
        # A helper started since is read from its beginning.
        if ($null -eq $offset) { $offset = [long]0 }
        if ($f.Length -lt $offset) { $offset = [long]0 }
        if ($f.Length -eq $offset) { continue }
        $offset = [Math]::Max($offset, $f.Length - $transcriptTailMax)
        $chunk = Read-TranscriptLines -Path $f.FullName -Start $offset
        $votes = Get-WorkVotes -Text $chunk.Text -Launch $launch
        if ($votes.Count -gt 0) { $state.Votes.AddRange($votes) }
        $state.Offsets[$f.FullName] = $chunk.Next
    }

    if ($state.Votes.Count -gt $workVotes) { $state.Votes.RemoveRange(0, $state.Votes.Count - $workVotes) }
    if ($state.Votes.Count -eq 0) { return $state.Root }
    $counts = @{}
    foreach ($r in $state.Votes) { $counts[$r] = 1 + [int]$counts[$r] }
    $top = ($counts.Values | Measure-Object -Maximum).Maximum
    if (-not ($state.Root -and $counts[$state.Root] -eq $top)) {
        for ($i = $state.Votes.Count - 1; $i -ge 0; $i--) {
            if ($counts[$state.Votes[$i]] -eq $top) { $state.Root = $state.Votes[$i]; break }
        }
    }
    return $state.Root
}

# How many helper agents a session has running now, for the ring on its row.
# Claude keeps two files per helper in the session's subagents folder: its
# transcript, and a small meta file that gains "finished":true when the helper
# ends of its own accord. A helper that is stopped never gets that flag; its
# transcript ends instead on Claude's "[Request interrupted by user" note, as
# its last conversation record. Sending a finished or stopped helper a message
# starts it again: its meta file is written afresh without the flag, and its
# transcript gains records after the note.
#
# Two guards cover a helper that leaves neither behind. One whose meta file is
# older than the session's start belonged to an earlier run of a resumed
# session. One whose transcript has not moved for half an hour has died
# without a word, or comes from a Claude too old to write the flag.
$helperQuietMin = 30
$helperTail = 65536   # bytes read from the end of a helper's transcript to find its last record
$script:helperState = @{}

function Update-HelperCount {
    param([string]$SessionId, [string]$MainPath, [double]$StartedAt)
    $folder = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($MainPath),
                                        [System.IO.Path]::GetFileNameWithoutExtension($MainPath), 'subagents')
    if (-not [System.IO.Directory]::Exists($folder)) { return 0 }
    $state = $script:helperState[$SessionId]
    if ($null -eq $state) {
        $state = @{ Metas = @{}; Logs = @{} }
        $script:helperState[$SessionId] = $state
    }
    $quiet = [DateTime]::UtcNow.AddMinutes(-$helperQuietMin)
    $started = [DateTime]::MinValue
    if ($StartedAt -gt 0) { $started = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$StartedAt).UtcDateTime }

    $count = 0
    foreach ($meta in (New-Object System.IO.DirectoryInfo $folder).GetFiles('*.meta.json')) {
        $seen = $state.Metas[$meta.FullName]
        if ($null -eq $seen -or $seen.Ticks -ne $meta.LastWriteTimeUtc.Ticks) {
            # A couple of hundred bytes, read again only when Claude rewrites
            # it. One caught half written is left for the next sweep.
            $text = ''
            try {
                $stream = [System.IO.File]::Open($meta.FullName, [System.IO.FileMode]::Open,
                                                 [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try { $text = (New-Object System.IO.StreamReader $stream).ReadToEnd() } finally { $stream.Dispose() }
            } catch { }
            if (-not $text.TrimEnd().EndsWith('}')) { continue }
            $seen = @{ Ticks = $meta.LastWriteTimeUtc.Ticks; Finished = $text.Contains('"finished":true') }
            $state.Metas[$meta.FullName] = $seen
        }
        if ($seen.Finished -or $meta.LastWriteTimeUtc -lt $started) { continue }

        $log = New-Object System.IO.FileInfo ($meta.FullName -replace '\.meta\.json$', '.jsonl')
        $moved = $(if ($log.Exists) { $log.LastWriteTimeUtc } else { $meta.LastWriteTimeUtc })
        if ($moved -lt $quiet) { continue }
        if ($log.Exists) {
            # Its last conversation record, read again only when the
            # transcript has grown.
            $last = $state.Logs[$log.FullName]
            if ($null -eq $last -or $last.Length -ne $log.Length) {
                $chunk = Read-TranscriptLines -Path $log.FullName -Start ([Math]::Max([long]0, $log.Length - $helperTail))
                $records = [regex]::Matches($chunk.Text, '(?m)^.*"isSidechain":.*$')
                $stopped = ($records.Count -gt 0 -and $records[$records.Count - 1].Value.Contains('[Request interrupted by user'))
                $last = @{ Length = $log.Length; Stopped = $stopped }
                $state.Logs[$log.FullName] = $last
            }
            if ($last.Stopped) { continue }
        }
        $count++
    }
    return $count
}

# When a session that set itself a timer, with Claude's ScheduleWakeup, wakes
# again, or $null when it has none. Read from its own records in its transcript,
# not from the copies of earlier turns Claude also writes there, and only from
# what was added since the last sweep. The last call counts: a stop clears the
# timer, and the delay is held to the minute-to-hour range Claude itself holds
# it to. Background commands need no reading: Claude marks its session file
# "shell" while its turn is over and one still runs.
$wakeTail = 4194304   # bytes read from the end of a transcript the first time it is seen
$wakeGraceSec = 30    # how long past its time a timer still counts, for the session to wake
$script:wakeState = @{}

function Update-WakeAt {
    param([string]$SessionId, [string]$MainPath)
    $file = New-Object System.IO.FileInfo $MainPath
    if (-not $file.Exists) { return $null }
    $state = $script:wakeState[$SessionId]
    if ($null -eq $state) {
        $state = @{ Offset = [Math]::Max([long]0, $file.Length - $wakeTail); WakeAt = $null }
        $script:wakeState[$SessionId] = $state
    }
    if ($file.Length -lt $state.Offset) { $state.Offset = [long]0 }
    if ($file.Length -eq $state.Offset) { return $state.WakeAt }
    $chunk = Read-TranscriptLines -Path $MainPath -Start ([Math]::Max($state.Offset, $file.Length - $wakeTail))
    $state.Offset = $chunk.Next
    $calls = [regex]::Matches($chunk.Text, '(?m)^.*"isSidechain":false.*"type":"tool_use","id":"[^"]*","name":"ScheduleWakeup","input":\{[^}]*\}.*$')
    if ($calls.Count -gt 0) {
        $line = $calls[$calls.Count - 1].Value
        $call = [regex]::Match($line, '"name":"ScheduleWakeup","input":\{[^}]*\}').Value
        $delay = [regex]::Match($call, '"delaySeconds":(\d+)')
        $stamp = [regex]::Match($line, '"timestamp":"([^"]+)"')
        $state.WakeAt = $null
        if ($delay.Success -and $stamp.Success -and -not $call.Contains('"stop":true')) {
            $seconds = [Math]::Min(3600, [Math]::Max(60, [int]$delay.Groups[1].Value))
            $state.WakeAt = ([DateTimeOffset]::Parse($stamp.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)).LocalDateTime.AddSeconds($seconds)
        }
    }
    return $state.WakeAt
}

# Model and context come from the session's own transcript, which is the only
# place either is recorded. These files reach several megabytes over a day, so
# only the tail is read, and only when the file has actually changed. The
# repository the session works in comes from Update-WorkRepo.
function Sync-SessionExtras {
    foreach ($key in @($script:sessionByHwnd.Keys)) {
        $info = $script:sessionByHwnd[$key]

        $path = $script:transcriptPaths[$info.SessionId]
        if (-not $path) {
            $projRoot = Join-Path $env:USERPROFILE '.claude\projects'
            if (-not (Test-Path $projRoot)) { continue }
            $hit = Get-ChildItem $projRoot -Filter ($info.SessionId + '.jsonl') -Recurse -File -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if (-not $hit) { continue }
            $path = $hit.FullName
            $script:transcriptPaths[$info.SessionId] = $path
        }

        $fi = Get-Item $path -ErrorAction SilentlyContinue
        if (-not $fi) { continue }

        $cached = $script:transcriptCache[$path]
        if ($null -eq $cached -or $cached.Mtime -ne $fi.LastWriteTimeUtc.Ticks) {
            if ($null -eq $cached) { $cached = @{ Model = ''; Prompt = 0; Title = '' } }
            $cached.Mtime = $fi.LastWriteTimeUtc.Ticks

            $text = ''
            try {
                # FileShare must allow writing: the session owning this file is
                # appending to it right now.
                $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                                                 [System.IO.FileAccess]::Read,
                                                 [System.IO.FileShare]::ReadWrite)
                try {
                    # Claude writes records far larger than the tail after every
                    # reply (a prompt snapshot measured 148 KB), which pushes the
                    # last usage record out of reach. The figure from before then
                    # stayed on the bar, so a compacted session read 96 % full.
                    # Widen the read until it holds a usage record or a
                    # compaction; the first tail still finds one mid-turn, so the
                    # common case reads no more than before.
                    $take = [Math]::Min([long]$transcriptTail, $stream.Length)
                    while ($true) {
                        [void]$stream.Seek($stream.Length - $take, [System.IO.SeekOrigin]::Begin)
                        $buffer = New-Object byte[] $take
                        [void]$stream.Read($buffer, 0, $take)
                        $text = [System.Text.Encoding]::UTF8.GetString($buffer)
                        if ($text -match '"input_tokens":|"postTokens":') { break }
                        if ($take -ge $stream.Length -or $take -ge $transcriptTailMax) { break }
                        $take = [Math]::Min([Math]::Min($take * 4, [long]$transcriptTailMax), $stream.Length)
                    }
                } finally { $stream.Dispose() }
            } catch { }

            if ($text -ne '') {
                # Regex rather than ConvertFrom-Json: parsing a hundred kilobytes
                # of JSON per session per sweep is far too slow, and only a
                # handful of numbers are wanted out of it.
                #
                # Records with model "<synthetic>" carry no real token counts, so
                # walking back to the last genuine one matters; a session whose
                # tail ends in synthetic records otherwise reads as empty.
                $matchesModel = [regex]::Matches($text, '"model":"([^"]+)"')
                for ($i = $matchesModel.Count - 1; $i -ge 0; $i--) {
                    $candidate = $matchesModel[$i].Groups[1].Value
                    if ($candidate -ne '<synthetic>') { $cached.Model = $candidate; break }
                }

                # The task title Claude keeps for the session, the same text
                # its terminal title carries. Only an incoming remote row needs
                # it, having no terminal title to read; a name the user gave
                # the session wins over the generated one. A tail without
                # either keeps the title from before.
                foreach ($field in @('aiTitle', 'customTitle')) {
                    $hits = [regex]::Matches($text, ('"{0}":"((?:[^"\\]|\\.)*)"' -f $field))
                    if ($hits.Count -gt 0) {
                        try { $cached.Title = [string](ConvertFrom-Json ('"' + $hits[$hits.Count - 1].Groups[1].Value + '"')) } catch { }
                    }
                }

                $prompt = 0
                $lastUsageAt = -1
                foreach ($pattern in @('"input_tokens":(\d+)',
                                       '"cache_creation_input_tokens":(\d+)',
                                       '"cache_read_input_tokens":(\d+)')) {
                    $hits = [regex]::Matches($text, $pattern)
                    if ($hits.Count -gt 0) {
                        $prompt += [int]$hits[$hits.Count - 1].Groups[1].Value
                        $lastUsageAt = [Math]::Max($lastUsageAt, $hits[$hits.Count - 1].Index)
                    }
                }

                # A compaction later than the last usage record means the context
                # was just replaced by its summary, and no reply has reported a
                # size since. The boundary record carries that size itself as
                # postTokens, so the bar drops the moment the compaction lands
                # rather than on the next reply.
                $compactions = [regex]::Matches($text, '"postTokens":(\d+)')
                $lastCompaction = $null
                if ($compactions.Count -gt 0) { $lastCompaction = $compactions[$compactions.Count - 1] }
                if ($null -ne $lastCompaction -and $lastCompaction.Index -gt $lastUsageAt) {
                    $cached.Prompt = [int]$lastCompaction.Groups[1].Value
                } elseif ($prompt -gt 0) {
                    # Keep the previous figure rather than showing zero when the
                    # tail happens to hold no usable record.
                    $cached.Prompt = $prompt
                }
            }

            $script:transcriptCache[$path] = $cached
        }

        $info.Model = $cached.Model
        $info.Prompt = $cached.Prompt
        $info.Title = $cached.Title

        # Every sweep, since the helpers write to files of their own.
        $info.Helpers = 0
        try {
            $info.Helpers = Update-HelperCount -SessionId $info.SessionId -MainPath $path -StartedAt $info.StartedAt
        } catch { Write-ErrorLog -Where 'helpers' -Problem $_ }
        $info.WakeAt = $null
        try {
            $info.WakeAt = Update-WakeAt -SessionId $info.SessionId -MainPath $path
        } catch { Write-ErrorLog -Where 'wakeup' -Problem $_ }

        # Every sweep, not only when the session's own transcript changed: its
        # helpers write to files of their own. Only with GroupByRepo on; off,
        # every row stays on the folder its terminal opened in. Marshal stays on
        # its own folder either way. It coordinates rather than works in a
        # repository, and it writes its report into the card's own folder every
        # round, which would otherwise file it under this repository.
        $info.WorkRepo = ''
        if ($script:settings.GroupByRepo -and -not (Test-MarshalRow -Cwd $info.Cwd -Label '')) {
            try {
                $root = Update-WorkRepo -SessionId $info.SessionId -MainPath $path -LaunchCwd $info.Cwd
                if ($root) { $info.WorkRepo = Split-Path -Leaf $root }
            } catch { Write-ErrorLog -Where 'workspace' -Problem $_ }
        }
    }

    # With the grouping off nothing is counted, and what was counted goes, so
    # switching it back on reads each session's history afresh rather than
    # carrying on from where it stopped and missing everything in between.
    if (-not $script:settings.GroupByRepo) { $script:workState.Clear() }

    # Sessions that have ended take their votes with them.
    $liveIds = @{}
    foreach ($i in $script:sessionByHwnd.Values) { $liveIds[[string]$i.SessionId] = $true }
    foreach ($id in @($script:workState.Keys)) {
        if (-not $liveIds.ContainsKey($id)) { $script:workState.Remove($id) }
    }
    foreach ($id in @($script:helperState.Keys)) {
        if (-not $liveIds.ContainsKey($id)) { $script:helperState.Remove($id) }
    }
}

# ---------------------------------------------------------------------------
# Unity editors
# ---------------------------------------------------------------------------

# Every Unity editor on this machine, one entry per project, for the Unity
# group at the bottom of the card. It exists for headless editors: an editor
# started with -batchmode has no window and no taskbar button, so without this
# the only way to know one is still running, and what it costs, is Task Manager.
#
# The process list is the source of truth. Unity's own pipeline descriptor in
# Library/Pipeline only refreshes its heartbeat when someone calls the editor,
# so it cannot say whether one is alive, and it holds the editor's bearer token,
# which the card has no business reading.
#
# An editor imports through child processes named AssetImportWorkerN, separate
# Unity.exe processes with the same -projectPath. They are added to their
# editor's memory and CPU, because during an import they hold most of both and
# an editor shown without them looks idle while the machine is saturated.
#
# The command line is read once per process and never shown or logged: a
# Unity Hub launch carries a live access token in it.
$script:unityCommandLines = @{}
$script:unityCpuSamples = @{}
$script:unityEditors = @()

# ---------------------------------------------------------------------------
# CPU limits on Unity editors
#
# A headless editor imports, compiles and runs tests on every core for as long
# as its agent works, and a few of them at once left the machine hard to use.
# So each limited editor is put, with its import workers, in a Windows job
# object of its own. The job caps the CPU they use together, as a share of the
# whole machine, and a headless editor's job also holds them at idle priority,
# so whatever the user does runs first. Workers started later join their
# editor's job by themselves.
#
# A headless editor gets $unityCpuLimitDefault unless its row's menu says
# otherwise. An editor with a window gets no limit unless its row asks for one,
# because it is the editor the user is working in. The choice is kept per
# project, so it holds the next time an editor opens the same project.
#
# Memory is not limited, on purpose: a hard limit crashes Unity when it is
# reached, and a soft one pushes the editor out to disk, which slows the
# machine more than the editor does.
#
# A process can never leave a job, so No limit lifts the job's cap rather than
# taking the editor out of it. A headless editor stays at idle priority even
# then: it still gets every core nothing else wants.
# ---------------------------------------------------------------------------
$unityCpuLimitDefault = 25
$unityCpuLimitChoices = @(0, 10, 25, 50, 75)
$script:unityJobs = @{}        # editor process id -> @{ Job; Percent; Idle; Capped }
$script:unityCapFailed = @{}   # process ids whose failure is logged already, so it is logged once

# ---------------------------------------------------------------------------
# Settings, chosen from the card's menu and its rows' right-click menus, kept in
# state/settings.json. Read once at start and written on every change.
#
# ShowUnityEditors is on by default, and the menu switch is there for the days
# the editors only crowd the card. A machine without Unity shows nothing either way.
#
# GroupByRepo groups rows under the repository each agent is really working in,
# read from its transcripts. Off by default, which groups them by the folder the
# terminal was opened in and skips reading transcripts for it at all.
#
# Preset is the name of a file in the presets folder, laid over Classic. One
# that has gone missing falls back to Classic when the card starts.
#
# ShowUsage5h and ShowUsageWeek show the Claude subscription's five-hour and
# weekly limits as bars along the card's bottom. Both on by default.
#
# Sounds maps a terminal window handle to the sound that window's session plays
# when it needs you, '' being Off picked on purpose. Keyed by window like the row
# order, so a sound survives a /clear, a new session in the same window and a
# restart of the card, and it is dropped when the window closes. A window with no
# entry follows DefaultSound, which is Off until one is picked; nothing is copied
# from it, so changing it changes every window that follows it.
#
# CpuLimits maps a Unity project folder, in lower case, to the CPU limit its
# editor's row picked, 0 being No limit picked on purpose. A project with no
# entry follows the default for its kind of editor.
#
# HiddenLaunchRepos lists repo folders the New session menus leave out. Added
# from those menus; taken out again only by editing this file.
#
# ShowOthersSessions shows the kept sessions other people started on a shared
# machine, such as the build PC, with their owner's name in front. On by default.
#
# AskBeforeKill asks before a row's Kill stops a session, here or elsewhere. On
# by default; off, Kill stops it at once.
#
# KeepClosedWindows keeps a session of this PC whose window is closed as a
# closed row to resume. On by default; off, only a row's Close keeps one, and a
# window closed any other way takes its session off the card.
#
# WaitOnOwnWork keeps a session whose turn is over off green while helpers or
# background commands it started still run, or a timer it set has yet to wake
# it: it waits on its own work, not on you. On by default; off, green means
# only that its turn is over.
# ---------------------------------------------------------------------------
$settingsFile = Join-Path $stateDir 'settings.json'
$script:settings = @{ ShowUnityEditors = $true; GroupByRepo = $false; ShowUsage5h = $true; ShowUsageWeek = $true
                      ShowOthersSessions = $true; AskBeforeKill = $true; KeepClosedWindows = $true; WaitOnOwnWork = $true
                      DefaultSound = ''; Preset = 'Classic'; Sounds = @{}; CpuLimits = @{}; HiddenLaunchRepos = @() }

function Read-Settings {
    try {
        $saved = Get-Content $settingsFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($null -ne $saved.ShowUnityEditors) { $script:settings.ShowUnityEditors = [bool]$saved.ShowUnityEditors }
        if ($null -ne $saved.GroupByRepo) { $script:settings.GroupByRepo = [bool]$saved.GroupByRepo }
        if ($null -ne $saved.ShowUsage5h) { $script:settings.ShowUsage5h = [bool]$saved.ShowUsage5h }
        if ($null -ne $saved.ShowUsageWeek) { $script:settings.ShowUsageWeek = [bool]$saved.ShowUsageWeek }
        if ($null -ne $saved.ShowOthersSessions) { $script:settings.ShowOthersSessions = [bool]$saved.ShowOthersSessions }
        if ($null -ne $saved.AskBeforeKill) { $script:settings.AskBeforeKill = [bool]$saved.AskBeforeKill }
        if ($null -ne $saved.KeepClosedWindows) { $script:settings.KeepClosedWindows = [bool]$saved.KeepClosedWindows }
        if ($null -ne $saved.WaitOnOwnWork) { $script:settings.WaitOnOwnWork = [bool]$saved.WaitOnOwnWork }
        if ($null -ne $saved.DefaultSound) { $script:settings.DefaultSound = [string]$saved.DefaultSound }
        if ($saved.Preset) { $script:settings.Preset = [string]$saved.Preset }
        if ($null -ne $saved.HiddenLaunchRepos) { $script:settings.HiddenLaunchRepos = @($saved.HiddenLaunchRepos | ForEach-Object { [string]$_ }) }
        if ($null -ne $saved.Sounds) {
            foreach ($entry in $saved.Sounds.PSObject.Properties) {
                $script:settings.Sounds[[string]$entry.Name] = [string]$entry.Value
            }
        }
        if ($null -ne $saved.CpuLimits) {
            foreach ($entry in $saved.CpuLimits.PSObject.Properties) {
                $script:settings.CpuLimits[[string]$entry.Name] = [int]$entry.Value
            }
        }
    } catch { }
}

function Save-Settings {
    try {
        [pscustomobject]@{
            ShowUnityEditors = $script:settings.ShowUnityEditors
            GroupByRepo      = $script:settings.GroupByRepo
            ShowUsage5h      = $script:settings.ShowUsage5h
            ShowUsageWeek    = $script:settings.ShowUsageWeek
            ShowOthersSessions = $script:settings.ShowOthersSessions
            AskBeforeKill    = $script:settings.AskBeforeKill
            KeepClosedWindows = $script:settings.KeepClosedWindows
            WaitOnOwnWork    = $script:settings.WaitOnOwnWork
            DefaultSound     = $script:settings.DefaultSound
            Preset           = $script:settings.Preset
            Sounds           = [pscustomobject]$script:settings.Sounds
            CpuLimits        = [pscustomobject]$script:settings.CpuLimits
            HiddenLaunchRepos = @($script:settings.HiddenLaunchRepos)
        } | ConvertTo-Json -Depth 4 | Set-Content -Path $settingsFile -Encoding UTF8
    } catch { Write-ErrorLog -Where 'settings' -Problem $_ }
}

Read-Settings

# The Windows sounds a session can pick, shortest and most distinct first. A
# fixed list rather than the whole Media folder: that folder also holds alarms
# and ringtones that play for half a minute. Names missing on a machine are
# dropped, since Windows versions ship different sets.
$soundFolder = Join-Path $env:WINDIR 'Media'
$soundChoices = @(
    'Windows Notify System Generic', 'Windows Notify Messaging', 'Windows Notify Email',
    'Windows Notify Calendar', 'Windows Proximity Notification', 'Windows Message Nudge',
    'chimes', 'chord', 'ding', 'notify', 'tada'
) | Where-Object { Test-Path (Join-Path $soundFolder "$_.wav") }

# Players are kept per sound, because creating one loads the file from disk.
$script:soundPlayers = @{}

function Invoke-Sound {
    param([string]$Name)
    if (-not $Name) { return }
    $path = Join-Path $soundFolder "$Name.wav"
    if (-not (Test-Path $path)) { return }
    try {
        if (-not $script:soundPlayers.ContainsKey($Name)) {
            $player = New-Object System.Media.SoundPlayer $path
            $player.Load()
            $script:soundPlayers[$Name] = $player
        }
        # Play, not PlaySync: it returns at once and never holds up the poll.
        $script:soundPlayers[$Name].Play()
    } catch { Write-ErrorLog -Where 'sound' -Problem $_ }
}
$listSep = ' ' + [char]0x00B7 + ' '   # code point: the file is read as ANSI

function Get-UnityProjectPath {
    param([string]$CommandLine)
    # The Hub passes -projectpath unquoted, import workers pass "-projectPath"
    # "D:/..." quoted. Both end at the next argument.
    $match = [regex]::Match($CommandLine, '-projectpath"?\s+"?([^"]+?)"?(\s+-|\s*$)', 'IgnoreCase')
    if (-not $match.Success) { return $null }
    return ($match.Groups[1].Value.Trim() -replace '/', '\').TrimEnd('\')
}

# Plastic writes the loaded branch into the workspace selector, which is far
# cheaper than asking cm. A git or unversioned project simply has no branch.
function Get-ProjectBranch {
    param([string]$ProjectPath)
    $selector = Join-Path $ProjectPath '.plastic\plastic.selector'
    if (-not (Test-Path $selector)) { return '' }
    $match = Select-String -Path $selector -Pattern '(?:smart)?branch\s+"([^"]+)"' | Select-Object -First 1
    if ($match) { return $match.Matches[0].Groups[1].Value }
    return ''
}

# Runs on the slow timer. Get-Process costs a few milliseconds; the command line
# needs a WMI query of about 20 ms, which is why it is asked once per process
# and remembered for as long as that process lives.
function Get-UnityEditors {
    $now = Get-Date
    $logicalProcessors = [Environment]::ProcessorCount
    $processes = @(Get-Process -Name 'Unity' -ErrorAction SilentlyContinue)

    $alive = @{}
    $byProject = @{}
    foreach ($process in $processes) {
        $processId = [int]$process.Id
        $alive[$processId] = $true
        if (-not $script:unityCommandLines.ContainsKey($processId)) {
            $commandLine = ''
            try {
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop
                if ($cim -and $cim.CommandLine) { $commandLine = [string]$cim.CommandLine }
            } catch { }
            $script:unityCommandLines[$processId] = $commandLine
        }
        $commandLine = $script:unityCommandLines[$processId]

        # The Hub's own unity.exe runs as "unity.exe serve" without a project.
        $projectPath = Get-UnityProjectPath $commandLine
        if (-not $projectPath) { continue }

        $key = $projectPath.ToLowerInvariant()
        if (-not $byProject.ContainsKey($key)) {
            $byProject[$key] = @{
                ProjectPath = $projectPath
                EditorId    = 0
                Window      = [IntPtr]::Zero
                Headless    = $false
                Workers     = 0
                WorkerIds   = @()
                Memory      = [int64]0
                Cpu         = 0.0
            }
        }
        $entry = $byProject[$key]

        try { $entry.Memory += [int64]$process.WorkingSet64 } catch { }

        if ($commandLine -match 'AssetImportWorker') {
            $entry.Workers += 1
            $entry.WorkerIds += $processId
        } else {
            $entry.EditorId = $processId
            $entry.Headless = $commandLine -match '(?i)-batchmode'
            try { $entry.Window = $process.MainWindowHandle } catch { }
        }

        # A rate over the sweep, not a lifetime average, so a finished import
        # stops reading busy within one sweep.
        try {
            $cpuTicks = $process.TotalProcessorTime.Ticks
            $previous = $script:unityCpuSamples[$processId]
            if ($previous) {
                $wallTicks = ($now - $previous.At).Ticks
                if ($wallTicks -gt 0) {
                    $entry.Cpu += 100.0 * ($cpuTicks - $previous.CpuTicks) / $wallTicks / $logicalProcessors
                }
            }
            $script:unityCpuSamples[$processId] = @{ At = $now; CpuTicks = $cpuTicks }
        } catch { }
    }

    # Forget ended processes, so neither table grows for the life of the card.
    foreach ($table in @($script:unityCommandLines, $script:unityCpuSamples)) {
        foreach ($processId in @($table.Keys)) {
            if (-not $alive.ContainsKey($processId)) { $table.Remove($processId) }
        }
    }

    $editors = @()
    foreach ($entry in $byProject.Values) {
        # Import workers without an editor are an editor that is shutting down.
        if ($entry.EditorId -eq 0) { continue }
        $editors += @{
            Id          = $entry.EditorId
            ProjectPath = $entry.ProjectPath
            WorkerIds   = $entry.WorkerIds
            Project     = Split-Path $entry.ProjectPath -Leaf
            Branch      = Get-ProjectBranch $entry.ProjectPath
            Headless    = $entry.Headless
            Window      = $entry.Window
            Workers     = $entry.Workers
            MemoryGB    = $entry.Memory / 1GB
            CpuPercent  = [Math]::Max(0.0, $entry.Cpu)
        }
    }
    return $editors
}

# The limit an editor's project picked in its row's menu, or the default for its
# kind of editor. 0 is no limit.
function Get-UnityCpuLimit {
    param([string]$ProjectPath, [bool]$Headless)
    $key = $ProjectPath.ToLowerInvariant()
    if ($script:settings.CpuLimits.ContainsKey($key)) { return [int]$script:settings.CpuLimits[$key] }
    if ($Headless) { return $unityCpuLimitDefault }
    return 0
}

# Puts every editor that has a limit, and its import workers, in its job, and
# brings the job's limits in line with the editor's row. Runs after every sweep,
# whether the Unity group is shown or not, because hiding the rows must not
# take the limits away. A sweep that finds everything in place only asks each
# process whether it is in its job.
function Update-UnityCaps {
    param($Editors)
    $alive = @{}
    foreach ($editor in @($Editors)) {
        $alive[$editor.Id] = $true
        foreach ($workerId in @($editor.WorkerIds)) { $alive[$workerId] = $true }
        try {
            $percent = Get-UnityCpuLimit -ProjectPath $editor.ProjectPath -Headless $editor.Headless
            $cap = $script:unityJobs[$editor.Id]
            if ($null -eq $cap) {
                # An editor with a window and no limit is left alone entirely.
                if ($percent -eq 0 -and -not $editor.Headless) { continue }
                $cap = @{ Job = [TlUnityCap]::Open($editor.Id); Percent = -1; Idle = $false; Capped = $false }
                $script:unityJobs[$editor.Id] = $cap
            }
            if ($cap.Percent -ne $percent -or $cap.Idle -ne $editor.Headless) {
                [TlUnityCap]::SetLimits($cap.Job, $percent, $editor.Headless)
                $cap.Percent = $percent
                $cap.Idle = $editor.Headless
            }
            foreach ($processId in @($editor.Id) + @($editor.WorkerIds)) {
                try {
                    [void][TlUnityCap]::Add($cap.Job, $processId)
                    if ($processId -eq $editor.Id) { $cap.Capped = $true }
                } catch {
                    if (-not $script:unityCapFailed.ContainsKey($processId)) {
                        $script:unityCapFailed[$processId] = $true
                        Write-ErrorLog -Where 'unitycap' -Problem $_
                    }
                }
            }
        } catch {
            if (-not $script:unityCapFailed.ContainsKey($editor.Id)) {
                $script:unityCapFailed[$editor.Id] = $true
                Write-ErrorLog -Where 'unitycap' -Problem $_
            }
        }
    }

    # An ended editor's job closes with it. Its handle is let go here, so the job
    # goes away once its last worker ends too.
    foreach ($editorId in @($script:unityJobs.Keys)) {
        if (-not $alive.ContainsKey($editorId)) {
            [TlUnityCap]::Close($script:unityJobs[$editorId].Job)
            $script:unityJobs.Remove($editorId)
        }
    }
    foreach ($processId in @($script:unityCapFailed.Keys)) {
        if (-not $alive.ContainsKey($processId)) { $script:unityCapFailed.Remove($processId) }
    }
}

# Headers are pooled rather than created and destroyed, because a workspace
# appearing and disappearing is common and rebuilding elements on a 400 ms
# timer would churn the visual tree for nothing.
function Get-Header {
    param([int]$Index)
    while ($script:headerPool.Count -le $Index) {
        $element = Import-Xaml 'Header.xaml'
        $rowCanvas.Children.Add($element) | Out-Null
        $newButton = $element.FindName('NewButton')
        # Fades in with the pointer anywhere on the heading, not only on the
        # button, so it is there by the time the pointer reaches it.
        $element.Tag = $newButton
        $element.Add_MouseEnter({ param($sender, $e) if ($sender.Tag.Visibility -eq 'Visible') { Set-Fade -Element $sender.Tag -To 1 } })
        $element.Add_MouseLeave({ param($sender, $e) Set-Fade -Element $sender.Tag -To 0 })
        # Its own press, so it neither drags the card nor reaches a row. The
        # folder rides on the button, set by the layout.
        $newButton.Add_MouseLeftButtonDown({
            param($sender, $e)
            $e.Handled = $true
            Start-NewPress -Button $sender -ClickCount $e.ClickCount
        })
        $newButton.Add_MouseLeftButtonUp({
            param($sender, $e)
            $e.Handled = $true
            try { Complete-NewPress -Button $sender } catch { Write-ErrorLog -Where 'launch' -Problem $_ }
        })
        [void]$script:headerPool.Add(@{
            Element   = $element
            Label     = $element.FindName('HeaderLabel')
            Swatch    = $element.FindName('Swatch')
            Icon      = $element.FindName('Icon')
            NewButton = $newButton
        })
    }
    return $script:headerPool[$Index]
}

# Hue by position in the alphabetically sorted list of workspaces currently on
# screen. Hashing the path was the first attempt, and it is more stable across
# restarts, but two workspaces then had a one-in-four chance of drawing the same
# colour, which is the only thing this stripe exists to prevent. Indexing can
# only shift colours when a workspace is opened or closed, which is rare and
# visible when it happens.
function Get-WorkspaceBrush {
    param([int]$Index)
    return $brush.Ws[$Index % $brush.Ws.Count]
}

# Icon by name, for the presets that list icons. Unlike the hues above this
# does hash the name, so a workspace keeps its icon from one start to the next:
# with ten or so icons rather than four, a clash is rarer, and one is settled by
# moving on to the next free icon, in the sorted order of the names. Repeats
# only once more workspaces are open than there are icons. The hash is our own,
# because String.GetHashCode is not promised to stay the same between runs.
function Get-WorkspaceIcons {
    param([string[]]$Names)
    $icons = $script:workspaceIcons
    $iconFor = @{}
    if ($icons.Count -eq 0) { return $iconFor }
    $taken = @{}
    foreach ($name in $Names) {
        [long]$hash = 0
        foreach ($c in $name.ToCharArray()) { $hash = ($hash * 31 + [int]$c) % 2147483647 }
        $i = [int]($hash % $icons.Count)
        for ($step = 0; $step -lt $icons.Count -and $taken.ContainsKey($i); $step++) { $i = ($i + 1) % $icons.Count }
        $taken[$i] = $true
        $iconFor[$name] = $icons[$i]
    }
    return $iconFor
}

# The stripe's colour for a session's model, for the presets that colour the
# stripe by model. A model not known yet, or of no family listed, is Other.
function Get-ModelBrush {
    param([string]$Model)
    if ($Model -match 'claude-([a-z]+)' -and $brush.Model.ContainsKey($matches[1])) { return $brush.Model[$matches[1]] }
    return $brush.ModelOther
}

# The tiles of the stripe patterns: size, path, and whether the path is
# filled or drawn as lines. Lines run past the tile's edge and are cut by it,
# so a diagonal meets the next tile's without a break.
$stripePatternTiles = @{
    hatch      = @{ W = 6; H = 6; Line = 1.2; Path = 'M-1,7 L7,-1 M-1,1 L1,-1 M5,7 L7,5' }
    crosshatch = @{ W = 6; H = 6; Line = 1.0; Path = 'M-1,7 L7,-1 M-1,1 L1,-1 M5,7 L7,5 M-1,-1 L7,7 M5,-1 L7,1 M-1,5 L1,7' }
    plus       = @{ W = 7; H = 7; Line = 0;   Path = 'M3,1 H4 V6 H3 Z M1,3 H6 V4 H1 Z' }
    dots       = @{ W = 4; H = 4; Line = 0;   Path = 'M1,1 H2.5 V2.5 H1 Z' }
    bars       = @{ W = 4; H = 4; Line = 0;   Path = 'M0,0 H4 V1.5 H0 Z' }
    chevron    = @{ W = 7; H = 6; Line = 1.2; Path = 'M0,4.5 L3.5,1.5 L7,4.5' }
    checker    = @{ W = 6; H = 6; Line = 0;   Path = 'M0,0 H3 V3 H0 Z M3,3 H6 V6 H3 Z' }
    rails      = @{ W = 7; H = 7; Line = 0;   Path = 'M3,0 H4.5 V7 H3 Z' }
}

# One pattern as a tiled brush in the preset's pattern ink, or null for plain.
# A name the card does not know is plain as well.
function New-StripePattern {
    param([string]$Name, $Ink)
    $tile = $stripePatternTiles[$Name]
    if ($null -eq $tile) { return $null }
    $box = New-Object System.Windows.Rect(0, 0, $tile.W, $tile.H)
    $group = New-Object System.Windows.Media.DrawingGroup
    $group.ClipGeometry = New-Object System.Windows.Media.RectangleGeometry($box)
    $group.Children.Add((New-Object System.Windows.Media.GeometryDrawing(
        [System.Windows.Media.Brushes]::Transparent, $null, (New-Object System.Windows.Media.RectangleGeometry($box)))))
    $shape = [System.Windows.Media.Geometry]::Parse($tile.Path)
    if ($tile.Line -gt 0) {
        $pen = New-Object System.Windows.Media.Pen($Ink, $tile.Line)
        $group.Children.Add((New-Object System.Windows.Media.GeometryDrawing($null, $pen, $shape)))
    } else {
        $group.Children.Add((New-Object System.Windows.Media.GeometryDrawing($Ink, $null, $shape)))
    }
    $pattern = New-Object System.Windows.Media.DrawingBrush($group)
    $pattern.TileMode = 'Tile'
    $pattern.Viewport = $box
    $pattern.ViewportUnits = 'Absolute'
    $pattern.Viewbox = $box
    $pattern.ViewboxUnits = 'Absolute'
    if ($pattern.CanFreeze) { $pattern.Freeze() }
    return $pattern
}

# Pattern by window, for the presets that list patterns. The window handle
# stays the same for as long as the window is open, through a /clear and
# through a restart of the card, so the pattern does too. Clashes move on to
# the next free pattern, in the order of the handles.
function Get-SessionPatterns {
    param($Recs)
    $patterns = $script:stripePatterns
    $patternFor = @{}
    if ($patterns.Count -eq 0) { return $patternFor }
    $taken = @{}
    foreach ($rec in @($Recs | Sort-Object { $_.Handle.ToInt64() })) {
        $key = $rec.Handle.ToInt64()
        $i = [int]([Math]::Abs($key) % $patterns.Count)
        for ($step = 0; $step -lt $patterns.Count -and $taken.ContainsKey($i); $step++) { $i = ($i + 1) % $patterns.Count }
        $taken[$i] = $true
        $patternFor[$key] = $patterns[$i]
    }
    return $patternFor
}

# A heading's "+" acts on a press and a release both on it, and once: a
# double-click would otherwise open two sessions, and a release ending a press
# made elsewhere would open one nobody asked for. A press on it also ends any
# row press left over, so moving off it cannot start that row's drag.
$script:newPress = $null
function Start-NewPress {
    param($Button, [int]$ClickCount)
    $script:pressRow = $null
    $script:newPress = $(if ($ClickCount -gt 1) { $null } else { $Button })
}

function Complete-NewPress {
    param($Button)
    $pressed = $script:newPress
    $script:newPress = $null
    if (-not [object]::ReferenceEquals($pressed, $Button)) { return }
    if ($Button.Tag) { Start-ClaudeSession -Folder ([string]$Button.Tag) }
}

# The folder a heading's "+" starts a session in: the one its rows' sessions
# started in. Only a row with a session on this PC has a folder, so a group on
# another machine gets no "+".
function Get-GroupFolder {
    param([string]$Name, $Recs)
    # Grouped by the repository the agent works in, the heading often names a
    # repository inside the folder its sessions were started from, as one part
    # of a larger checkout. A new session starts where those did, so the most
    # common of their folders wins, and on a tie the earliest session's.
    if ($script:settings.GroupByRepo) {
        $count = @{}
        $best = ''
        foreach ($rec in @(@($Recs) | Sort-Object { $_.Seq })) {
            if (-not $rec.Cwd) { continue }
            $cwd = ([string]$rec.Cwd).TrimEnd('\')
            if (-not [System.IO.Directory]::Exists($cwd)) { continue }
            $key = $cwd.ToLowerInvariant()
            $count[$key] = 1 + [int]$count[$key]
            if (-not $best -or $count[$key] -gt $count[$best.ToLowerInvariant()]) { $best = $cwd }
        }
        return $best
    }
    foreach ($rec in @($Recs)) {
        if (-not $rec.Cwd) { continue }
        $cwd = ([string]$rec.Cwd).TrimEnd('\')
        if ((Split-Path -Leaf $cwd) -ieq $Name -and [System.IO.Directory]::Exists($cwd)) { return $cwd }
        $root = Get-RepoRoot -Path $cwd
        if ($root -and (Split-Path -Leaf $root) -ieq $Name) { return $root }
    }
    return ''
}

# A heading shows its icon when it has one, and the swatch otherwise.
function Set-HeaderMark {
    param($Header, [string]$Icon)
    if ($Icon) {
        $Header.Icon.Text = $Icon
        $Header.Icon.Visibility = 'Visible'
        $Header.Swatch.Visibility = 'Collapsed'
    } else {
        $Header.Icon.Visibility = 'Collapsed'
        $Header.Swatch.Visibility = 'Visible'
    }
}

# ---------------------------------------------------------------------------
# New sessions: the repos the New session menus offer
#
# Claude Code keeps one folder per working directory in ~/.claude/projects,
# each holding that directory's transcripts. A repo is offered when a session
# ran in it in the last two weeks, most used first, so the list keeps itself:
# a repo worked in shows up, one left alone drops off, and a folder that is no
# repo at all, as system32 or the Desktop, never shows. Only the file dates are
# looked at for the count; the folder is read from the newest transcript's
# first lines, since a project folder's own name is a lossy spelling of it.
# ---------------------------------------------------------------------------
$launchDays     = 14
$launchMax      = 5
$launchCacheSec = 60
$launchCwdChars = 2097152
$claudeProjects = Join-Path $env:USERPROFILE '.claude\projects'
$script:launchCache = $null

# The folder a transcript's session ran in, or '' when its opening lines do
# not say. Read a line at a time up to the first that does: a transcript can
# open with request records of a hundred kilobytes or more before any line
# carries the folder. Shared for writing, since the newest transcript is often
# one a live session is still writing.
function Read-TranscriptCwd {
    param([string]$Path)
    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $seen = 0
        while ($seen -lt $launchCwdChars) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            $seen += $line.Length
            $m = [regex]::Match($line, '"cwd":"((?:[^"\\]|\\.)*)"')
            if (-not $m.Success) { continue }
            # A session whose shell is Git Bash records /c/Users/..., which
            # names C:\Users\... on this PC.
            $cwd = [regex]::Unescape($m.Groups[1].Value)
            $drive = [regex]::Match($cwd, '^/([A-Za-z])(/.*)?$')
            if ($drive.Success) { $cwd = $drive.Groups[1].Value.ToUpperInvariant() + ':' + ($drive.Groups[2].Value -replace '/', '\') }
            return $cwd
        }
    } catch { } finally { if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() } }
    return ''
}

# The repos to offer, and every project folder left out with why. A folder
# that is gone is told apart before the repo lookup, which would otherwise
# walk up from it to a repo it once sat in.
function Get-LaunchRepos {
    param([string]$ProjectsDir = $claudeProjects, [string[]]$Hidden = @(), [datetime]$Now = (Get-Date))
    $since = $Now.AddDays(-$launchDays)
    $byRoot = @{}
    $skipped = New-Object System.Collections.ArrayList
    foreach ($dir in @(Get-ChildItem -LiteralPath $ProjectsDir -Directory -ErrorAction SilentlyContinue)) {
        $recent = @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime -Descending)
        $why = ''
        $root = ''
        if ($recent.Count -eq 0) { $why = 'old' }
        else {
            $cwd = Read-TranscriptCwd -Path $recent[0].FullName
            if (-not $cwd) { $why = 'no cwd' }
            elseif (-not [System.IO.Directory]::Exists($cwd)) { $why = 'gone' }
            else {
                $root = Get-RepoRoot -Path $cwd
                if (-not $root) { $why = 'not a repo' }
                elseif (@($Hidden | Where-Object { $_ -ieq $root }).Count -gt 0) { $why = 'hidden' }
            }
        }
        if ($why) { [void]$skipped.Add(@{ Folder = $dir.Name; Why = $why }); continue }
        $key = $root.ToLowerInvariant()
        if (-not $byRoot.ContainsKey($key)) { $byRoot[$key] = @{ Path = $root; Name = (Split-Path -Leaf $root); Count = 0 } }
        $byRoot[$key].Count += $recent.Count
    }
    $sorted = @($byRoot.Values | Sort-Object @{ Expression = { $_.Count }; Descending = $true }, @{ Expression = { $_.Name } })
    foreach ($extra in @($sorted | Select-Object -Skip $launchMax)) { [void]$skipped.Add(@{ Folder = $extra.Name; Why = 'over limit' }) }
    return @{ Repos = @($sorted | Select-Object -First $launchMax); Skipped = @($skipped) }
}

# The list as the menus show it, built at most once a minute: menus open in
# bursts, and the list changes over days.
function Get-LaunchMenuRepos {
    $cache = $script:launchCache
    if ($null -eq $cache -or ((Get-Date) - $cache.At).TotalSeconds -ge $launchCacheSec) {
        $repos = @()
        try { $repos = @((Get-LaunchRepos -Hidden @($script:settings.HiddenLaunchRepos)).Repos) }
        catch { Write-ErrorLog -Where 'launch' -Problem $_ }
        $cache = @{ At = Get-Date; Repos = $repos }
        $script:launchCache = $cache
    }
    return @($cache.Repos)
}

# ---------------------------------------------------------------------------
# Stage 1: console probe. Kept in the shipping script so the parsing can always
# be checked against reality without the UI in the way.
# ---------------------------------------------------------------------------
if ($Probe) {
    if ($Launch) {
        $dir = $(if ($ProjectsDir) { $ProjectsDir } else { $claudeProjects })
        $list = Get-LaunchRepos -ProjectsDir $dir -Hidden @($script:settings.HiddenLaunchRepos)
        # Written to the output, not the host, so a check script can capture it.
        foreach ($r in $list.Repos) { Write-Output ('  {0,4}  {1,-28} {2}' -f $r.Count, $r.Name, $r.Path) }
        foreach ($s in $list.Skipped) { Write-Output ('  skip  {0,-10}  {1}' -f $s.Why, $s.Folder) }
        return
    }
    $pass = 0
    while ($true) {
        $pass++
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $scan = Scan-Windows
        Sync-SessionMap -ShellToWindow $scan.ShellToWindow
        $found = @()
        foreach ($h in $scan.Terminals) {
            $title = Get-WindowTitle -Handle $h
            $parsed = Read-SessionTitle -Title $title
            if ($parsed) {
                $key = [string][int64]$h
                $ws = 'UNRESOLVED'
                if ($script:sessionByHwnd.ContainsKey($key)) { $ws = $script:sessionByHwnd[$key].Workspace }
                $found += ('  {0,-10} {1,-8} {2,-28} {3}' -f [int64]$h, $parsed.State, $ws, $parsed.Label)
            }
        }
        $sw.Stop()
        # Uses the count Sync-SessionMap already worked out. Calling
        # Get-LiveSessionCount here instead would add a Get-Process per session
        # and make the timing above look four times worse than the widget's.
        Write-Host ("{0}  pass {1}  sweep {2:0.0} ms  windows={3}  live sessions={4}" -f `
            (Get-Date -Format 'HH:mm:ss'), $pass, $sw.Elapsed.TotalMilliseconds, $found.Count, $script:liveSessionCount)
        $found | ForEach-Object { Write-Host $_ }
        foreach ($editor in @(Get-UnityEditors)) {
            Write-Host ('  unity      {0,-8} {1,-28} {2,5:0.0} GB {3,5:0.0} % cpu  {4} importers  {5}' -f `
                $(if ($editor.Headless) { 'headless' } else { 'editor' }), $editor.Project,
                $editor.MemoryGB, $editor.CpuPercent, $editor.Workers, $editor.Branch)
        }
        if ($Passes -gt 0 -and $pass -ge $Passes) { break }
        Start-Sleep -Milliseconds 1000
    }
    return
}

# ---------------------------------------------------------------------------
# Widget
# ---------------------------------------------------------------------------

# One card only. Launching from the Start Menu while the Startup copy is already
# running would otherwise stack two identical cards on top of each other.
#
# The second instance does not simply die, because the usual reason for
# launching again is that the card was hidden to the tray and is wanted back. It
# leaves a flag that the running instance picks up on its next poll, then exits.
$showFlag = Join-Path $stateDir 'show.flag'
$createdNew = $false
$script:instanceMutex = New-Object System.Threading.Mutex($true, 'Local\AgentTrafficLight', [ref]$createdNew)
if (-not $createdNew) {
    try { Set-Content -Path $showFlag -Value (Get-Date -Format 'o') -Encoding UTF8 } catch { }
    exit 0
}
if (Test-Path $showFlag) { Remove-Item $showFlag -Force -ErrorAction SilentlyContinue }

# Per-monitor v2 before any window exists. All three monitors here run at 100%
# today so this changes nothing now, but the PowerShell host declares itself DPI
# unaware, which would show as a blurry stretched card on any scaled display.
try { [TlNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null } catch { }

[TlNative]::ShowWindow([TlNative]::GetConsoleWindow(), $SW_HIDE) | Out-Null

# XAML is read from the tool's folder, or from another root given. Each file is
# read with its own folder as its base, so a preset can name an image or a font
# by a path relative to it, such as art\ and fonts\.
$xamlRoot = $PSScriptRoot
function Import-Xaml {
    param([string]$Name, [string]$Root = $xamlRoot)
    $path = Join-Path $Root $Name
    $context = New-Object System.Windows.Markup.ParserContext
    $context.BaseUri = New-Object System.Uri ((Split-Path $path -Parent) + '\')
    $stream = [System.IO.File]::OpenRead($path)
    try { return [System.Windows.Markup.XamlReader]::Load($stream, $context) }
    finally { $stream.Dispose() }
}

$window    = Import-Xaml 'AgentTrafficLight.xaml'
# The look comes from the presets folder: Classic, which holds every key, and
# the chosen preset laid over it, holding only what it changes. Merged before
# anything reads a resource, so the lookups below and every row built later
# find them.
$presetDir = Join-Path $PSScriptRoot 'presets'

# Presets are loaded from a copy of the presets folder the card keeps for
# itself, never from the folder in the repository. A font in use is read from
# its file again whenever Windows rebuilds it, minutes after it was first drawn,
# and a pull, merge or branch switch rewrites the repository's files, if only
# with a new time: the next rebuild then found no file it knew, and the card
# fell over in the middle of drawing, with nothing to catch. Git never touches
# the copy.
#
# The copy is named by what the folder holds, its files' paths, sizes and
# times, so a style switch after a change in the repository takes a new copy
# and sees the change, and an unchanged folder is not copied again. Earlier
# copies stay, since fonts already loaded may still read from them, until the
# card next starts.
$snapshotRoot = Join-Path $env:LOCALAPPDATA 'AgentTrafficLight\presets'
Get-ChildItem $snapshotRoot -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

function Get-PresetSnapshot {
    $files = @(Get-ChildItem $presetDir -Recurse -File | Sort-Object FullName | ForEach-Object {
        '{0}|{1}|{2}' -f $_.FullName.Substring($presetDir.Length), $_.Length, $_.LastWriteTimeUtc.Ticks })
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($files -join "`n")))
    $name = (($hash[0..5] | ForEach-Object { $_.ToString('x2') }) -join '')
    $dir = Join-Path $snapshotRoot $name
    if (-not (Test-Path $dir)) {
        # Copied under another name first, so a copy cut short is never used.
        $partial = "$dir.partial"
        Remove-Item $partial -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $partial | Out-Null
        Copy-Item (Join-Path $presetDir '*') $partial -Recurse -Force
        Rename-Item $partial $name
    }
    return $dir
}

# The chosen preset's dictionary, or null for Classic, which is the base and
# needs no second layer. Throws if the file is missing or is not a preset, so
# the caller decides what a failure means.
#
# Every value is checked against Classic's before the preset can touch the
# card. A value of the wrong type would otherwise throw half way through a
# switch, or quietly draw nothing where the template expected it, and a null
# counts as not set, so Classic's value would show through. Where Classic has
# no effect at all, which costs nothing to draw, a preset may set any effect.
function Import-Preset {
    param([string]$Name)
    if ($Name -eq 'Classic') { return $null }
    $dict = Import-Xaml -Name "$Name.xaml" -Root (Get-PresetSnapshot)
    if (-not ($dict -is [System.Windows.ResourceDictionary])) { throw "presets\$Name.xaml is not a ResourceDictionary" }
    $classic = $window.Resources.MergedDictionaries[0]
    foreach ($key in @($dict.Keys)) {
        if (-not $classic.Contains($key)) { throw "presets\$Name.xaml sets $key, which Classic does not have" }
        $want = [System.Windows.Media.Effects.Effect]
        if ($null -ne $classic[$key]) { $want = $classic[$key].GetType() }
        if ($null -eq $dict[$key] -or -not $want.IsInstanceOfType($dict[$key])) {
            throw "presets\$Name.xaml sets $key to something other than a $($want.Name)"
        }
    }
    # The faces split out of FontText and FontClock, and the warning colour
    # split out of the blocked one, follow them in a preset that does not set
    # them itself, so it looks as it did before the split.
    foreach ($pair in @(@('FontHeader', 'FontText'), @('FontTimer', 'FontText'), @('FontCaption', 'FontClock'),
                        @('BrushWarning', 'BrushBlocked'), @('BrushRing', 'BrushTextDim'))) {
        if (-not $dict.Contains($pair[0]) -and $dict.Contains($pair[1])) { $dict[$pair[0]] = $dict[$pair[1]] }
    }
    return $dict
}

# The row buttons' colours a preset may leave out, each with the colour it then
# follows and how much of it shows: the look of the heading's "+", the icon in
# the dim text colour on a faint pill of it, and under the pointer the text
# colour on the menu highlight. Every preset already makes that pair readable.
$buttonFollows = @(
    @('BrushIconButton', 'BrushTextDim', 1.0), @('BrushIconButtonBg', 'BrushTextDim', 0.18),
    @('BrushDisconnectHoverBg', 'BrushMenuHighlight', 0.6), @('BrushKillHoverBg', 'BrushMenuHighlight', 0.6),
    @('BrushDisconnectHoverIcon', 'BrushText', 1.0), @('BrushKillHoverIcon', 'BrushText', 1.0))

# Puts a preset over Classic in place of the one there now, or takes it away.
# The button colours it leaves out are laid on the window's own resources,
# which win over both layers, so Classic's own values never show.
function Use-PresetLayer {
    param($Dict)
    $merged = $window.Resources.MergedDictionaries
    while ($merged.Count -gt 1) { $merged.RemoveAt(1) }
    if ($null -ne $Dict) { [void]$merged.Add($Dict) }
    foreach ($follow in $buttonFollows) {
        $window.Resources.Remove($follow[0])
        if ($null -ne $Dict -and $Dict.Contains($follow[0])) { continue }
        # Made with ::new, not New-Object, whose PowerShell wrapper would go
        # into the dictionary as it is and fail to cast to a brush when drawn.
        $made = [System.Windows.Media.SolidColorBrush]::new($window.FindResource($follow[1]).Color)
        $made.Opacity = $follow[2]
        $made.Freeze()
        $window.Resources[$follow[0]] = $made
    }
}

# Classic first, then the others by name.
function Get-PresetNames {
    $others = @(Get-ChildItem $presetDir -Filter '*.xaml' -File |
                ForEach-Object { $_.BaseName } | Where-Object { $_ -ne 'Classic' } | Sort-Object)
    return @('Classic') + $others
}

[void]$window.Resources.MergedDictionaries.Add((Import-Xaml -Name 'Classic.xaml' -Root (Get-PresetSnapshot)))
$script:preset = 'Classic'
try {
    Use-PresetLayer -Dict (Import-Preset -Name $script:settings.Preset)
    $script:preset = $script:settings.Preset
} catch {
    Write-ErrorLog -Where 'style' -Problem $_
    Use-PresetLayer -Dict $null
}
$rowCanvas = $window.FindName('RowCanvas')
$warnText  = $window.FindName('WarnText')
$workClock     = $window.FindName('WorkClock')
$workClockText = $window.FindName('WorkClockText')
$workClockSub  = $window.FindName('WorkClockSub')
$menuButton    = $window.FindName('MenuButton')
$usagePanel    = $window.FindName('UsagePanel')
$usageBars = @(
    @{ Setting = 'ShowUsage5h'; Field = 'five_hour'; Row = $window.FindName('Usage5h')
       Used = $window.FindName('Usage5hUsed'); Left = $window.FindName('Usage5hLeft'); Fill = $window.FindName('Usage5hFill')
       Pct = $window.FindName('Usage5hPct'); Reset = $window.FindName('Usage5hReset') },
    @{ Setting = 'ShowUsageWeek'; Field = 'seven_day'; Row = $window.FindName('UsageWeek')
       Used = $window.FindName('UsageWeekUsed'); Left = $window.FindName('UsageWeekLeft'); Fill = $window.FindName('UsageWeekFill')
       Pct = $window.FindName('UsageWeekPct'); Reset = $window.FindName('UsageWeekReset') }
)

# The colours and sizes the script works with itself, read from the merged
# presets. Run at start and after every switch of preset; everything bound in
# the templates follows a switch by itself, these do not.
#
# The card's width follows the rows: a row, its padding either side, the
# card's two border lines either side, and the shadow's room round the card.
# Leaving the border lines out took them off the padding on the right and at
# the bottom, which then sat narrower than on the left. The context bar starts
# after the stripe and stops short of the timer's margin, 30 in all.
function Read-StyleValues {
    $script:brush = @{
        Working        = $window.FindResource('BrushWorking')
        Waiting        = $window.FindResource('BrushWaiting')
        Blocked        = $window.FindResource('BrushBlocked')
        RowBase        = $window.FindResource('BrushRowBase')
        RowEdge        = $window.FindResource('BrushRowEdge')
        RowEdgeOnWait  = $window.FindResource('BrushRowEdgeOnWait')
        RowEdgeOnBlock = $window.FindResource('BrushRowEdgeOnBlock')
        DotOnBlock     = $window.FindResource('BrushDotOnBlock')
        Text           = $window.FindResource('BrushText')
        TextDim        = $window.FindResource('BrushTextDim')
        Ring           = $window.FindResource('BrushRing')
        TextOnWait    = $window.FindResource('BrushTextOnWait')
        TextOnBlock    = $window.FindResource('BrushTextOnBlock')
        TimerOnWait    = $window.FindResource('BrushTimerOnWait')
        TimerOnBlock   = $window.FindResource('BrushTimerOnBlock')
        WsNeutral      = $window.FindResource('BrushWsNeutral')
        CtxFill        = $window.FindResource('BrushCtxFill')
        CtxHigh        = $window.FindResource('BrushCtxHigh')
        Headless       = $window.FindResource('BrushHeadless')
        UnityEditor    = $window.FindResource('BrushUnityEditor')
        Model          = @{
            opus   = $window.FindResource('BrushModelOpus')
            fable  = $window.FindResource('BrushModelFable')
            sonnet = $window.FindResource('BrushModelSonnet')
            haiku  = $window.FindResource('BrushModelHaiku')
        }
        ModelOther     = $window.FindResource('BrushModelOther')
        Ws             = @(
            $window.FindResource('BrushWs0'),
            $window.FindResource('BrushWs1'),
            $window.FindResource('BrushWs2'),
            $window.FindResource('BrushWs3')
        )
    }
    $script:workspaceIcons = @(([string]$window.FindResource('WorkspaceIcons')) -split '\s+' | Where-Object { $_ })
    $script:stripeByModel = ([string]$window.FindResource('StripeColour')) -eq 'Model'
    $script:stripeModelName = [bool]$window.FindResource('StripeModelName')
    $patternInk = $window.FindResource('BrushStripePattern')
    # A list rather than a pipeline, which would drop plain's null and with it
    # its place among the patterns.
    $script:stripePatterns = New-Object System.Collections.ArrayList
    foreach ($name in @(([string]$window.FindResource('StripePatterns')) -split '\s+' | Where-Object { $_ })) {
        [void]$script:stripePatterns.Add((New-StripePattern -Name $name -Ink $patternInk))
    }
    $script:rowHeight    = [double]$window.FindResource('RowHeight')
    $script:rowGap       = [double]$window.FindResource('RowGap')
    $script:headerHeight = [double]$window.FindResource('HeaderHeight')
    $script:groupGap     = [double]$window.FindResource('GroupGap')
    $script:cardPadding  = [double]$window.FindResource('CardPadding')
    $rowWidth            = [double]$window.FindResource('RowWidth')
    $edge  = $window.FindResource('CardEdgeThickness')
    $inner = $window.FindResource('CardInnerThickness')
    $script:cardBorder   = New-Object System.Windows.Thickness(($edge.Left + $inner.Left), ($edge.Top + $inner.Top),
                                                               ($edge.Right + $inner.Right), ($edge.Bottom + $inner.Bottom))
    $script:cardWidth    = $rowWidth + 2 * $script:cardPadding + $script:cardBorder.Left + $script:cardBorder.Right
    $script:ctxBarWidth  = $rowWidth - 30
    $window.Width = $script:cardWidth + 2 * $shadowMargin
    $rowCanvas.Margin = New-Object System.Windows.Thickness($script:cardPadding, $script:cardPadding, $script:cardPadding, 0)
}

Read-StyleValues

# One rotation shared by every working row's ring, turning on one clock. Each
# indicator used to start its own animation the moment its row began working,
# so no two were ever in step; one shared transform means they cannot drift
# apart. It only runs while some row is working or has helpers running, so a
# card of finished sessions still costs nothing to draw.
$script:spinTurn = New-Object System.Windows.Media.RotateTransform
$script:spinAnimation = New-Object System.Windows.Media.Animation.DoubleAnimation
$script:spinAnimation.From = 0.0
$script:spinAnimation.To = 360.0
$script:spinAnimation.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds($spinTurnMs)
$script:spinAnimation.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
[System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($script:spinAnimation, $endlessFps)
$script:spinRunning = $false

# Lift for a row being dragged, so it reads as picked up and above the others.
$script:liftShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$script:liftShadow.Color = [System.Windows.Media.Colors]::Black
$script:liftShadow.BlurRadius = 14
$script:liftShadow.ShadowDepth = 3
$script:liftShadow.Direction = 270
$script:liftShadow.Opacity = 0.55

# Window handles in the order rows were dragged into. A row is a terminal window,
# and its handle stays the same for as long as that window is open: through a
# /clear, through a new session started in it, and through a restart of this
# widget. It also does not depend on matching the window to a session file,
# which a session id would. Only the order inside one workspace group means
# anything, since each group is laid out on its own. A window that is not listed
# sorts after the listed ones by session start time, so a new session still
# lands at the bottom of its group exactly as before.
$orderFile = Join-Path $stateDir 'row-order.json'
$script:userOrder = New-Object System.Collections.ArrayList
$script:orderIndex = @{}

function Update-OrderIndex {
    $script:orderIndex = @{}
    for ($i = 0; $i -lt $script:userOrder.Count; $i++) {
        $script:orderIndex[[string]$script:userOrder[$i]] = $i
    }
}

try {
    # Assigned before the loop on purpose: PowerShell 5.1's ConvertFrom-Json
    # sends a JSON array down the pipeline as one object, not item by item.
    $saved = Get-Content $orderFile -Raw -ErrorAction Stop | ConvertFrom-Json
    foreach ($id in $saved) { [void]$script:userOrder.Add([string]$id) }
} catch { }
Update-OrderIndex

# The row being dragged, or null. Holds the row, its group, where in the row the
# pointer grabbed it, the slot it would drop into, and the order on screen.
$script:drag = $null
# Per group, the top of its first slot and how many slots it has; and the rows
# in the order last laid out. Both are written by Update-Layout, and the drag
# reads them to know where it may go and where it started.
$script:groupSlots = @{}
$script:groupOrder = @{}
$script:pressCanvasY = 0.0

$script:sessionByHwnd = @{}
$script:outgoingByHwnd = @{}
$script:liveSessionCount = 0
$script:headerPool = New-Object System.Collections.ArrayList

if (Test-Path $positionFile) {
    try {
        $pos = Get-Content $positionFile -Raw | ConvertFrom-Json
        $window.Left = [double]$pos.Left
        $window.Top  = [double]$pos.Top
    } catch { }
}

function Save-Position {
    try {
        @{ Left = $window.Left; Top = $window.Top } | ConvertTo-Json | Set-Content -Path $positionFile -Encoding UTF8
    } catch { }
}

# rows: handle (as int64 string) -> record. Order in $rowOrder is presentation
# order, which is what the slide animation animates between.
$rows = @{}
$script:firstSeen = 0

function New-Row {
    param([IntPtr]$Handle, [string]$Label, [string]$State)
    $element = Import-Xaml 'Row.xaml'
    $script:firstSeen++
    $rec = @{
        Handle    = $Handle
        Element   = $element
        Bg        = $element
        Dot       = $element.FindName('Dot')
        Stripe    = $element.FindName('Stripe')
        StripePattern = $element.FindName('StripePattern')
        LabelText = $element.FindName('Label')
        DetailText = $element.FindName('Detail')
        TimerText = $element.FindName('Timer')
        ModelText = $element.FindName('Model')
        CtxTrack  = $element.FindName('CtxTrack')
        CtxFill   = $element.FindName('CtxFill')
        TimerColumn = $element.FindName('TimerColumn')
        SoundMark = $element.FindName('SoundMark')
        Spinner   = $element.FindName('Spinner')
        HelperMark  = $element.FindName('HelperMark')
        HelperRing  = $element.FindName('HelperRing')
        HelperCount = $element.FindName('HelperCount')
        # Helper agents the session has running now.
        Helpers   = 0
        State     = ''
        Label     = ''
        # The line under the label. Only the Marshal row ever has one.
        Detail    = ''
        Since     = Get-Date
        # WorkSince ticks while the session works, cut to the whole second so
        # every running timer on the card turns over at the same moment.
        # FinishedAt is the clock time the work stopped. It replaced the frozen
        # duration of that work, which nobody read once a row was green; the
        # time it finished says how old the session is, which people do want.
        WorkSince = $null
        FinishedAt = $null
        # When Marshal's last round ended, from its own report. Null on every
        # other row, which leaves their timers exactly as they were.
        RoundAt   = $null
        SessionStatus   = ''
        StatusUpdatedAt = [double]0
        Top       = -1.0
        Seq       = $script:firstSeen
        Alarm     = $null
        SessionId = ''
        Cwd       = ''
        Workspace = ''
        StartedAt = [double]0
        Model     = ''
        Prompt    = 0
        # The second line of a remote row, and for an outgoing one the host it
        # connects to. Empty on a row driven from this desktop.
        RemoteNote = ''
        OutHost   = ''
        # What a click on a row with no window connected does, shown over it on
        # hover: 'Reconnect', 'Resume' or 'Sign in'. Empty on every other row.
        Reconnect     = $element.FindName('Reconnect')
        ReconnectText = $element.FindName('ReconnectText')
        ClickAction   = ''
        # The row's buttons, shown on hover: Disconnect, Close or Resume, and
        # Kill. And the tmux session a window's title names, if any.
        RowButtons       = $element.FindName('RowButtons')
        DisconnectButton = $element.FindName('DisconnectButton')
        CloseButton      = $element.FindName('CloseButton')
        ResumeButton     = $element.FindName('ResumeButton')
        KillButton       = $element.FindName('KillButton')
        TmuxName  = ''
        # A closed session of this PC: a slim row of its title and when it
        # closed. Resuming while a resume of it is under way.
        Closed    = $false
        Resuming  = $false
    }

    # A row with no window connected fades up and shows what a click will do
    # while the pointer is over it. A closed row says it with its Resume
    # button instead, which a veil over its one line would cover.
    $element.Add_MouseEnter({
        param($sender, $e)
        $rec = $rows[[string][int64]$sender.Tag]
        if ($null -ne $rec -and $rec.ClickAction) {
            if (-not $rec.Closed) {
                $rec.ReconnectText.Text = $rec.ClickAction
                $rec.Reconnect.Visibility = 'Visible'
                Set-Fade -Element $rec.Reconnect -To 1
            }
            Set-Fade -Element $sender -To 1
        }
    })
    $element.Add_MouseLeave({
        param($sender, $e)
        $rec = $rows[[string][int64]$sender.Tag]
        if ($null -ne $rec -and $rec.ClickAction) {
            if (-not $rec.Closed) { Set-Fade -Element $rec.Reconnect -To 0 }
            Set-Fade -Element $sender -To $keptFade
        }
    })

    # The buttons take their own press, so none starts a drag or counts as a
    # click on the row. Kill asks before it stops anything that runs.
    foreach ($button in @($rec.DisconnectButton, $rec.CloseButton, $rec.ResumeButton, $rec.KillButton)) {
        $button.Tag = $Handle
        $button.Add_MouseLeftButtonDown({
            param($sender, $e)
            $e.Handled = $true
        })
        $button.Add_MouseLeftButtonUp({
            param($sender, $e)
            $e.Handled = $true
            $row = $rows[[string][int64]$sender.Tag]
            if ($null -eq $row) { return }
            try {
                $kept = Get-RowEndable -Element $row.Element
                $closed = Get-RowClosed -Element $row.Element
                if ($sender.Name -eq 'ResumeButton') {
                    if ($null -ne $closed) { Resume-ClosedSession -Entry $closed }
                } elseif ($null -ne $kept) {
                    if ($sender.Name -eq 'KillButton') { Stop-KeptSession -Kept $kept } else { Disconnect-KeptSession -Kept $kept }
                } elseif ($sender.Name -eq 'KillButton') {
                    Stop-LocalSession -Element $row.Element
                } elseif ($sender.Name -eq 'CloseButton') {
                    Close-LocalSession -Element $row.Element
                }
            } catch { Write-ErrorLog -Where 'rowbutton' -Problem $_ }
        })
    }

    $element.Tag = $Handle
    $rec.Spinner.RenderTransform = $script:spinTurn
    $rec.HelperRing.RenderTransform = $script:spinTurn
    if (Get-RowSound -Key ([string][int64]$Handle)) { $rec.SoundMark.Visibility = 'Visible' }

    # Right click opens the row's menu: bring to front, maximize, and the sound
    # this session plays when it needs you. The sound is per row, so several
    # sessions can each have their own and be told apart by ear.
    $element.Add_MouseRightButtonUp({
        param($sender, $e)
        try { Show-RowMenu -Element $sender } catch { Write-ErrorLog -Where 'rowmenu' -Problem $_ }
        $e.Handled = $true
    })

    # Press on a row is ambiguous: it starts either a click that focuses the
    # session, or a drag that moves the row within its group. Deciding once the
    # pointer moves, not on press, is what keeps rows clickable. Handled stops
    # the press bubbling to the card's own drag, which moves the whole window.
    $element.Add_MouseLeftButtonDown({
        param($sender, $e)
        $script:pressPoint = $e.GetPosition($window)
        # Kept in canvas coordinates too, so a drag that starts four pixels
        # later grabs the row where the press landed, without a jump.
        $script:pressCanvasY = $e.GetPosition($rowCanvas).Y
        $script:pressRow = $sender
        # The second press of a double-click. The first press notes where the
        # window is, before its own click's focus can restore a minimized one,
        # so a double-click remembers the window as it really was.
        $script:pressDouble = ($e.ClickCount -eq 2)
        if ($e.ClickCount -eq 1) {
            try {
                $script:pressSpot = @{ Handle = [IntPtr]$sender.Tag; Spot = [TlNative]::GetSpot([IntPtr]$sender.Tag) }
            } catch { Write-ErrorLog -Where 'maximize' -Problem $_ }
        }
        $e.Handled = $true
    })

    # Release either drops a dragged row or, if the pointer never went far
    # enough to start a drag, is a click that focuses the session's window, or
    # the end of a double-click that maximizes it or puts it back.
    # Focus is best effort by design: if Windows refuses the foreground change
    # the native helper flashes the taskbar button instead.
    $element.Add_MouseLeftButtonUp({
        param($sender, $e)
        if ($null -ne $script:drag) {
            try { Complete-RowDrag -Commit $true } catch { Write-ErrorLog -Where 'drop' -Problem $_ }
        } elseif ($script:pressRow -eq $sender -and $script:pressDouble) {
            try { Switch-RowMaximized -Handle ([IntPtr]$sender.Tag) } catch { Write-ErrorLog -Where 'maximize' -Problem $_ }
        } elseif ($script:pressRow -eq $sender -and (Get-RowClosed -Element $sender)) {
            # A closed session of this PC: the click resumes it in a new window.
            try { Resume-ClosedSession -Entry (Get-RowClosed -Element $sender) } catch { Write-ErrorLog -Where 'resume' -Problem $_ }
        } elseif ($script:pressRow -eq $sender -and (Get-RowKept -Element $sender)) {
            # A kept session with no window here: the click opens one.
            try { Open-KeptSession -Kept (Get-RowKept -Element $sender) } catch { Write-ErrorLog -Where 'reopen' -Problem $_ }
        } elseif ($script:pressRow -eq $sender) {
            [TlNative]::Focus([IntPtr]$sender.Tag) | Out-Null
            # An incoming remote row has no window to bring forward, which is
            # what normally clears its blue dot, so the click itself counts as
            # having looked.
            $watch = $script:needWatch[[string][int64]$sender.Tag]
            if ([int64]$sender.Tag -lt 0 -and $null -ne $watch) { $watch.Opened = $watch.Need }
        }
        $script:pressRow = $null
        $script:pressDouble = $false
        $e.Handled = $true
    })

    # Capture can be taken away mid-drag, by Alt+Tab or a window stealing the
    # focus. The drag is abandoned rather than dropped, so the row goes back
    # where it was instead of landing wherever the pointer happened to be.
    $element.Add_LostMouseCapture({
        param($sender, $e)
        if ($null -ne $script:drag -and [object]::ReferenceEquals($script:drag.Rec.Element, $sender)) {
            try { Complete-RowDrag -Commit $false } catch { Write-ErrorLog -Where 'drag' -Problem $_ }
        }
    })

    $rowCanvas.Children.Add($element) | Out-Null
    return $rec
}

# Unity editor rows, keyed by the editor's process id. Kept apart from $rows on
# purpose: they have no session state, no tray colour and no drag order, and
# every function that walks $rows would otherwise have to learn to skip them.
$script:unityRows = @{}

# Creates, updates and removes the Unity rows from the last sweep's editors.
# Runs on the slow timer, right after the sweep that collected them.
function Sync-UnityRows {
    $seen = @{}
    foreach ($editor in @($script:unityEditors)) {
        $key = [string]$editor.Id
        $seen[$key] = $true
        if (-not $script:unityRows.ContainsKey($key)) {
            $element = Import-Xaml 'UnityRow.xaml'
            $rec = @{
                Element = $element
                Stripe  = $element.FindName('Stripe')
                Label   = $element.FindName('Label')
                Detail  = $element.FindName('Detail')
                Memory  = $element.FindName('Memory')
                Cpu     = $element.FindName('Cpu')
                Window  = [IntPtr]::Zero
                SortKey = ''
                ProjectPath = $editor.ProjectPath
                Headless    = $editor.Headless
            }

            # Right click opens the row's menu, which sets the editor's CPU limit.
            $element.Add_MouseRightButtonUp({
                param($sender, $e)
                try { Show-UnityRowMenu -Element $sender } catch { Write-ErrorLog -Where 'unitymenu' -Problem $_ }
                $e.Handled = $true
            })

            # A click brings an editor with a window to the front, like an agent
            # row. A headless row has no window to bring, so its press is left to
            # bubble up and drag the card, as the card's empty edge does.
            $element.Add_MouseLeftButtonDown({
                param($sender, $e)
                if ([IntPtr]$sender.Tag -ne [IntPtr]::Zero) { $e.Handled = $true }
            })
            $element.Add_MouseLeftButtonUp({
                param($sender, $e)
                if ([IntPtr]$sender.Tag -ne [IntPtr]::Zero) {
                    [TlNative]::Focus([IntPtr]$sender.Tag) | Out-Null
                    $e.Handled = $true
                }
            })

            $rowCanvas.Children.Add($element) | Out-Null
            $script:unityRows[$key] = $rec
        }

        $rec = $script:unityRows[$key]
        $rec.Window = $editor.Window
        $rec.Element.Tag = $editor.Window
        if ($editor.Window -ne [IntPtr]::Zero) {
            $rec.Element.Cursor = [System.Windows.Input.Cursors]::Hand
        } else {
            $rec.Element.Cursor = [System.Windows.Input.Cursors]::Arrow
        }
        # Headless first, then by project, so the editors with no window to find
        # are the ones at the top of the group.
        $rec.SortKey = '{0}|{1}' -f $(if ($editor.Headless) { '0' } else { '1' }), $editor.Project
        if ($editor.Headless) { $rec.Stripe.Background = $brush.Headless } else { $rec.Stripe.Background = $brush.UnityEditor }

        $rec.Label.Text = $editor.Project
        $detail = $(if ($editor.Headless) { 'headless' } else { 'editor' })
        # The limit shows only once the editor is really in its job, so a limit
        # that failed to apply never reads as one that holds.
        $cap = $script:unityJobs[$editor.Id]
        if ($null -ne $cap -and $cap.Capped -and $cap.Percent -gt 0) { $detail += $listSep + ('max {0} %' -f $cap.Percent) }
        if ($editor.Branch) { $detail += $listSep + $editor.Branch }
        if ($editor.Workers -gt 0) { $detail += $listSep + ('{0} importing' -f $editor.Workers) }
        $rec.Detail.Text = $detail
        $rec.Memory.Text = '{0:0.0} GB' -f $editor.MemoryGB
        $rec.Cpu.Text = '{0:0.0} % cpu' -f $editor.CpuPercent
    }

    foreach ($key in @($script:unityRows.Keys)) {
        if (-not $seen.ContainsKey($key)) {
            $rowCanvas.Children.Remove($script:unityRows[$key].Element)
            $script:unityRows.Remove($key)
        }
    }
}

function Get-CpuLimitName {
    param([int]$Percent)
    if ($Percent -gt 0) { return ('{0} %' -f $Percent) }
    return 'No limit'
}

# The menu of a Unity row: the most CPU the editor and its import workers may
# use together, as a share of the whole machine. Built like a row's Sound entry:
# Default, naming what the default is for this kind of editor, then each limit,
# with a tick on the one chosen now.
function Show-UnityRowMenu {
    param($Element)
    $rec = $null
    foreach ($candidate in $script:unityRows.Values) {
        if ([object]::ReferenceEquals($candidate.Element, $Element)) { $rec = $candidate }
    }
    if ($null -eq $rec) { return }
    $key = $rec.ProjectPath.ToLowerInvariant()
    $own = $script:settings.CpuLimits.ContainsKey($key)
    $defaultPercent = $(if ($rec.Headless) { $unityCpuLimitDefault } else { 0 })

    $menu = New-CardMenu
    $limit = New-CardMenuItem -Header 'CPU limit'
    $default = Add-CardMenuAction -Parent $limit -Header ('Default (' + (Get-CpuLimitName $defaultPercent) + ')') `
                                  -Arg $key -Where 'unitymenu' -Action {
        param($Key)
        Set-UnityCpuLimit -Key $Key -FollowDefault
    }
    $default.IsChecked = (-not $own)
    [void]$limit.Items.Add((New-CardMenuSeparator))
    foreach ($choice in $unityCpuLimitChoices) {
        $item = Add-CardMenuAction -Parent $limit -Header (Get-CpuLimitName $choice) `
                                   -Arg @{ Key = $key; Percent = $choice } -Where 'unitymenu' -Action {
            param($Pick)
            Set-UnityCpuLimit -Key $Pick.Key -Percent $Pick.Percent
        }
        $item.IsChecked = ($own -and $choice -eq [int]$script:settings.CpuLimits[$key])
    }
    [void]$menu.Items.Add($limit)

    $menu.PlacementTarget = $Element
    $menu.IsOpen = $true
}

# Saves a project's limit and applies it at once, rather than on the next sweep,
# so the row's detail line shows the new limit as the menu closes.
function Set-UnityCpuLimit {
    param([string]$Key, [int]$Percent, [switch]$FollowDefault)
    if ($FollowDefault) {
        $script:settings.CpuLimits.Remove($Key)
    } else {
        $script:settings.CpuLimits[$Key] = $Percent
    }
    Save-Settings
    Update-UnityRows
}

function Set-RowState {
    param($Rec, [string]$State, [string]$Label, [string]$Detail = '')

    if ($Rec.Label -ne $Label) {
        $Rec.LabelText.Text = $Label
        $Rec.Label = $Label
    }
    # Before the early return below, like the label: Marshal's question can
    # change between rounds while its row stays Blocked throughout.
    if ($Rec.Detail -ne $Detail) {
        $Rec.DetailText.Text = $Detail
        $Rec.DetailText.Visibility = $(if ($Detail) { 'Visible' } else { 'Collapsed' })
        $Rec.Detail = $Detail
    }
    if ($Rec.State -eq $State) { return }

    $now = Get-Date

    # The row's sound and its blue dot are not decided here but in Update-Needs,
    # after every row is applied, so that they survive the row being rebuilt.

    # Waiting on its own helpers or timer is still the same piece of work, so
    # going between that and Working keeps the clock running from where it was.
    $busy = @('Working', 'OwnWork')
    if ($busy -contains $State) {
        if (-not ($busy -contains $Rec.State -and $null -ne $Rec.WorkSince)) {
            $Rec.WorkSince = Get-WholeSecond -At $now
            $Rec.FinishedAt = $null
        }
    } elseif ($null -ne $Rec.WorkSince) {
        # Left the working state, so note the clock time it stopped. Guarded on
        # WorkSince so that Waiting turning into Blocked, or back, keeps the
        # original time instead of moving it.
        $Rec.FinishedAt = $now
        $Rec.WorkSince = $null
    }

    $Rec.State = $State
    $Rec.Since = $now

    Set-RowLook -Rec $Rec
}

# Paints a row for the state it is in: fill, outline, text colours, ring and
# alarm. Kept apart from Set-RowState so a switch of preset can paint every row
# again without touching its timers or its state.
function Set-RowLook {
    param($Rec)

    # Stop whatever motion the previous state was running before starting the
    # next one, or the two animations fight over the same property.
    if ($Rec.Alarm) { $Rec.Alarm.Stop(); $Rec.Alarm = $null }
    $Rec.Bg.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)

    switch ($Rec.State) {
        'Working' {
            $Rec.Bg.Background        = $brush.RowBase
            $Rec.Bg.BorderBrush       = $brush.RowEdge
            $Rec.LabelText.Foreground = $brush.Text
            $Rec.TimerText.Foreground = $brush.TextDim
            # The only thing that moves on a calm card. Every ring turns with
            # the one shared rotation, so all of them are in step.
            $Rec.Spinner.Visibility   = 'Visible'
            $Rec.Bg.Opacity           = 1.0
        }
        # Its turn is over, but it waits on helpers it started or on a timer it
        # set, not on you: the working row, with no small ring, since Claude
        # itself is not working. Update-HelperMarks shows the larger ring
        # standing still in its place. It turns green once nothing is left.
        'OwnWork' {
            Start-FillAnimation -Rec $Rec -To $brush.RowBase.Color
            $Rec.Bg.BorderBrush       = $brush.RowEdge
            $Rec.LabelText.Foreground = $brush.Text
            $Rec.TimerText.Foreground = $brush.TextDim
            $Rec.Spinner.Visibility   = 'Collapsed'
            $Rec.Bg.Opacity           = 1.0
        }
        'Waiting' {
            Start-FillAnimation -Rec $Rec -To $brush.Waiting.Color
            $Rec.Bg.BorderBrush       = $brush.RowEdgeOnWait
            $Rec.LabelText.Foreground = $brush.TextOnWait
            $Rec.TimerText.Foreground = $brush.TimerOnWait
            $Rec.Spinner.Visibility   = 'Collapsed'
            # Still, not breathing. A filled row is already loud; pulsing every
            # finished session would make the alarm state indistinguishable.
            $Rec.Bg.Opacity           = 1.0
        }
        'Blocked' {
            Start-FillAnimation -Rec $Rec -To $brush.Blocked.Color
            $Rec.Bg.BorderBrush       = $brush.RowEdgeOnBlock
            $Rec.LabelText.Foreground = $brush.TextOnBlock
            $Rec.TimerText.Foreground = $brush.TimerOnBlock
            $Rec.Spinner.Visibility   = 'Collapsed'
            Start-Alarm -Rec $Rec
        }
        # Marshal between rounds, with nothing for you. It is idle in exactly
        # the way a finished session is, but it will start again by itself in
        # a few minutes, so the green fill and the blue dot would claim your
        # attention almost all day for nothing. It goes back to the plain dark
        # row instead, with no ring, because nothing is running, and no dot,
        # because nothing is wanted. The label is dimmed so the row sits a step
        # quieter than a working one; the time on the right is its last round.
        'Watching' {
            Start-FillAnimation -Rec $Rec -To $brush.RowBase.Color
            $Rec.Bg.BorderBrush       = $brush.RowEdge
            $Rec.LabelText.Foreground = $brush.TextDim
            $Rec.TimerText.Foreground = $brush.TextDim
            $Rec.Spinner.Visibility   = 'Collapsed'
            $Rec.Bg.Opacity           = 1.0
        }
    }
    # The dot shows on finished and blocked rows. A preset may fill a blocked
    # row with the dot's own colour, so that row gets a dot of its own.
    $Rec.Dot.Fill = $(if ($Rec.State -eq 'Blocked') { $brush.DotOnBlock } else { $brush.Working })
    # The note takes the timer's colour, which each state already picks to read
    # on its own fill.
    $Rec.SoundMark.Foreground = $Rec.TimerText.Foreground
    # The helpers' ring takes the ring colour on the working glass, like the
    # small ring, and the timer's colour on a filled row; the number inside
    # takes the label's, to be read at a glance.
    $Rec.HelperRing.Stroke = $(if ($Rec.State -eq 'Working' -or $Rec.State -eq 'OwnWork') { $brush.Ring } else { $Rec.TimerText.Foreground })
    $Rec.HelperCount.Foreground = $Rec.LabelText.Foreground
    # The detail takes the label's colour, not the timer's. On a blocked row it
    # carries Marshal's question, the one line there meant to be read rather
    # than glanced at, and the timer's pulled-back amber measured about 2.6 to 1
    # against the fill, too faint at this size. Size and weight already mark it
    # as the lesser line.
    $Rec.DetailText.Foreground = $Rec.LabelText.Foreground
}

# Menus built in code take the card's dark styles from the window's resources
# explicitly: a context menu opens in a popup of its own, outside the window's
# tree, so neither the styles nor the presets they read would reach it by
# lookup. The menu is handed the window's presets as they are when it opens,
# and its submenus find them through it.
function New-CardMenu {
    $menu = New-Object System.Windows.Controls.ContextMenu
    foreach ($dict in $window.Resources.MergedDictionaries) { [void]$menu.Resources.MergedDictionaries.Add($dict) }
    $menu.Style = $window.FindResource('CardMenu')
    return $menu
}

function New-CardMenuItem {
    param([string]$Header)
    $item = New-Object System.Windows.Controls.MenuItem
    $item.Style = $window.FindResource('CardMenuItem')
    $item.Header = $Header
    return $item
}

function New-CardMenuSeparator {
    $separator = New-Object System.Windows.Controls.Separator
    $separator.Style = $window.FindResource('CardMenuSeparator')
    return $separator
}

# One clickable entry in a menu or a submenu, added to Parent and returned. The
# action is called with Arg, which rides on the item because a handler
# scriptblock does not capture the variables around it. Where names the action
# in the error log.
function Add-CardMenuAction {
    param($Parent, [string]$Header, [scriptblock]$Action, $Arg = $null, [string]$Where = 'menu')
    $item = New-CardMenuItem -Header $Header
    $item.Tag = @{ Action = $Action; Arg = $Arg; Where = $Where }
    $item.Add_Click({
        param($sender, $e)
        try { & $sender.Tag.Action $sender.Tag.Arg } catch { Write-ErrorLog -Where $sender.Tag.Where -Problem $_ }
    })
    [void]$Parent.Items.Add($item)
    return $item
}

# The right-click menu of an agent row: a short list of actions on its session,
# with Sound opening a submenu on hover. Each top-level entry is one
# Add-CardMenuAction, or one submenu built like New-RowSoundMenu, so another
# action is one more entry here.
function Show-RowMenu {
    param($Element)
    $handle = [IntPtr]$Element.Tag
    $menu = New-CardMenu
    $hasWindow = ([int64]$handle -gt 0)

    # A session that outlives its window: open it again, let go of it while it
    # keeps running, or end it where it runs. Each says what happens to Claude,
    # since closing a window no longer means stopping it.
    $reopen = Get-RowKept -Element $Element
    $kept = Get-RowEndable -Element $Element
    if ($null -ne $reopen) {
        $header = $(if ($reopen.Problem -eq 'signin') { 'Sign in to Tailscale in a new window' }
                    elseif ($reopen.Problem) { 'Try to reach it again' }
                    else { 'Reconnect: open it in a new window' })
        Add-CardMenuAction -Parent $menu -Header $header -Arg $reopen -Where 'reopen' -Action {
            param($Kept)
            Open-KeptSession -Kept $Kept
        } | Out-Null
    }
    if ($null -ne $kept) {
        $where = Get-KeptPlaceLong -Place $kept.Place
        if ($hasWindow) {
            Add-CardMenuAction -Parent $menu -Header "Disconnect: close this window, Claude keeps running on $where" -Arg $kept -Where 'disconnect' -Action {
                param($Kept)
                Disconnect-KeptSession -Kept $Kept
            } | Out-Null
        }
        Add-CardMenuAction -Parent $menu -Header "Kill: stop Claude on $where" -Arg $kept -Where 'end' -Action {
            param($Kept)
            Stop-KeptSession -Kept $Kept
        } | Out-Null
    }
    # A session of this PC: close its window and keep it here to resume, or
    # end it. A closed one: resume it, or take it off the card.
    $closed = Get-RowClosed -Element $Element
    $local = Get-RowLocal -Element $Element
    if ($null -ne $closed) {
        Add-CardMenuAction -Parent $menu -Header 'Resume: open it again in a new window' -Arg $closed -Where 'resume' -Action {
            param($Entry)
            Resume-ClosedSession -Entry $Entry
        } | Out-Null
    }
    if ($null -ne $local) {
        Add-CardMenuAction -Parent $menu -Header 'Close: close this window, keep the session here to resume' -Arg $Element -Where 'close' -Action {
            param($Row)
            Close-LocalSession -Element $Row
        } | Out-Null
    }
    if ($null -ne $closed -or $null -ne $local) {
        $killHeader = $(if ($null -ne $closed) { 'Kill: take it off the card' } else { 'Kill: end this session and take it off the card' })
        Add-CardMenuAction -Parent $menu -Header $killHeader -Arg $Element -Where 'end' -Action {
            param($Row)
            Stop-LocalSession -Element $Row
        } | Out-Null
    }
    if ($null -ne $reopen -or $null -ne $kept -or $null -ne $closed -or $null -ne $local) {
        [void]$menu.Items.Add((New-CardMenuSeparator))
    }

    # Window actions, for a row that has a window here to act on.
    if ($hasWindow) {
        Add-CardMenuAction -Parent $menu -Header 'Bring to front' -Arg $handle -Where 'rowmenu' -Action {
            param($Handle)
            [TlNative]::Focus($Handle) | Out-Null
        } | Out-Null

        # The same as a double-click on the row, so it says which way it will go.
        $isMaximized = ($null -ne $script:maximized -and $script:maximized.Handle -eq $handle -and
                        [TlNative]::IsMaximizedOnPrimary($handle))
        $maxHeader = $(if ($isMaximized) { 'Put window back' } else { 'Maximize window' })
        Add-CardMenuAction -Parent $menu -Header $maxHeader -Arg $handle -Where 'maximize' -Action {
            param($Handle)
            # No double-click led here, so the window is noted as it is now rather
            # than as some earlier press on the row found it.
            $script:pressSpot = $null
            Switch-RowMaximized -Handle $Handle
        } | Out-Null

        [void]$menu.Items.Add((New-CardMenuSeparator))
    }
    [void]$menu.Items.Add((New-RowSoundMenu -Key ([string][int64]$handle)))

    $menu.PlacementTarget = $Element
    $menu.IsOpen = $true
}

# The sound a window's session plays when it needs you: its own choice, Off
# included, or else the default. '' is no sound.
function Get-RowSound {
    param([string]$Key)
    if ($script:settings.Sounds.ContainsKey($Key)) { return $script:settings.Sounds[$Key] }
    return $script:settings.DefaultSound
}

# The note on every row, after a row's choice or the default has changed. A
# closed row has none, since nothing there can need you.
function Update-SoundMarks {
    foreach ($rec in $rows.Values) {
        $mark = $(if (-not $rec.Closed -and (Get-RowSound -Key ([string][int64]$rec.Handle))) { 'Visible' } else { 'Collapsed' })
        if ($rec.SoundMark.Visibility -ne $mark) { $rec.SoundMark.Visibility = $mark }
    }
}

function Get-SoundName {
    param([string]$Sound)
    if ($Sound) { return $Sound }
    return 'Off'
}

# The Sound entry of a row's menu: Default, naming what the default is now, then
# Off and every sound, with a tick on the one chosen now. Picking plays the
# sound once, so the choice is heard.
function New-RowSoundMenu {
    param([string]$Key)
    $own = $script:settings.Sounds.ContainsKey($Key)

    $sound = New-CardMenuItem -Header 'Sound'
    $default = Add-CardMenuAction -Parent $sound -Header ('Default (' + (Get-SoundName $script:settings.DefaultSound) + ')') `
                                  -Arg $Key -Where 'rowmenu' -Action {
        param($Key)
        Set-RowSound -Key $Key -FollowDefault
    }
    $default.IsChecked = (-not $own)
    [void]$sound.Items.Add((New-CardMenuSeparator))

    foreach ($choice in @('') + @($soundChoices)) {
        $item = Add-CardMenuAction -Parent $sound -Header (Get-SoundName $choice) `
                                   -Arg @{ Key = $Key; Sound = $choice } -Where 'rowmenu' -Action {
            param($Pick)
            Set-RowSound -Key $Pick.Key -Sound $Pick.Sound
        }
        $item.IsChecked = ($own -and $choice -eq $script:settings.Sounds[$Key])
    }
    return $sound
}

function Set-RowSound {
    param([string]$Key, [string]$Sound, [switch]$FollowDefault)
    if ($FollowDefault) {
        $script:settings.Sounds.Remove($Key)
    } else {
        $script:settings.Sounds[$Key] = $Sound
    }
    Save-Settings
    Invoke-Sound -Name (Get-RowSound -Key $Key)
    Update-SoundMarks
}

# The Default sound entry of the card's menu, built like a row's Sound entry
# without its Default line.
function New-DefaultSoundMenu {
    $sound = New-CardMenuItem -Header 'Default sound'
    foreach ($choice in @('') + @($soundChoices)) {
        $item = Add-CardMenuAction -Parent $sound -Header (Get-SoundName $choice) -Arg $choice -Where 'settings' -Action {
            param($Sound)
            $script:settings.DefaultSound = $Sound
            Save-Settings
            Invoke-Sound -Name $Sound
            Update-SoundMarks
        }
        $item.IsChecked = ($choice -eq $script:settings.DefaultSound)
    }
    return $sound
}

# Lays a preset over Classic and repaints the card with it. Rows are not
# rebuilt: what the templates bind follows by itself, and what the script set
# in code is set again. Loaded first, so a preset that fails to load leaves the
# card as it was.
function Set-Preset {
    param([string]$Name)
    $dict = Import-Preset -Name $Name
    Use-PresetLayer -Dict $dict
    $script:preset = $Name
    Read-StyleValues
    foreach ($rec in $rows.Values) { if ($rec.State) { Set-RowLook -Rec $rec } }
    Update-HelperMarks -Ordered @($rows.Values)
    Sync-UnityRows
    Update-Layout
    $script:settings.Preset = $Name
    Save-Settings
}

# The Style entry of the card's menu: every preset, with a tick on the one in use.
function New-StyleMenu {
    $style = New-CardMenuItem -Header 'Style'
    foreach ($name in @(Get-PresetNames)) {
        $item = Add-CardMenuAction -Parent $style -Header $name -Arg $name -Where 'style' -Action {
            param($Name)
            Set-Preset -Name $Name
        }
        $item.IsChecked = ($name -eq $script:preset)
    }
    return $style
}

# Double-clicking a row maximizes its session's window on the primary display,
# and double-clicking it again puts the window back exactly where it was. Only
# one window is maximized this way at a time, so maximizing another first puts
# the previous one back. A window that has closed, or was moved by hand since,
# is left where it is, and the double-click simply maximizes.
#
# The window and its snapshot, @{ Handle; Spot }, or null. Kept only for as long
# as the card runs.
$script:maximized = $null

function Switch-RowMaximized {
    param([IntPtr]$Handle)
    $previous = $script:maximized
    $script:maximized = $null
    if ($null -ne $previous -and [TlNative]::IsMaximizedOnPrimary($previous.Handle)) {
        [TlNative]::RestoreSpot($previous.Handle, $previous.Spot) | Out-Null
        if ($previous.Handle -eq $Handle) { return }
    }

    # Taken by the double-click's first press. Taken now only if that press
    # was on another row, which a row sliding between the two clicks can do.
    $spot = $null
    if ($null -ne $script:pressSpot -and $script:pressSpot.Handle -eq $Handle) { $spot = $script:pressSpot.Spot }
    if ($null -eq $spot) { $spot = [TlNative]::GetSpot($Handle) }
    if ($null -eq $spot) { return }
    if ([TlNative]::MaximizeOnPrimary($Handle)) {
        $script:maximized = @{ Handle = $Handle; Spot = $spot }
    }
}

# What a session wanting you shows and sounds like, run on every poll after the
# states are applied: the row's sound, and its blue dot.
#
# The sound plays every time a session starts needing you: the row turns
# Waiting or Blocked from anything else. Once per need, however long the need
# lasts, and playing never uses the choice up; it stays until Off is picked.
# The title is the main agent's own: it keeps its working glyph while subagents
# run and return, so their endings never count, which is exactly what the old
# Notification-hook chime could not tell apart. Waiting turning into Blocked, or
# back, is the same need seen twice and stays silent. Marshal Watching between
# rounds does not need you, so a question reaching it there is a new need. A
# Marshal round, though, neither starts a need nor ends one: a question still
# open when the round ends is the same need, not a new one every round. A need
# must outlast the settle time before its sound plays, so a title that flickers
# between tools stays silent.
#
# The dot marks a need you have not opened yet, so the dots left are the
# sessions still to handle. Opening is the session's terminal window coming to
# the front by any route: a click on the row, Alt+Tab, the taskbar, or simply
# being in front already when the session stops. That clears the dot and only
# the dot; the row keeps its colour. It comes back with the next need: the
# session finishing again, or asking something new, which includes a finished
# session turning Blocked on a question. Each need gets a number, and the dot
# shows while the number last opened is behind it.
#
# All of this is kept here by window handle rather than on the row. A row drops
# off the card for a poll whenever something else writes its window's title,
# and the row built when it comes back starts with no state, so a stop landing
# in between used to go unheard. A window this run of the card has not seen yet
# only sets the baseline: starting the card does not sound every session
# already waiting, but does show their dots, since the card cannot know which
# of them were handled before it started.
$script:needWatch = @{}

function Update-Needs {
    param($Ordered)
    $now = Get-Date
    $front = [int64][TlNative]::GetForegroundWindow()
    foreach ($rec in $Ordered) {
        $key = [string][int64]$rec.Handle
        $needs = ($rec.State -eq 'Waiting' -or $rec.State -eq 'Blocked')
        $watch = $script:needWatch[$key]
        if ($null -eq $watch) {
            $watch = @{ Needs = $needs; State = $rec.State; DueAt = $null; Need = 1; Opened = 0 }
            $script:needWatch[$key] = $watch
        } else {
            if ($rec.State -eq 'Working' -and (Test-MarshalRow -Cwd $rec.Cwd -Label $rec.Label)) { $needs = $watch.Needs }
            $isNew = ($needs -and -not $watch.Needs)

            if (-not $needs) {
                $watch.DueAt = $null
            } elseif ($isNew) {
                $watch.DueAt = $now.AddMilliseconds($soundSettleMs)
            }
            if ($isNew -or ($rec.State -eq 'Blocked' -and $watch.State -eq 'Waiting')) { $watch.Need++ }
            $watch.Needs = $needs
            $watch.State = $rec.State

            if ($null -ne $watch.DueAt -and $now -ge $watch.DueAt) {
                $watch.DueAt = $null
                Invoke-Sound -Name (Get-RowSound -Key $key)
            }
        }

        if ([int64]$rec.Handle -eq $front) { $watch.Opened = $watch.Need }
        $dot = $(if ($needs -and $rec.State -ne 'Working' -and $watch.Opened -ne $watch.Need) { 'Visible' } else { 'Collapsed' })
        if ($rec.Dot.Visibility -ne $dot) { $rec.Dot.Visibility = $dot }
    }
}

# The mark left of the label, run on every poll after Update-Needs has set the
# dot. A session with helper agents running shows the larger ring with their
# number inside, in place of the small ring on a working row and of the dot on
# a finished one: its helpers are still busy, so the session is too. The
# dot's need is kept and shows again once the helpers end. Without helpers the
# small ring shows on a working row only, as before.
#
# The larger ring turns only while Claude itself works. While it waits on its
# helpers, its background commands or its timer the ring closes and stands
# still, so motion on the card still means only that Claude is busy. The number
# counts helpers only: Claude marks that commands run, not how many.
$script:ringOpen = [System.Windows.Media.Geometry]::Parse('M 8,1 A 7,7 0 1 1 1,8')
$script:ringOpen.Freeze()
$script:ringClosed = New-Object System.Windows.Media.EllipseGeometry ((New-Object System.Windows.Point 8, 8), 7, 7)
$script:ringClosed.Freeze()

function Update-HelperMarks {
    param($Ordered)
    foreach ($rec in $Ordered) {
        $helpers = ($rec.Helpers -gt 0)
        $turning = ($rec.State -eq 'Working')
        $turn = $(if ($turning) { $script:spinTurn } else { [System.Windows.Media.Transform]::Identity })
        if (-not [object]::ReferenceEquals($rec.HelperRing.RenderTransform, $turn)) { $rec.HelperRing.RenderTransform = $turn }
        $shape = $(if ($turning) { $script:ringOpen } else { $script:ringClosed })
        if (-not [object]::ReferenceEquals($rec.HelperRing.Data, $shape)) { $rec.HelperRing.Data = $shape }
        $mark = $(if ($helpers -or $rec.State -eq 'OwnWork') { 'Visible' } else { 'Collapsed' })
        if ($rec.HelperMark.Visibility -ne $mark) { $rec.HelperMark.Visibility = $mark }
        $count = $(if ($helpers) { [string]$rec.Helpers } else { '' })
        if ($rec.HelperCount.Text -ne $count) { $rec.HelperCount.Text = $count }
        $spin = $(if (-not $helpers -and $rec.State -eq 'Working') { 'Visible' } else { 'Collapsed' })
        if ($rec.Spinner.Visibility -ne $spin) { $rec.Spinner.Visibility = $spin }
        if ($helpers -and $rec.Dot.Visibility -ne 'Collapsed') { $rec.Dot.Visibility = 'Collapsed' }
    }
}

function Start-FillAnimation {
    param($Rec, $To)
    # Animate from whatever is there now, so a Waiting row promoted to Blocked
    # slides amber to vermilion instead of snapping.
    $from = [System.Windows.Media.Color]::FromArgb(0, 20, 22, 26)
    if ($Rec.Bg.Background -is [System.Windows.Media.SolidColorBrush]) {
        $from = $Rec.Bg.Background.Color
    }
    $solid = New-Object System.Windows.Media.SolidColorBrush $from
    $Rec.Bg.Background = $solid
    $anim = New-Object System.Windows.Media.Animation.ColorAnimation
    $anim.From = $from
    $anim.To = $To
    $anim.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds($flipMs)
    $solid.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $anim)
}

# Three hard beats, then a slow breathe that never stops. The beats are what
# catches the eye; the breathe is what stops the row from blending back into a
# static card while it waits.
function Start-Alarm {
    param($Rec)
    $beats = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $beats.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds($blinkMs * 3)
    $t = 0
    for ($i = 0; $i -lt 3; $i++) {
        $t += $blinkMs / 2
        $k1 = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(0.42, [System.Windows.Media.Animation.KeyTime][TimeSpan]::FromMilliseconds($t))
        $beats.KeyFrames.Add($k1) | Out-Null
        $t += $blinkMs / 2
        $k2 = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(1.0, [System.Windows.Media.Animation.KeyTime][TimeSpan]::FromMilliseconds($t))
        $beats.KeyFrames.Add($k2) | Out-Null
    }

    $breathe = New-Object System.Windows.Media.Animation.DoubleAnimation
    $breathe.From = 1.0
    $breathe.To = 0.78
    $breathe.BeginTime = [TimeSpan]::FromMilliseconds($blinkMs * 3)
    $breathe.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds($breatheMs)
    $breathe.AutoReverse = $true
    $breathe.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever

    $sb = New-Object System.Windows.Media.Animation.Storyboard
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($sb, $endlessFps)
    foreach ($a in @($beats, $breathe)) {
        [System.Windows.Media.Animation.Storyboard]::SetTarget($a, $Rec.Bg)
        [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($a, (New-Object System.Windows.PropertyPath '(UIElement.Opacity)'))
        $sb.Children.Add($a) | Out-Null
    }
    $sb.Begin()
    $Rec.Alarm = $sb
}

function Move-RowTo {
    param($Rec, [double]$Top)
    if ([Math]::Abs($Rec.Top - $Top) -lt 0.5) { return }
    $first = $Rec.Top -lt 0
    $Rec.Top = $Top
    # Slide from where the row is drawn right now, not from where it was last
    # sent. During a drag rows change slot faster than a slide finishes, and
    # starting from the old target made them jump back before moving.
    $from = [System.Windows.Controls.Canvas]::GetTop($Rec.Element)
    if ($first -or [double]::IsNaN($from)) {
        [System.Windows.Controls.Canvas]::SetTop($Rec.Element, $Top)
        return
    }
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = $from
    $anim.To = $Top
    $anim.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds($flipMs)
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = 'EaseOut'
    $anim.EasingFunction = $ease
    $Rec.Element.BeginAnimation([System.Windows.Controls.Canvas]::TopProperty, $anim)
}

function Format-Elapsed {
    param([TimeSpan]$Span)
    # Floor, never [int]: PowerShell's [int] rounds, which made 40 seconds read
    # as 1:40 and every minute show one too many for its second half.
    $hours = [Math]::Floor($Span.TotalHours)
    if ($hours -ge 1) { return ('{0}:{1:00}:{2:00}' -f $hours, $Span.Minutes, $Span.Seconds) }
    return ('{0}:{1:00}' -f [Math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

function Get-WholeSecond {
    param([datetime]$At)
    return $At.AddTicks(-($At.Ticks % [TimeSpan]::TicksPerSecond))
}

# Today's finish as "at 14:05". Older ones only need the day to judge their age,
# which also keeps the column narrow. Invariant culture because the rest of the
# card is English.
function Format-FinishedAt {
    param([datetime]$At, [datetime]$Now)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($At.Date -eq $Now.Date) { return 'at ' + $At.ToString('HH:mm', $inv) }
    if (($Now.Date - $At.Date).TotalDays -lt 7) { return $At.ToString('ddd', $inv) }
    return $At.ToString('d MMM', $inv)
}

# The right-hand column of every row, all written in one pass so every running
# timer turns over together. A working row counts up from the whole second its
# work started. Any other row shows the clock time it stopped, with "at" in
# front and in italics, so it can never be read as a running figure.
function Update-Timers {
    $now = Get-Date
    $second = Get-WholeSecond -At $now
    foreach ($rec in @($rows.Values)) {
        $text = ''
        $italic = $false
        if ($null -ne $rec.WorkSince) {
            $text = Format-Elapsed -Span ($second - $rec.WorkSince)
        } else {
            $stopped = $rec.FinishedAt
            # Marshal says itself when its last round ended, and that survives
            # a restart of the card, which the moment the card saw it stop does
            # not. Every other row has no RoundAt and carries on as before.
            if ($null -ne $rec.RoundAt) { $stopped = $rec.RoundAt }
            # The widget did not see this one finish, usually because it was
            # started afterwards. Claude's own session file still knows when it
            # went idle. Only idle counts: a busy status would give the time the
            # turn began, not when it ended.
            if ($null -eq $stopped -and $rec.SessionStatus -eq 'idle' -and $rec.StatusUpdatedAt -gt 0) {
                $stopped = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$rec.StatusUpdatedAt).LocalDateTime
            }
            if ($null -ne $stopped) {
                $text = Format-FinishedAt -At $stopped -Now $now
                $italic = $true
            }
            # A closed row's time is when it closed, and says so: it is the
            # row's only word that it is closed.
            if ($rec.Closed) {
                $text = $(if ($rec.Resuming) { 'resuming...' } elseif ($text) { 'closed ' + ($text -replace '^at ', '') } else { 'closed' })
            }
        }
        if ($rec.TimerText.Text -ne $text) { $rec.TimerText.Text = $text }
        if ($italic) {
            $rec.TimerText.FontStyle = [System.Windows.FontStyles]::Italic
        } else {
            $rec.TimerText.FontStyle = [System.Windows.FontStyles]::Normal
        }
    }
}

# ---------------------------------------------------------------------------
# Work clock: today's time with at least one session open, shown at the top of
# the card with today's first start and this week's total under the label. Kept
# in state/worktime.csv as one "yyyy-MM-dd,h:mm:ss,HH:mm" line per day, the last
# line being today; the third column is when the day's counting began. Weeks
# start on Monday.
# ---------------------------------------------------------------------------
$workClockFile = Join-Path $stateDir 'worktime.csv'
$workClockMaxStepSec = 5    # a longer gap between ticks is sleep, not work
$workClockSaveSec    = 30
$workClockSep = ' ' + [char]0x00B7 + ' '   # code point: the file is read as ANSI

function Format-WorkClock {
    param([double]$Seconds, [switch]$NoSeconds)
    $span = [TimeSpan]::FromSeconds([Math]::Floor($Seconds))
    if ($NoSeconds) { return ('{0}:{1:00}' -f [Math]::Floor($span.TotalHours), $span.Minutes) }
    return ('{0}:{1:00}:{2:00}' -f [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
}

# One line as @{ Date; Seconds; Start }, or $null if it does not parse.
function ConvertFrom-WorkLine {
    param([string]$Line)
    $parts = $Line.Split(',')
    if ($parts.Count -lt 2) { return $null }
    $hms = $parts[1].Split(':')
    if ($hms.Count -ne 3) { return $null }
    $start = $null
    if ($parts.Count -ge 3 -and $parts[2].Trim()) { $start = $parts[2].Trim() }
    return @{
        Date    = $parts[0]
        Seconds = [double]([int]$hms[0] * 3600 + [int]$hms[1] * 60 + [int]$hms[2])
        Start   = $start
    }
}

function Get-WorkLines {
    if (-not (Test-Path $workClockFile)) { return @() }
    return @(Get-Content $workClockFile | Where-Object { $_.Trim() })
}

# Today's figures from the last line, and this week's total before today, which
# only changes at midnight so it is summed once rather than every second.
function Read-WorkClock {
    $script:workDate = (Get-Date).Date
    $script:workSeconds = 0.0
    $script:workStart = $null
    $today = $script:workDate.ToString('yyyy-MM-dd')
    $monday = $script:workDate.AddDays(-(([int]$script:workDate.DayOfWeek + 6) % 7)).ToString('yyyy-MM-dd')
    $script:workWeekBefore = 0.0
    foreach ($l in Get-WorkLines) {
        $w = ConvertFrom-WorkLine -Line $l
        if ($null -eq $w) { continue }
        if ($w.Date -eq $today) {
            $script:workSeconds = $w.Seconds
            $script:workStart = $w.Start
        } elseif ($w.Date -ge $monday -and $w.Date -lt $today) {
            $script:workWeekBefore += $w.Seconds
        }
    }
}

# Rewrites today's line in place, or appends it on the first save of a day.
function Save-WorkClock {
    $day = $script:workDate.ToString('yyyy-MM-dd')
    $line = $day + ',' + (Format-WorkClock -Seconds $script:workSeconds)
    if ($script:workStart) { $line += ',' + $script:workStart }
    $lines = @(Get-WorkLines)
    if ($lines.Count -gt 0 -and $lines[-1].StartsWith($day + ',')) {
        $lines[-1] = $line
    } else {
        $lines += $line
    }
    [System.IO.File]::WriteAllLines($workClockFile, [string[]]$lines)
    $script:workSavedAt = Get-Date
}

# Called once a second from the clock timer.
function Update-WorkClock {
    $now = Get-Date
    $step = ($now - $script:workTickAt).TotalSeconds
    $script:workTickAt = $now
    if ($step -gt $workClockMaxStepSec) { $step = $workClockMaxStepSec }

    if ($now.Date -ne $script:workDate) {
        Save-WorkClock
        Read-WorkClock
    }
    if ($rows.Count -gt 0 -and $step -gt 0) {
        $script:workSeconds += $step
        if (-not $script:workStart) { $script:workStart = $now.ToString('HH:mm') }
    }

    $text = Format-WorkClock -Seconds $script:workSeconds
    if ($workClockText.Text -ne $text) { $workClockText.Text = $text }
    $sub = 'week ' + (Format-WorkClock -Seconds ($script:workWeekBefore + $script:workSeconds) -NoSeconds)
    if ($script:workStart) { $sub = 'since ' + $script:workStart + $workClockSep + $sub }
    if ($workClockSub.Text -ne $sub) { $workClockSub.Text = $sub }
    if (($now - $script:workSavedAt).TotalSeconds -ge $workClockSaveSec) { Save-WorkClock }
}

Read-WorkClock
$script:workTickAt = Get-Date
$script:workSavedAt = Get-Date

function Set-Spin {
    param([bool]$On)
    if ($On -eq $script:spinRunning) { return }
    $script:spinRunning = $On
    if ($On) {
        $script:spinTurn.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $script:spinAnimation)
    } else {
        $script:spinTurn.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
    }
}

# ---------------------------------------------------------------------------
# Dragging a row within its group. The order is remembered by window handle in
# state/row-order.json, so it survives a restart of the widget.
# ---------------------------------------------------------------------------

# Rows of one group in display order: dragged order first, then the rest by
# when their session started, which is the order a new session gets.
function Get-GroupOrder {
    param($Group)
    return @($Group | Sort-Object @{ Expression = {
                $i = $script:orderIndex[[string][int64]$_.Handle]
                if ($null -eq $i) { [int]::MaxValue } else { $i }
            } }, @{ Expression = { $_.StartedAt } }, @{ Expression = { $_.Seq } })
}

function Start-RowDrag {
    param($Element, [double]$PointerY)
    $rec = $rows[[string][int64]$Element.Tag]
    # A row whose session is not resolved yet sits in the unnamed group at the
    # bottom and moves into its real group once it resolves, so an order given
    # to it now would mean nothing. It stays put; the press just stops being a
    # click.
    if ($null -eq $rec -or $rec.Workspace -eq 'unknown') { return }

    $order = @($script:groupOrder[$rec.Workspace])
    $index = 0
    for ($i = 0; $i -lt $order.Count; $i++) {
        if ([object]::ReferenceEquals($order[$i], $rec)) { $index = $i }
    }

    # Pin the row where it is drawn right now, in case it was mid-slide.
    $top = [System.Windows.Controls.Canvas]::GetTop($Element)
    $Element.BeginAnimation([System.Windows.Controls.Canvas]::TopProperty, $null)
    [System.Windows.Controls.Canvas]::SetTop($Element, $top)
    $rec.Top = $top

    $script:drag = @{
        Rec    = $rec
        Group  = $rec.Workspace
        Offset = $script:pressCanvasY - $top
        Target = $index
        Order  = $order
    }
    [System.Windows.Controls.Panel]::SetZIndex($Element, 10)
    $Element.Effect = $script:liftShadow
    $Element.Cursor = [System.Windows.Input.Cursors]::SizeNS
    # Captured so the drag keeps tracking when the pointer leaves the row or
    # the card, and so the release comes back to this row wherever it happens.
    [void]$Element.CaptureMouse()
    Move-DraggedRow -PointerY $PointerY
}

function Move-DraggedRow {
    param([double]$PointerY)
    $drag = $script:drag
    if ($null -eq $drag) { return }
    $slots = $script:groupSlots[$drag.Group]
    if ($null -eq $slots) { return }
    # The group's other rows, in order, and the room they take. A closed row
    # is slimmer, so the slots are not all one height.
    $others = @($slots.Recs | Where-Object { -not [object]::ReferenceEquals($_, $drag.Rec) })
    $span = 0.0
    foreach ($other in $others) { $span += Get-RowPitch -Rec $other }
    $first = [double]$slots.Top
    $last = $first + $span
    # Held inside its own group: a session cannot be dropped among another
    # workspace's rows, so its row cannot travel past its group's ends either.
    $top = [Math]::Max($first, [Math]::Min($last, $PointerY - $drag.Offset))
    [System.Windows.Controls.Canvas]::SetTop($drag.Rec.Element, $top)
    $drag.Rec.Top = $top
    # It goes below every other row whose middle its own middle has passed.
    $middle = $top - $first + (Get-RowHeight -Rec $drag.Rec) / 2
    $target = 0
    $above = 0.0
    foreach ($other in $others) {
        $pitch = Get-RowPitch -Rec $other
        if ($above + $pitch / 2 -ge $middle) { break }
        $above += $pitch
        $target++
    }
    if ($target -ne $drag.Target) {
        $drag.Target = $target
        # Straight away, not on the next poll, so the gap opens under the row
        # as it arrives rather than up to 400 ms later.
        Update-Layout
    }
}

function Complete-RowDrag {
    param([bool]$Commit)
    $drag = $script:drag
    if ($null -eq $drag) { return }
    # Cleared before the capture is released: releasing raises
    # LostMouseCapture, whose handler must find no drag still running.
    $script:drag = $null
    $element = $drag.Rec.Element
    $element.Effect = $null
    $element.Cursor = [System.Windows.Input.Cursors]::Hand
    [System.Windows.Controls.Panel]::SetZIndex($element, 0)
    if ($element.IsMouseCaptured) { $element.ReleaseMouseCapture() }
    if ($Commit) {
        Save-UserOrder -GroupKeys @($drag.Order | ForEach-Object { [string][int64]$_.Handle })
    }
    # Slides the dropped row from under the pointer into its slot.
    Update-Layout
}

function Write-LayoutDump {
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add(('{0:o}  drag={1}  order={2}  preset={3}  pitch={4}  height={5}  live={6}  rows={7}  warn={8}' -f (Get-Date), ($null -ne $script:drag),
        ($script:userOrder -join ','), $script:preset, ($script:rowHeight + $rowGap), $window.Height,
        $script:liveSessionCount, $rows.Count, $warnText.Visibility))
    [void]$lines.Add(('usage  panel={0}  opacity={1}  {2}' -f $usagePanel.Visibility, $usagePanel.Opacity,
        (($usageBars | ForEach-Object { '{0}={1} {2} "{3}" "{4}"' -f $_.Field, $_.Row.Visibility, $_.Used.Width, $_.Pct.Text, $_.Reset.Text }) -join '  ')))
    foreach ($name in @($script:groupOrder.Keys)) {
        # The "+" and how far it sits from the end of the name, which it follows.
        $header = $script:groupNew[$name]
        if ($null -eq $header) {
            [void]$lines.Add("group $name  new=Collapsed")
        } else {
            $label = $header.Label
            $gap = $header.NewButton.TranslatePoint((New-Object System.Windows.Point 0, 0), $header.Element).X -
                ($label.TranslatePoint((New-Object System.Windows.Point 0, 0), $header.Element).X + $label.ActualWidth)
            [void]$lines.Add(('group {0}  new={1}  gap={2}  folder={3}' -f $name, $header.NewButton.Visibility, [Math]::Round($gap, 1), $header.NewButton.Tag))
        }
        foreach ($rec in @($script:groupOrder[$name])) {
            $drawn = [System.Windows.Controls.Canvas]::GetTop($rec.Element)
            [void]$lines.Add(('  top={0,-6} drawn={1,-6} started={2:HH:mm:ss} seq={3,-3} hwnd={4,-9} idx={5,-4} {6}  [{7}] {8}  opacity={9} click={10} kill={11} disconnect={13} close={15} buttons={16} tmux={12} helpers={14}' -f
                $rec.Top, [Math]::Round($drawn, 1),
                [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$rec.StartedAt).LocalDateTime,
                $rec.Seq, [int64]$rec.Handle, $script:orderIndex[[string][int64]$rec.Handle], $rec.Label,
                $rec.State, $rec.Detail, [Math]::Round($rec.Element.Opacity, 2), $rec.ClickAction,
                $rec.KillButton.Visibility, $rec.TmuxName, $rec.DisconnectButton.Visibility, $rec.Helpers,
                $rec.CloseButton.Visibility, $rec.RowButtons.Tag))
        }
    }
    Set-Content -Path (Join-Path $stateDir 'dump.txt') -Value $lines -Encoding UTF8
}

function Save-UserOrder {
    param([string[]]$GroupKeys)
    # Windows no longer on the card are dropped here, so the file only ever
    # holds what is open now instead of growing forever.
    $next = New-Object System.Collections.ArrayList
    foreach ($key in $script:userOrder) {
        if ($rows.ContainsKey($key) -and $GroupKeys -notcontains $key) { [void]$next.Add($key) }
    }
    foreach ($key in $GroupKeys) { [void]$next.Add($key) }
    $script:userOrder = $next
    Update-OrderIndex
    try {
        # -InputObject rather than the pipeline, so a list of one is still
        # written as a JSON array.
        ConvertTo-Json -InputObject @($next) | Set-Content -Path $orderFile -Encoding UTF8
    } catch { Write-ErrorLog -Where 'order' -Problem $_ }
}

# ---------------------------------------------------------------------------
# Markers written by the Notification hook. This is the only source for the
# third state: Claude's terminal title has no glyph for "blocked on you", so
# there is nothing to scrape.
#
# There is no direct link from a window handle to a session id, so the join is
# a ladder of decreasing certainty. It never guesses: an unresolved marker
# leaves the row amber rather than reddening the wrong session.
# ---------------------------------------------------------------------------
function Resolve-BlockedRows {
    param($Ordered)

    # Only the markers folder: sweeping all of state/ once deleted the saved
    # row order along with the stale markers.
    $files = @(Get-ChildItem (Join-Path $stateDir 'markers') -Filter '*.json' -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return @() }

    # Judged on the state the titles just reported, not on the state currently
    # painted, because this runs before anything is applied.
    $waiting = @($Ordered | Where-Object { $_.PendingState -eq 'Waiting' })

    # Nothing is waiting, so no permission prompt can still be open. Approving a
    # prompt does not fire UserPromptSubmit, so without this sweep an approved
    # prompt's marker would sit here until the user typed something.
    if ($waiting.Count -eq 0) {
        foreach ($f in $files) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
        return @()
    }

    # An exact join. The marker file is named after the session id, and every
    # row now knows its own session id through the process chain, so a marker
    # either belongs to a row or belongs to nothing.
    #
    # This replaced a ladder of console-title matching and time correlation.
    # None of that was ever needed once the window could be resolved properly.
    $blocked = @()
    foreach ($f in $files) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $hit = $waiting | Where-Object { $_.SessionId -eq $id } | Select-Object -First 1
        if ($hit) {
            $blocked += $hit
        } else {
            # Its session is not waiting, so whatever it was blocked on is
            # resolved. Approving a permission prompt does not submit a prompt,
            # so the clear hook alone would leave this behind.
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return $blocked
}

# ---------------------------------------------------------------------------
# Marshal, the long-running coordinator session. It runs a round every 15
# minutes and idles in between, so by its title alone it would sit green with a
# blue dot almost all day, asking for attention it does not want. Whether it
# wants you is something only Marshal knows, and it says so at the end of every
# round in state/marshal.json:
#
#   { "needsYou": bool, "open": int, "summary": string, "at": ISO 8601 time }
#
# Its row works as any other while a round runs. Between rounds it is Blocked
# only while that report says needsYou, with the summary under the label, and
# otherwise Watching: a quiet dark row that the tray leaves out.
# ---------------------------------------------------------------------------

# The row is found by the folder Marshal runs in, because that is an identity
# the card resolves exactly through the process chain, while the title is
# whatever Claude last wrote there. The folder is built from the profile rather
# than written out, so no user name is baked into the repository.
$marshalDir = (Join-Path $env:USERPROFILE 'Marshal').TrimEnd('\')
$marshalReportFile = Join-Path $stateDir 'marshal.json'
$script:marshalReport = $null
$script:marshalReportMtime = [int64]0

# True for the Marshal session's row. The window title "Marshal" counts only
# while the row has no folder yet, which is the first sweep or so of a new
# window, so an unrelated session that happens to carry that title is never
# mistaken for it once its folder is known.
function Test-MarshalRow {
    param([string]$Cwd, [string]$Label)
    if ($Cwd) {
        $folder = ($Cwd -replace '/', '\').TrimEnd('\')
        return [string]::Equals($folder, $marshalDir, [System.StringComparison]::OrdinalIgnoreCase)
    }
    return [string]::Equals(([string]$Label).Trim(), 'Marshal', [System.StringComparison]::OrdinalIgnoreCase)
}

# Marshal's last report, or $null when there is none. Parsed only when the file
# changes, so a Marshal between rounds costs a stat per poll.
#
# A file that does not parse is usually one caught halfway through being
# written. The last good report stands and the file's time is not remembered,
# so the next poll reads it again once the write has finished.
function Read-MarshalReport {
    param([string]$Path)
    $file = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $file) {
        $script:marshalReport = $null
        $script:marshalReportMtime = [int64]0
        return $null
    }
    $mtime = $file.LastWriteTimeUtc.Ticks
    if ($mtime -eq $script:marshalReportMtime) { return $script:marshalReport }

    try {
        $saved = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        return $script:marshalReport
    }

    # The round's own time, as Marshal wrote it. PowerShell 5.1 leaves an ISO
    # 8601 string as a string, and DateTimeOffset honours the offset in it, so
    # a "Z" time and a "+02:00" time both land on the same local clock.
    $at = $null
    try {
        if ($saved.at) {
            $at = [DateTimeOffset]::Parse([string]$saved.at, [System.Globalization.CultureInfo]::InvariantCulture,
                                          [System.Globalization.DateTimeStyles]::AssumeLocal).LocalDateTime
        }
    } catch { }
    if ($null -eq $at) { $at = $file.LastWriteTime }

    $open = 0
    try { $open = [int]$saved.open } catch { }

    $script:marshalReport = @{
        # -eq with the boolean on the right, so a "false" written as a string
        # reads as false; a plain [bool] cast would call any non-empty string
        # true and raise a question that was never asked.
        NeedsYou  = ($saved.needsYou -eq $true)
        Open      = $open
        # One line on the row, however Marshal broke it up.
        Summary   = (([string]$saved.summary) -replace '\s+', ' ').Trim()
        At        = $at
        # When the file was last written, which is what says Marshal is alive.
        # Judged on this rather than on "at", so a Marshal writing its time in
        # the wrong zone shows a wrong clock but is never called dead for it.
        WrittenAt = $file.LastWriteTime
    }
    $script:marshalReportMtime = $mtime
    return $script:marshalReport
}

# What the Marshal row shows, from the state its title gives and its last
# report: @{ State; Detail; RoundAt }. Kept free of the window and the row so
# the decision can be checked on its own against sample reports.
function Get-MarshalLook {
    param([string]$State, $Report, [datetime]$Now)

    $look = @{ State = $State; Detail = ''; RoundAt = $null }
    if ($null -ne $Report) { $look.RoundAt = $Report.At }

    # A round is running. It looks like any working session, and its report is
    # the previous round's, so it has nothing to say yet.
    if ($State -eq 'Working') { return $look }

    # Two missed rounds. Whatever the report says belongs to a Marshal that has
    # stopped, so a question in it is not shown as live; the row says stale
    # instead, which is the sign that Marshal itself needs restarting.
    $age = $null
    if ($null -ne $Report) { $age = $Now - $Report.WrittenAt }
    $stale = ($null -ne $age -and $age.TotalMinutes -gt $marshalStaleMin)

    if ($null -ne $Report -and -not $stale -and $Report.NeedsYou) {
        $look.State = 'Blocked'
        $look.Detail = $Report.Summary
        if (-not $look.Detail -and $Report.Open -gt 0) { $look.Detail = '{0} open' -f $Report.Open }
        return $look
    }

    # A permission prompt or a question dialog the hooks reported. Marshal is
    # waiting on you whatever its last report said, and while it waits no round
    # can run to say so, so this stays Blocked as on any other row.
    if ($State -eq 'Blocked') { return $look }

    $look.State = 'Watching'
    if ($stale) {
        $minutes = [Math]::Floor($age.TotalMinutes)
        if ($minutes -lt 120) { $span = '{0} min' -f $minutes }
        elseif ($minutes -lt 2880) { $span = '{0} h' -f [Math]::Floor($minutes / 60) }
        else { $span = '{0} days' -f [Math]::Floor($minutes / 1440) }
        $look.Detail = 'stale' + $listSep + 'no round for ' + $span
    }
    return $look
}

# ---------------------------------------------------------------------------
# The poll
# ---------------------------------------------------------------------------
$script:knownHandles = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------------------
# Auto-hide. An empty card is only clutter on a screen it is always on top of,
# so it leaves and says what little it has to say through the tray dot until a
# session comes back.
# ---------------------------------------------------------------------------
$script:autoHidden = $false
$script:manualShow = $false

# Every show or hide a person asks for goes through here, so the poll can tell
# a card it hid itself from one the user opened deliberately. An opened card
# stays open, empty or not, until it next has rows to lose.
function Set-CardVisible {
    param([bool]$Visible, [switch]$Activate)
    if ($Visible) {
        if (-not $window.IsVisible) { $window.Show() }
        if ($Activate) { $window.Activate() | Out-Null }
        $script:manualShow = $true
        $script:autoHidden = $false
    } else {
        $window.Hide()
        $script:manualShow = $false
        $script:autoHidden = $false
    }
}

function Update-Card {
    # Someone launched the shortcut again while this instance was already
    # running. Treat it as "bring the card back" rather than ignoring it.
    if (Test-Path $showFlag) {
        Remove-Item $showFlag -Force -ErrorAction SilentlyContinue
        Set-CardVisible -Visible $true -Activate
    }

    # Touch state/dump.flag and this poll writes what every row is laid out from
    # to state/dump.txt. Checks the live card against reality without stopping
    # it, the way -Probe checks the window parsing.
    $dumpFlag = Join-Path $stateDir 'dump.flag'
    if (Test-Path $dumpFlag) {
        Remove-Item $dumpFlag -Force -ErrorAction SilentlyContinue
        Write-LayoutDump
    }

    # Write a preset's name into state/preset.flag and this poll switches to it,
    # the way the Style menu does, so a check can switch the live card without
    # clicking through it.
    $presetFlag = Join-Path $stateDir 'preset.flag'
    if (Test-Path $presetFlag) {
        $name = ([string](Get-Content $presetFlag -Raw)).Trim()
        Remove-Item $presetFlag -Force -ErrorAction SilentlyContinue
        try { Set-Preset -Name $name } catch { Write-ErrorLog -Where 'style' -Problem $_ }
    }

    # Write "resume <session id>" or "forget <session id>" into
    # state/closed.flag and this poll does to that closed row what a click on
    # it, or its Kill, does, so a check can drive closed rows without clicking.
    $closedFlag = Join-Path $stateDir 'closed.flag'
    if (Test-Path $closedFlag) {
        $words = ([string](Get-Content $closedFlag -Raw)).Trim() -split '\s+'
        Remove-Item $closedFlag -Force -ErrorAction SilentlyContinue
        try {
            $entry = $script:closedSessions[$words[-1]]
            if ($null -ne $entry -and $words[0] -eq 'resume') { Resume-ClosedSession -Entry $entry }
            if ($null -ne $entry -and $words[0] -eq 'forget') { Remove-ClosedSession -SessionId $entry.SessionId }
        } catch { Write-ErrorLog -Where 'closed' -Problem $_ }
    }

    $seen = @{}

    # Kept sessions first, so a poll that answered since the last tick shows on
    # this one rather than up to three seconds later.
    try { Update-KeptSessions } catch { Write-ErrorLog -Where 'kept' -Problem $_ }
    # "host|session" for every kept session a window here shows right now.
    $windowIds = @{}

    foreach ($h in @($script:knownHandles)) {
        $title = Get-WindowTitle -Handle $h
        if ($null -eq $title) {
            # Window is gone. Drop it now rather than waiting for the sweep, so
            # a closed session never lingers on the card. A window to another
            # machine may leave its session running there, so that machine is
            # asked at once and the session's row follows in a second or two.
            $script:knownHandles.Remove($h)
            $closedKey = [string][int64]$h
            # A session of this PC turns into a closed row on this same poll, in
            # its row's place, so the row never vanishes. With KeepClosedWindows
            # off, a window closed other than by its row's Close leaves the card
            # as a Kill would.
            $closedInfo = $script:sessionByHwnd[$closedKey]
            if ($null -ne $closedInfo -and $closedInfo.Remote -ne 'In') {
                $closedSid = [string]$closedInfo.SessionId
                if ($script:settings.KeepClosedWindows -or $script:keepSessions.ContainsKey($closedSid)) {
                    Add-ClosedSession -Info $closedInfo -Rec $rows[$closedKey]
                } elseif ($closedSid) {
                    $script:forgetSessions[$closedSid] = $true
                }
                $script:keepSessions.Remove($closedSid)
            }
            if ($script:outgoingByHwnd.ContainsKey($closedKey)) {
                $closedHost = $script:outgoingByHwnd[$closedKey]
                Request-KeptPoll -HostName $closedHost
                if ($rows.ContainsKey($closedKey) -and $rows[$closedKey].TmuxName) {
                    Set-KeptWindowClosed -HostName $closedHost -Name $rows[$closedKey].TmuxName
                }
            }
            # Its sound goes with it. Only here, where the window is known to be
            # closed: a row that merely drops off for one poll keeps its sound.
            $soundKey = [string][int64]$h
            $script:needWatch.Remove($soundKey)
            if ($script:settings.Sounds.ContainsKey($soundKey)) {
                $script:settings.Sounds.Remove($soundKey)
                Save-Settings
            }
            continue
        }
        $parsed = Read-SessionTitle -Title $title
        if (-not $parsed) { continue }
        $key = [string][int64]$h
        $isNew = -not $rows.ContainsKey($key)
        if ($isNew) {
            $rows[$key] = New-Row -Handle $h -Label $parsed.Label -State $parsed.State
        }
        $rows[$key].PendingState = $parsed.State
        $rows[$key].PendingLabel = $parsed.Label
        $rows[$key].TmuxName = $parsed.TmuxName
        $seen[$key] = $true
        # A window showing a kept session stands for that session: its faded
        # row steps aside, and a new window row takes that row's slot.
        if ($parsed.TmuxName -and $script:outgoingByHwnd.ContainsKey($key)) {
            $id = $script:outgoingByHwnd[$key] + '|' + $parsed.TmuxName
            $windowIds[$id] = $true
            if ($isNew -or $null -eq $script:slotRec[$id]) { Use-SessionSlot -Rec $rows[$key] -Id $id }
        }
        # The same for a session of this PC: a window resuming a closed session
        # takes the closed row's slot, and the closed row goes.
        $local = $script:sessionByHwnd[$key]
        if ($null -ne $local -and $local.Remote -ne 'In' -and $local.SessionId) {
            $id = 'local|' + $local.SessionId
            if (-not [object]::ReferenceEquals($script:slotRec[$id], $rows[$key])) { Use-SessionSlot -Rec $rows[$key] -Id $id }
            if ($script:closedSessions.ContainsKey($local.SessionId)) { Remove-ClosedSession -SessionId $local.SessionId }
        }
    }

    # Incoming remote sessions have no title to read, so their state is the
    # session file's own busy or idle, and their label the task title from the
    # transcript. Both follow the slow timer, three seconds behind at most.
    foreach ($key in @($script:sessionByHwnd.Keys)) {
        $info = $script:sessionByHwnd[$key]
        if ($info.Remote -ne 'In') { continue }
        $state = $(if ($info.Status -eq 'busy') { 'Working' } else { 'Waiting' })
        $label = $(if ($info.Title) { $info.Title } else { 'Session' })
        if (-not $rows.ContainsKey($key)) {
            $rows[$key] = New-Row -Handle ([IntPtr][int64]$key) -Label $label -State $state
        }
        $rows[$key].PendingState = $state
        $rows[$key].PendingLabel = $label
        $seen[$key] = $true
    }

    # Kept sessions with no window to read, from the last poll of each place.
    # Their state and title come from that place's tmux, a few seconds behind.
    foreach ($key in @($script:keptByKey.Keys)) {
        $kept = $script:keptByKey[$key]
        $id = ''
        if ($kept.Problem) {
            $state = 'Waiting'
            $label = $(if ($kept.Problem -eq 'signin') { 'Sign in to see its sessions' } else { 'Cannot reach it' })
        } else {
            $id = (Get-KeptPlaceName -Place $kept.Place) + '|' + $kept.Name
            if ($windowIds.ContainsKey($id)) { continue }
            $state = $kept.State
            $label = $(if ($kept.Title -and $kept.Title -ne 'Claude Code') { $kept.Title } else { $kept.Name })
        }
        if (-not $rows.ContainsKey($key)) {
            $rows[$key] = New-Row -Handle ([IntPtr][int64]$key) -Label $label -State $state
            if ($id) { Use-SessionSlot -Rec $rows[$key] -Id $id }
        }
        $rows[$key].PendingState = $state
        $rows[$key].PendingLabel = $label
        $seen[$key] = $true
    }

    # Closed sessions of this PC, faded, until resumed or killed. Drawn as a
    # quiet row with nothing for you, the way Marshal is between rounds, and
    # slimmer: only its title and when it closed. The stripe with the model,
    # the context bar and the second line belong to a session that runs.
    foreach ($entry in @($script:closedSessions.Values)) {
        $key = $entry.Key
        if (-not $rows.ContainsKey($key)) {
            $rows[$key] = New-Row -Handle ([IntPtr][int64]$key) -Label $entry.Label -State 'Watching'
            Use-SessionSlot -Rec $rows[$key] -Id ('local|' + $entry.SessionId)
            $closedRec = $rows[$key]
            $closedRec.Closed = $true
            $closedRec.Stripe.Visibility = 'Hidden'
            $closedRec.CtxTrack.Visibility = 'Collapsed'
            $closedRec.CtxFill.Visibility = 'Collapsed'
            $closedRec.SoundMark.Visibility = 'Collapsed'
            $closedRec.TimerColumn.Width = [System.Windows.GridLength]::Auto
        }
        $rows[$key].Resuming = ($null -ne $entry.Resuming -and ((Get-Date) - $entry.Resuming).TotalSeconds -lt 20)
        $rows[$key].PendingState = 'Watching'
        $rows[$key].PendingLabel = $entry.Label
        $seen[$key] = $true
    }

    foreach ($key in @($rows.Keys)) {
        if (-not $seen.ContainsKey($key)) {
            # An incoming row has no window whose closing would clear these in
            # the loop above, so its session ending is the moment.
            if ($rows[$key].Handle.ToInt64() -lt 0) {
                $script:needWatch.Remove($key)
                if ($script:settings.Sounds.ContainsKey($key)) {
                    $script:settings.Sounds.Remove($key)
                    Save-Settings
                }
            }
            # A session closing mid-drag takes its row with it. Drop the drag
            # first so nothing is left holding capture on a removed element.
            if ($null -ne $script:drag -and [object]::ReferenceEquals($script:drag.Rec, $rows[$key])) {
                Complete-RowDrag -Commit $false
            }
            $rowCanvas.Children.Remove($rows[$key].Element)
            $rows.Remove($key)
        }
    }

    $ordered = @($rows.Values)

    # Attach the workspace to every row before anything else looks at it. The
    # map is rebuilt on the slow timer, so this is a dictionary lookup. The
    # workspace is the folder the session's terminal opened in, or with
    # GroupByRepo on the repository the agent is really working in, read from its
    # transcript, once that is known.
    foreach ($rec in $ordered) {
        $key = [string][int64]$rec.Handle
        $rec.RemoteNote = ''
        $rec.Helpers = 0
        $rec.WakeAt = $null
        if ($script:sessionByHwnd.ContainsKey($key)) {
            $info = $script:sessionByHwnd[$key]
            $rec.SessionId = $info.SessionId
            $rec.Cwd       = $info.Cwd
            $rec.Workspace = $info.Workspace
            if ($info.ContainsKey('WorkRepo') -and $info.WorkRepo) { $rec.Workspace = $info.WorkRepo }
            $rec.StartedAt = $info.StartedAt
            $rec.SessionStatus   = $info.Status
            $rec.StatusUpdatedAt = $info.StatusUpdatedAt
            if ($info.ContainsKey('Model'))  { $rec.Model  = $info.Model }
            if ($info.ContainsKey('Prompt')) { $rec.Prompt = $info.Prompt }
            if ($info.ContainsKey('Helpers')) { $rec.Helpers = $info.Helpers }
            if ($info.ContainsKey('WakeAt')) { $rec.WakeAt = $info.WakeAt }
            # How the row looks, for a closed row should its Claude end
            # between two polls and the row be gone by then.
            if ($info.Remote -ne 'In' -and $info.SessionId -and $rec.Label) {
                $script:localSeen[[string]$info.SessionId] = @{ Cwd = [string]$info.Cwd; Label = $rec.Label; Workspace = $rec.Workspace
                                                                Model = $rec.Model; Prompt = $rec.Prompt }
            }
            if ($info.Remote -eq 'In') {
                # Started from somewhere else. When it runs in tmux here, say
                # where its window is, and whether it has one at all.
                $kept = $script:keptBySessionId[$info.SessionId]
                if ($null -eq $kept) {
                    $rec.RemoteNote = 'started from another PC'
                } elseif ($kept.Window -eq 'remote') {
                    $rec.RemoteNote = 'connected from another PC' + $listSep + 'keeps running when closed'
                } elseif ($kept.Window -eq 'local') {
                    $rec.RemoteNote = 'connected here' + $listSep + 'keeps running when closed'
                } else {
                    $rec.RemoteNote = 'not connected' + $listSep + 'still running'
                }
            }
        } elseif ($script:keptByKey.ContainsKey($key)) {
            # A kept session with no window here, filed under its machine the
            # way that machine's open windows are.
            $kept = $script:keptByKey[$key]
            $placeName = Get-KeptPlaceName -Place $kept.Place
            $rec.Workspace = $placeName
            $rec.Helpers = [int]$kept.Helpers
            if ($kept.Problem -eq 'signin') {
                $rec.RemoteNote = 'Tailscale wants you to sign in again'
            } elseif ($kept.Problem) {
                $rec.RemoteNote = 'switched off or offline'
            } else {
                $opening = $script:keptOpening["$($kept.Place)|$($kept.Name)"]
                if ($null -ne $opening -and ((Get-Date) - $opening).TotalSeconds -lt 15) {
                    $rec.RemoteNote = 'connecting...'
                } elseif ($kept.Window -eq 'local') {
                    $rec.RemoteNote = 'open on the ' + $placeName + ' PC' + $listSep + 'still running'
                } elseif ($kept.Window -eq 'remote') {
                    $rec.RemoteNote = 'open on another PC' + $listSep + 'still running'
                } else {
                    $rec.RemoteNote = 'not connected' + $listSep + 'still running'
                }
            }
        } elseif ($script:closedByKey.ContainsKey($key)) {
            # A closed session of this PC keeps the group, model and context
            # its row had when it closed.
            $closed = $script:closedByKey[$key]
            $rec.SessionId = $closed.SessionId
            $rec.Cwd       = $closed.Cwd
            $rec.Workspace = $(if ($closed.Workspace) { $closed.Workspace } else { 'unknown' })
            $rec.Model     = $closed.Model
            $rec.Prompt    = $closed.Prompt
        } elseif ($script:outgoingByHwnd.ContainsKey($key)) {
            # The session lives on the other machine, so the machine is the
            # workspace: every session reached through it groups under its name.
            $rec.Workspace = $script:outgoingByHwnd[$key]
            $rec.OutHost = $rec.Workspace
            if ($rec.TmuxName -or $script:outgoingKeeps[$key] -or (Test-KeptTitle -HostName $rec.Workspace -Label $rec.PendingLabel)) {
                $rec.RemoteNote = 'connected' + $listSep + 'keeps running when closed'
            } else {
                $rec.RemoteNote = 'connected' + $listSep + 'ends when closed'
            }
            $rec.Helpers = Get-OutgoingHelpers -HostName $rec.Workspace -TmuxName $rec.TmuxName -Label $rec.PendingLabel
        } elseif ($rec.OutHost) {
            # Its ssh has ended but the window still shows a session title, so
            # it is no longer filed under the host it left.
            $rec.OutHost = ''
            $rec.Workspace = 'unknown'
        } elseif ($rec.Workspace -eq '') {
            $rec.Workspace = 'unknown'
        }
    }

    # Promote to Blocked before anything is applied, not after. Applying the
    # title's state first and correcting it afterwards would flip the row
    # Waiting -> Blocked on every single poll, which resets its timer to zero
    # and restarts the alarm animation four hundred milliseconds into itself.
    foreach ($rec in (Resolve-BlockedRows -Ordered $ordered)) {
        $rec.PendingState = 'Blocked'
    }

    # Marshal's row is settled last, for the same reason and after the markers:
    # those are judged on the title's Waiting, which the Watching below would
    # otherwise hide from them. Every other row gets an empty detail and no
    # round time, which is exactly what it had before.
    foreach ($rec in $ordered) {
        # A remote row says which way and where on its second line, the line
        # only Marshal used before, so it reads the same in every style.
        $rec.PendingDetail = [string]$rec.RemoteNote
        $rec.RoundAt = $null
        if ($script:closedByKey.ContainsKey([string][int64]$rec.Handle)) { continue }
        if (-not (Test-MarshalRow -Cwd $rec.Cwd -Label $rec.PendingLabel)) { continue }
        $look = Get-MarshalLook -State $rec.PendingState -Report (Read-MarshalReport -Path $marshalReportFile) -Now (Get-Date)
        $rec.PendingState  = $look.State
        $rec.PendingDetail = $look.Detail
        $rec.RoundAt       = $look.RoundAt
    }

    # A finished turn whose session still has helpers or background commands
    # running, or a timer set to wake it, waits on its own work rather than on
    # you. Decided after the blocked rows, so a question for you still turns its
    # row amber. The timer counts until a little after it is due, by when the
    # session has woken. With WaitOnOwnWork off, green means only that the
    # turn is over.
    $wakeNow = Get-Date
    foreach ($rec in $ordered) {
        if (-not $script:settings.WaitOnOwnWork) { break }
        if ($rec.PendingState -ne 'Waiting') { continue }
        $timer = ($null -ne $rec.WakeAt -and $wakeNow -lt $rec.WakeAt.AddSeconds($wakeGraceSec))
        $shell = ($rec.SessionStatus -eq 'shell')
        if ($rec.Helpers -gt 0 -or $shell -or $timer) { $rec.PendingState = 'OwnWork' }
    }

    foreach ($rec in $ordered) {
        Set-RowState -Rec $rec -State $rec.PendingState -Label $rec.PendingLabel -Detail $rec.PendingDetail
    }

    # A row with no window connected is drawn faded, so it reads as not
    # connected at a glance, and says on hover what a click on it does: a kept
    # session reconnects, a closed one resumes.
    foreach ($rec in $ordered) {
        $kept = Get-RowKept -Element $rec.Element
        $closed = Get-RowClosed -Element $rec.Element
        $action = ''
        if ($null -ne $closed) {
            $action = 'Resume'
        } elseif ($null -ne $kept) {
            $action = $(if ($kept.Problem -eq 'signin') { 'Sign in' } elseif ($kept.Problem) { 'Try again' } else { 'Reconnect' })
        }
        $rec.ClickAction = $action
        if (-not $rec.Element.IsMouseOver -or -not $action) {
            Set-Fade -Element $rec.Element -To $(if ($action) { $keptFade } else { 1 })
            if (-not $action) {
                $rec.Reconnect.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                $rec.Reconnect.Opacity = 0
                $rec.Reconnect.Visibility = 'Collapsed'
            }
        }
        # A closed row's time is when it closed, across restarts of the card.
        if ($null -ne $closed) {
            if ($null -eq $closed.ClosedTime) {
                try { $closed.ClosedTime = [DateTime]::Parse($closed.ClosedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { $closed.ClosedTime = Get-Date }
            }
            $rec.FinishedAt = $closed.ClosedTime
            $rec.WorkSince = $null
        }

        # The row's buttons, which show while the pointer is on it. A session
        # elsewhere gets Disconnect, while a window here shows it, and Kill. A
        # session of this PC gets Close while its window is open, and Kill.
        $endable = Get-RowEndable -Element $rec.Element
        $local = Get-RowLocal -Element $rec.Element
        $canKill = ($null -ne $endable -or $null -ne $local -or $null -ne $closed)
        $rec.KillButton.Visibility = $(if ($canKill) { 'Visible' } else { 'Collapsed' })
        $rec.DisconnectButton.Visibility = $(if ($null -ne $endable -and [int64]$rec.Handle -gt 0) { 'Visible' } else { 'Collapsed' })
        $rec.CloseButton.Visibility = $(if ($null -ne $local) { 'Visible' } else { 'Collapsed' })
        $rec.ResumeButton.Visibility = $(if ($null -ne $closed) { 'Visible' } else { 'Collapsed' })
        if ($null -ne $closed -and $null -eq $rec.ResumeButton.ToolTip) { $rec.ResumeButton.ToolTip = 'Resume: open it again in a new window' }
        $rec.RowButtons.Tag = $(if ($canKill) { 'on' } else { '' })
        if ($null -ne $endable) {
            $where = Get-KeptPlaceLong -Place $endable.Place
            $killTip = "Kill: stop Claude on $where"
            $rec.DisconnectButton.ToolTip = "Disconnect: close this window, Claude keeps running on $where"
        } elseif ($null -ne $local) {
            $killTip = 'Kill: end this session and take it off the card'
        } else {
            $killTip = 'Kill: take this closed session off the card'
        }
        if ($canKill -and [string]$rec.KillButton.ToolTip -ne $killTip) { $rec.KillButton.ToolTip = $killTip }
    }
    Update-Needs -Ordered $ordered
    Update-HelperMarks -Ordered $ordered

    # The helpers' ring turns too, on a finished row as much as a working one.
    Set-Spin -On (@($ordered | Where-Object { $_.State -eq 'Working' }).Count -gt 0)
    Update-Layout
    Update-Timers

    # The same rows just painted, so the tray can never disagree with the card.
    # This once passed a variable that no longer existed, which PowerShell reads
    # as $null without complaint, and the tray sat on blue whatever happened.
    Set-TrayState -Rows $ordered

    # The card carries nothing, so it gets out of the way until it does again. A
    # running Unity editor counts as something: a headless one is invisible
    # everywhere else, and keeping it in sight is what its rows are for. So does
    # Marshal while it is Watching, unlike in the tray: it is a live session, and
    # its row is the only place a stale Marshal shows.
    if (@($ordered).Count -eq 0 -and $script:unityRows.Count -eq 0) {
        if ($window.IsVisible -and -not $script:manualShow) {
            $window.Hide()
            $script:autoHidden = $true
        }
    } else {
        # It has rows again, so the next empty stretch may hide it even if this
        # one was opened by hand.
        $script:manualShow = $false
        if ($script:autoHidden) {
            if (-not $window.IsVisible) { $window.Show() }
            $script:autoHidden = $false
        }
    }
}

# Places every row and heading, fills the stripes and bars, and sizes the window
# to fit. Split out of the poll so a drag can re-lay the card the moment a row
# changes slot instead of waiting for the next poll.
# The window's height for this much content: the rows, their padding above
# and below, the warning line when it shows, the clock above them, the card's
# border lines top and bottom, and the shadow's room round the card.
function Get-CardHeight {
    param([double]$ContentHeight)
    $body = $ContentHeight + $script:cardPadding * 2 + $script:cardBorder.Top + $script:cardBorder.Bottom
    if ($warnText.Visibility -eq 'Visible') { $body += 20 }
    if ($usagePanel.Visibility -eq 'Visible') {
        $body += $usagePanel.Margin.Top + $usagePanel.Margin.Bottom
        foreach ($bar in $usageBars) { if ($bar.Row.Visibility -eq 'Visible') { $body += $bar.Row.Height } }
    }
    $body += $workClock.Height + $workClock.Margin.Top
    return $body + $shadowMargin * 2
}

# Whether to warn that more sessions are running than the card shows, which is
# what tabs sharing a window look like. Only once that has lasted five seconds:
# the rows follow the windows every poll but the session count only every
# sweep, three seconds apart, so the two disagree for a moment every time a
# session opens or closes, and a session's process can outlive its window by a
# moment too. Warning on those flashed a false alarm, and grew the card by the
# warning's line, at every close.
$script:warnSince = $null

function Test-ShowWarning {
    param([int]$Live, [int]$Shown, [datetime]$Now)
    if ($Live -le $Shown) { $script:warnSince = $null; return $false }
    if ($null -eq $script:warnSince) { $script:warnSince = $Now }
    return (($Now - $script:warnSince).TotalSeconds -ge 5)
}

# How tall a row is drawn, and the room it takes with the gap under it. A
# closed row holds one line of small text, so it takes less.
$closedRowScale = 0.7

function Get-RowHeight {
    param($Rec)
    if ($Rec.Closed) { return [Math]::Round($script:rowHeight * $closedRowScale) }
    return $script:rowHeight
}

function Get-RowPitch {
    param($Rec)
    return (Get-RowHeight -Rec $Rec) + $rowGap
}

function Update-Layout {
    $ordered = @($rows.Values)

    # Stable geography beats sorting attention to the top. At six rows a filled
    # row is found instantly anyway, and rows that never move let you learn
    # where each session lives. Ordering is by workspace, then by the order the
    # rows were dragged into, then by when the session started: the task label
    # changes every turn, so ordering by anything about it would reshuffle the
    # card constantly.
    # Grouped through a scriptblock, not -Property Workspace: rows are
    # hashtables, and Group-Object resolves a bare property name against the
    # Hashtable type itself rather than its keys, so every row came back in one
    # nameless group.
    $allGroups = @($ordered | Group-Object -Property { $_.Workspace })

    # A window whose session file has not appeared yet is almost always one
    # opened a second ago. It must not invent a workspace of its own, must not
    # push a single-workspace card into grouped mode, and must not take a
    # stripe colour: it just sits at the bottom until it resolves.
    $known = @($allGroups | Where-Object { $_.Name -ne 'unknown' } | Sort-Object Name)
    $unresolved = @($allGroups | Where-Object { $_.Name -eq 'unknown' })
    $groups = @($known) + @($unresolved)
    # Headers show even with a single workspace: the folder name is worth
    # reading on an ordinary one-repository day too, not only when there are
    # two to tell apart.
    $showGroups = $known.Count -gt 0

    $y = 0.0
    $script:groupSlots = @{}
    $script:groupOrder = @{}
    $script:groupNew = @{}
    $headerIndex = 0
    $trailingGroupGap = $false

    $iconFor = Get-WorkspaceIcons -Names @($known | ForEach-Object { $_.Name })
    $patternFor = Get-SessionPatterns -Recs @($rows.Values)

    $groupIndex = 0
    foreach ($g in $groups) {
        $isResolved = ($g.Name -ne 'unknown')
        $wsBrush = Get-WorkspaceBrush -Index $groupIndex
        if ($isResolved) { $groupIndex++ }
        $showThisGroup = ($showGroups -and $isResolved)

        if ($showThisGroup) {
            $header = Get-Header -Index $headerIndex
            $headerIndex++
            $header.Label.Text = $g.Name
            $header.Swatch.Fill = $wsBrush
            Set-HeaderMark -Header $header -Icon $iconFor[$g.Name]
            $folder = Get-GroupFolder -Name $g.Name -Recs $g.Group
            $header.NewButton.Tag = $folder
            $header.NewButton.Visibility = $(if ($folder) { 'Visible' } else { 'Collapsed' })
            $header.NewButton.ToolTip = $(if ($folder) { 'New session in ' + (Split-Path -Leaf $folder) } else { $null })
            $script:groupNew[$g.Name] = $header
            $header.Element.Visibility = 'Visible'
            [System.Windows.Controls.Canvas]::SetTop($header.Element, $y)
            $y += $headerHeight
        }

        $inGroup = @(Get-GroupOrder -Group $g.Group)
        $drag = $script:drag
        if ($null -ne $drag -and $drag.Group -eq $g.Name) {
            # The dragged row takes the slot under the pointer and the others
            # close up around it. Kept on the drag, so a drop saves exactly the
            # order that was on screen at that moment.
            $list = New-Object System.Collections.ArrayList
            foreach ($other in $inGroup) {
                if (-not [object]::ReferenceEquals($other, $drag.Rec)) { [void]$list.Add($other) }
            }
            $list.Insert([Math]::Max(0, [Math]::Min([int]$drag.Target, $list.Count)), $drag.Rec)
            $inGroup = @($list)
            $drag.Order = $inGroup
        }
        $script:groupSlots[$g.Name] = @{ Top = $y; Count = $inGroup.Count; Recs = $inGroup }
        $script:groupOrder[$g.Name] = $inGroup

        foreach ($rec in $inGroup) {
            # Always drawn, because it holds the model name. It takes the hue of
            # its group's header swatch, so the two always agree; only a row
            # whose session is not resolved yet stays neutral. A preset that
            # colours it by model gives it the model's colour instead.
            if ($script:stripeByModel) {
                $rec.Stripe.Background = Get-ModelBrush -Model $rec.Model
            } elseif ($showThisGroup) {
                $rec.Stripe.Background = $wsBrush
            } else {
                $rec.Stripe.Background = $brush.WsNeutral
            }
            $rec.StripePattern.Background = $patternFor[$rec.Handle.ToInt64()]
            # The row under the pointer is placed by the drag, not by the layout.
            if (-not ($null -ne $drag -and [object]::ReferenceEquals($rec, $drag.Rec))) {
                Move-RowTo -Rec $rec -Top $y
            }

            # "claude-opus-5" is noise on a row this narrow; "opus" is the part
            # that answers the question.
            if ($rec.Model -match 'claude-([a-z]+)') {
                $rec.ModelText.Text = $matches[1]
            } else {
                $rec.ModelText.Text = ''
            }
            # A preset that says the model by colour alone moves the name to
            # the stripe's tooltip.
            if (-not $script:stripeModelName) {
                $rec.ModelText.Text = ''
                $rec.Stripe.ToolTip = $(if ($rec.Model) { $rec.Model } else { $null })
            } else {
                $rec.Stripe.ToolTip = $null
            }

            $limit = $script:contextWindow
            $fraction = 0.0
            if ($limit -gt 0) { $fraction = [Math]::Min(1.0, $rec.Prompt / $limit) }
            $rec.CtxFill.Width = [Math]::Round($ctxBarWidth * $fraction)
            if ($fraction -ge $ctxHighMark) {
                $rec.CtxFill.Background = $brush.CtxHigh
            } else {
                $rec.CtxFill.Background = $brush.CtxFill
            }

            if ($rec.Closed) { $rec.Element.Height = Get-RowHeight -Rec $rec }
            $y += Get-RowPitch -Rec $rec
        }

        if ($showThisGroup) { $y += $groupGap }
        $trailingGroupGap = $showThisGroup
    }

    # Unity editors go below every agent group, under a heading of their own, so
    # they never mix with the rows the drag, the tray and the timers work on.
    $unityList = @($script:unityRows.Values | Sort-Object { $_.SortKey })
    if ($unityList.Count -gt 0) {
        # An unresolved agent group at the bottom adds no gap of its own.
        if (@($ordered).Count -gt 0 -and -not $trailingGroupGap) { $y += $groupGap }
        $header = Get-Header -Index $headerIndex
        $headerIndex++
        $header.Label.Text = 'Unity'
        $header.Swatch.Fill = $brush.WsNeutral
        Set-HeaderMark -Header $header -Icon $null
        $header.NewButton.Visibility = 'Collapsed'
        $header.NewButton.Tag = ''
        $header.Element.Visibility = 'Visible'
        [System.Windows.Controls.Canvas]::SetTop($header.Element, $y)
        $y += $headerHeight
        foreach ($unityRow in $unityList) {
            [System.Windows.Controls.Canvas]::SetTop($unityRow.Element, $y)
            $y += $script:rowHeight + $rowGap
        }
        $y += $groupGap
        $trailingGroupGap = $true
    }

    # Any header left over from a workspace that has closed.
    for ($i = $headerIndex; $i -lt $script:headerPool.Count; $i++) {
        $script:headerPool[$i].Element.Visibility = 'Collapsed'
    }

    $count = @($ordered).Count
    $liveFiles = $script:liveSessionCount
    if (Test-ShowWarning -Live $liveFiles -Shown $count -Now (Get-Date)) {
        # One session per window is load-bearing: if two ever share a window as
        # tabs, only the active tab's title is readable and the other session
        # disappears. Fail loudly instead of silently showing four of five.
        $warnText.Text = ("{0} sessions running, {1} shown - check for tabbed windows" -f $liveFiles, $count)
        $warnText.Visibility = 'Visible'
    } else {
        $warnText.Visibility = 'Collapsed'
    }

    # The layout loop already walked the exact height; trim the trailing gaps it
    # left behind rather than recomputing from counts, which would have to know
    # about headers and group spacing all over again.
    $contentHeight = $y
    if ($count -gt 0 -or $unityList.Count -gt 0) {
        $contentHeight -= $rowGap
        # Only if the final group actually added one; an unresolved group at the
        # bottom does not.
        if ($trailingGroupGap) { $contentHeight -= $groupGap }
    } else {
        $contentHeight = $rowHeight
    }
    $window.Height = Get-CardHeight -ContentHeight $contentHeight
}

function Sweep-Windows {
    $scan = Scan-Windows
    foreach ($h in $scan.Terminals) {
        if (-not $script:knownHandles.Contains($h)) {
            $title = Get-WindowTitle -Handle $h
            if (Read-SessionTitle -Title $title) { [void]$script:knownHandles.Add($h) }
        }
    }
    Sync-SessionMap -ShellToWindow $scan.ShellToWindow
    Sync-SessionExtras
    Update-UnityRows
    # Caught on its own, so a place that misbehaves cannot stop the local rows.
    try { Update-KeptSessions -ReadPlaces } catch { Write-ErrorLog -Where 'kept' -Problem $_ }
}

# Caught on its own, so a Unity hiccup can never stop the agent rows updating.
# The editors are collected even with the group switched off, because their CPU
# limits must hold whether their rows are shown or not; the switch only hides
# the rows.
function Update-UnityRows {
    try {
        $editors = @(Get-UnityEditors)
        Update-UnityCaps -Editors $editors
        if ($script:settings.ShowUnityEditors) {
            $script:unityEditors = $editors
        } else {
            $script:unityEditors = @()
        }
        Sync-UnityRows
    } catch { Write-ErrorLog -Where 'unity' -Problem $_ }
}

# The card's menu items read "_" as an access key, so a repo named with one
# would lose it.
function ConvertTo-MenuHeader {
    param([string]$Text)
    return ($Text -replace '_', '__')
}

# New session, first in the card's own menu: the same list the tray offers.
function New-LaunchMenu {
    $parent = New-CardMenuItem -Header 'New session'
    $repos = @(Get-LaunchMenuRepos)
    if ($repos.Count -eq 0) {
        $none = New-CardMenuItem -Header 'No recent repos'
        $none.IsEnabled = $false
        [void]$parent.Items.Add($none)
        return $parent
    }
    foreach ($repo in $repos) {
        [void](Add-CardMenuAction -Parent $parent -Header (ConvertTo-MenuHeader $repo.Name) -Where 'launch' -Arg $repo.Path `
            -Action { param($path) Start-ClaudeSession -Folder $path })
    }
    [void]$parent.Items.Add((New-CardMenuSeparator))
    $hide = New-CardMenuItem -Header 'Hide from this list'
    foreach ($repo in $repos) {
        [void](Add-CardMenuAction -Parent $hide -Header (ConvertTo-MenuHeader $repo.Name) -Where 'launch' -Arg $repo.Path `
            -Action { param($path) Hide-LaunchRepo -Path $path })
    }
    [void]$parent.Items.Add($hide)
    return $parent
}

# The card's own menu, behind the three bars left of the session clock.
function Show-SettingsMenu {
    $menu = New-CardMenu
    [void]$menu.Items.Add((New-LaunchMenu))
    [void]$menu.Items.Add((New-CardMenuSeparator))

    # The switches in a submenu of their own, so the menu itself stays short
    # and New session stands out at its top.
    $settingsItem = New-CardMenuItem -Header 'Settings'

    $unityItem = New-CardMenuItem -Header 'Show Unity editors'
    $unityItem.IsCheckable = $true
    $unityItem.IsChecked = [bool]$script:settings.ShowUnityEditors
    $unityItem.Add_Click({
        param($sender, $e)
        try {
            $script:settings.ShowUnityEditors = [bool]$sender.IsChecked
            Save-Settings
            Update-UnityRows
            Update-Layout
        } catch { Write-ErrorLog -Where 'settings' -Problem $_ }
    })
    [void]$settingsItem.Items.Add($unityItem)

    # Takes effect at once rather than on the next sweep: the extras are read
    # again with the new setting and the poll regroups the rows from them.
    $repoItem = New-CardMenuItem -Header 'Group by working repository'
    $repoItem.IsCheckable = $true
    $repoItem.IsChecked = [bool]$script:settings.GroupByRepo
    $repoItem.Add_Click({
        param($sender, $e)
        try {
            $script:settings.GroupByRepo = [bool]$sender.IsChecked
            Save-Settings
            Sync-SessionExtras
            Update-Card
        } catch { Write-ErrorLog -Where 'settings' -Problem $_ }
    })
    [void]$settingsItem.Items.Add($repoItem)

    # Every place is asked again at once with the new setting, so the rows
    # change in a moment rather than on the next round.
    $othersItem = New-CardMenuItem -Header "Show other people's sessions"
    $othersItem.IsCheckable = $true
    $othersItem.IsChecked = [bool]$script:settings.ShowOthersSessions
    $othersItem.Add_Click({
        param($sender, $e)
        try {
            $script:settings.ShowOthersSessions = [bool]$sender.IsChecked
            Save-Settings
            foreach ($poll in @($script:keptSources.Values)) { $poll.NextAt = [datetime]::MinValue }
        } catch { Write-ErrorLog -Where 'settings' -Problem $_ }
    })
    [void]$settingsItem.Items.Add($othersItem)

    $askKillItem = New-CardMenuItem -Header 'Ask before Kill'
    $askKillItem.IsCheckable = $true
    $askKillItem.IsChecked = [bool]$script:settings.AskBeforeKill
    $askKillItem.Add_Click({
        param($sender, $e)
        try {
            $script:settings.AskBeforeKill = [bool]$sender.IsChecked
            Save-Settings
        } catch { Write-ErrorLog -Where 'settings' -Problem $_ }
    })
    [void]$settingsItem.Items.Add($askKillItem)

    $keepClosedItem = New-CardMenuItem -Header 'Keep closed windows to resume'
    $keepClosedItem.IsCheckable = $true
    $keepClosedItem.IsChecked = [bool]$script:settings.KeepClosedWindows
    $keepClosedItem.Add_Click({
        param($sender, $e)
        try {
            $script:settings.KeepClosedWindows = [bool]$sender.IsChecked
            Save-Settings
        } catch { Write-ErrorLog -Where 'settings' -Problem $_ }
    })
    [void]$settingsItem.Items.Add($keepClosedItem)

    $ownWorkItem = New-CardMenuItem -Header 'Green only once helpers and commands end'
    $ownWorkItem.IsCheckable = $true
    $ownWorkItem.IsChecked = [bool]$script:settings.WaitOnOwnWork
    $ownWorkItem.Add_Click({
        param($sender, $e)
        try {
            $script:settings.WaitOnOwnWork = [bool]$sender.IsChecked
            Save-Settings
        } catch { Write-ErrorLog -Where 'settings' -Problem $_ }
    })
    [void]$settingsItem.Items.Add($ownWorkItem)

    # The subscription's limits along the card's bottom, each on its own.
    foreach ($bar in @(@{ Header = 'Show 5-hour limit'; Key = 'ShowUsage5h' },
                       @{ Header = 'Show weekly limit'; Key = 'ShowUsageWeek' })) {
        $usageItem = New-CardMenuItem -Header $bar.Header
        $usageItem.IsCheckable = $true
        $usageItem.IsChecked = [bool]$script:settings[$bar.Key]
        $usageItem.Tag = $bar.Key
        $usageItem.Add_Click({
            param($sender, $e)
            try {
                $script:settings[[string]$sender.Tag] = [bool]$sender.IsChecked
                Save-Settings
                Update-UsageBars
                Update-Layout
            } catch { Write-ErrorLog -Where 'settings' -Problem $_ }
        })
        [void]$settingsItem.Items.Add($usageItem)
    }

    [void]$menu.Items.Add($settingsItem)
    [void]$menu.Items.Add((New-DefaultSoundMenu))
    [void]$menu.Items.Add((New-StyleMenu))

    $menu.PlacementTarget = $menuButton
    $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $menu.IsOpen = $true
}

# ---------------------------------------------------------------------------
# The Claude subscription's limits, as bars along the card's bottom: the
# five-hour window and the week, how much of each is used, and when each resets.
#
# Claude Code keeps its login in ~/.claude/.credentials.json and refreshes the
# token there while it runs. The card only reads that file and never refreshes
# the token itself, since a refresh would replace the one Claude holds. With it
# the card asks the endpoint Claude's own /usage reads, every few minutes, and
# never waits on the network: the request runs as a task the clock collects.
# A reading that has grown old, because no Claude has run here for a while and
# the login lapsed, is shown dimmed rather than as current.
# ---------------------------------------------------------------------------
$usageEverySec = 180
$usageStaleMin = 15
$credentialsFile = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$script:usage = @{ Task = $null; ReadTask = $null; NextAt = [datetime]::MinValue; Data = $null; At = $null; DrawnAt = [datetime]::MinValue }
Add-Type -AssemblyName System.Net.Http
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
$script:http = New-Object System.Net.Http.HttpClient
$script:http.Timeout = [TimeSpan]::FromSeconds(20)

# Collects a finished request, or starts the next one when it is due. Runs on
# the clock, once a second; with nothing finished and nothing due it returns
# at once.
function Update-Usage {
    $u = $script:usage
    $now = Get-Date
    if ($null -ne $u.ReadTask) {
        if (-not $u.ReadTask.IsCompleted) { return }
        if (-not $u.ReadTask.IsFaulted) {
            try {
                $reading = $u.ReadTask.Result | ConvertFrom-Json
                if ($null -ne $reading.five_hour -or $null -ne $reading.seven_day) { $u.Data = $reading; $u.At = $now }
            } catch { Write-ErrorLog -Where 'usage' -Problem $_ }
        }
        $u.ReadTask = $null
        Update-UsageBars
        return
    }
    if ($null -ne $u.Task) {
        if (-not $u.Task.IsCompleted) { return }
        if (-not $u.Task.IsFaulted -and -not $u.Task.IsCanceled -and $u.Task.Result.IsSuccessStatusCode) {
            $u.ReadTask = $u.Task.Result.Content.ReadAsStringAsync()
        }
        $u.Task = $null
        return
    }
    # A window that has reset since the last reading shows its old use until
    # asked again, so it is asked as soon as the reset has passed.
    if ($null -ne $u.Data -and $null -ne $u.At) {
        foreach ($field in @('five_hour', 'seven_day')) {
            $resets = ConvertFrom-UsageTime -Value $u.Data.$field.resets_at
            if ($null -ne $resets -and $resets -lt $now -and $u.At -lt $resets -and $u.NextAt -gt $now.AddSeconds(20)) {
                $u.NextAt = $now.AddSeconds(20)
            }
        }
    }
    if ((-not ($script:settings.ShowUsage5h -or $script:settings.ShowUsageWeek)) -or $now -lt $u.NextAt) {
        if (($now - $u.DrawnAt).TotalSeconds -ge 60) { Update-UsageBars }
        return
    }
    $u.NextAt = $now.AddSeconds($usageEverySec)
    try {
        $login = (Get-Content $credentialsFile -Raw -ErrorAction Stop | ConvertFrom-Json).claudeAiOauth
        if (-not $login.accessToken) { return }
        if ([int64]$login.expiresAt -lt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { return }
        $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, 'https://api.anthropic.com/api/oauth/usage')
        $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', [string]$login.accessToken)
        [void]$request.Headers.TryAddWithoutValidation('anthropic-beta', 'oauth-2025-04-20')
        $u.Task = $script:http.SendAsync($request)
    } catch { }
}

function ConvertFrom-UsageTime {
    param($Value)
    if (-not $Value) { return $null }
    try { return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { return $null }
}

# "resets 18:40" today, "resets Mon 18:00" on another day.
function Format-UsageReset {
    param($Value)
    $at = ConvertFrom-UsageTime -Value $Value
    if ($null -eq $at) { return '' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($at.Date -eq (Get-Date).Date) { return 'resets ' + $at.ToString('HH:mm', $inv) }
    return 'resets ' + $at.ToString('ddd HH:mm', $inv)
}

# Draws both bars from the last reading and the two menu switches, and resizes
# the card when a line comes or goes.
function Update-UsageBars {
    $u = $script:usage
    $u.DrawnAt = Get-Date
    $before = '' + $usagePanel.Visibility + ($usageBars | ForEach-Object { $_.Row.Visibility })
    $any = $false
    foreach ($bar in $usageBars) {
        $limit = $null
        if ($null -ne $u.Data) { $limit = $u.Data.($bar.Field) }
        if (-not $script:settings[$bar.Setting] -or $null -eq $limit -or $null -eq $limit.utilization) {
            $bar.Row.Visibility = 'Collapsed'
            continue
        }
        $any = $true
        $bar.Row.Visibility = 'Visible'
        $used = [Math]::Max(0.0, [Math]::Min(100.0, [double]$limit.utilization))
        $bar.Used.Width = New-Object System.Windows.GridLength($used, ([System.Windows.GridUnitType]::Star))
        $bar.Left.Width = New-Object System.Windows.GridLength((100.0 - $used), ([System.Windows.GridUnitType]::Star))
        # By reference, so a change of style recolours it like everything else.
        $bar.Fill.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $(if ($used -ge 80) { 'BrushUsageHigh' } else { 'BrushUsageFill' }))
        $bar.Pct.Text = ('{0:0} %' -f $used)
        $bar.Reset.Text = Format-UsageReset -Value $limit.resets_at
    }
    $usagePanel.Visibility = $(if ($any) { 'Visible' } else { 'Collapsed' })
    $stale = ($null -ne $u.At -and ((Get-Date) - $u.At).TotalMinutes -gt $usageStaleMin)
    $usagePanel.Opacity = $(if ($stale) { 0.45 } else { 1 })
    $usagePanel.ToolTip = $(if ($null -ne $u.At) { 'Claude subscription limits, as of ' + $u.At.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture) } else { $null })
    $after = '' + $usagePanel.Visibility + ($usageBars | ForEach-Object { $_.Row.Visibility })
    if ($after -ne $before) { Update-Layout }
}

# ---------------------------------------------------------------------------
# Tray icon. Doubles as a miniature of the card: it takes the colour of the
# worst state, so the widget still says something while hidden.
# ---------------------------------------------------------------------------
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Text = 'Agent Traffic Light'
$notify.Visible = $true
$script:trayColor = ''
$script:trayIcon = $null

function Set-TrayState {
    param($Rows)
    # A Watching row is Marshal between rounds with nothing for you, so it adds
    # nothing to the tray. Left out entirely rather than counted as working: a
    # card holding only a watching Marshal turns the tray the grey of an empty
    # card, not the blue of a session busy on your behalf.
    $Rows = @($Rows | Where-Object { $_.State -ne 'Watching' })
    $worst = 'Working'
    if (@($Rows | Where-Object { $_.State -eq 'Waiting' }).Count -gt 0) { $worst = 'Waiting' }
    if (@($Rows | Where-Object { $_.State -eq 'Blocked' }).Count -gt 0) { $worst = 'Blocked' }
    if (@($Rows).Count -eq 0) { $worst = 'Empty' }
    if ($worst -eq $script:trayColor) { return }
    $script:trayColor = $worst

    # Brighter than the row fills on purpose: a 12 px dot in the tray has almost
    # no area to carry the colour, so the muted card tones would read as grey.
    $rgb = switch ($worst) {
        'Blocked' { [System.Drawing.Color]::FromArgb(214, 146, 58) }
        'Waiting' { [System.Drawing.Color]::FromArgb(62, 160, 120) }
        'Working' { [System.Drawing.Color]::FromArgb(76, 155, 232) }
        default   { [System.Drawing.Color]::FromArgb(90, 98, 110) }
    }
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $rgb), 2, 2, 12, 12)
    $g.Dispose()
    $h = $bmp.GetHicon()
    $old = $script:trayIcon
    $script:trayIcon = [System.Drawing.Icon]::FromHandle($h)
    $notify.Icon = $script:trayIcon
    if ($old) { [TlNative]::DestroyIcon($old.Handle) | Out-Null }
    $bmp.Dispose()
}

# ---------------------------------------------------------------------------
# New sessions: starting one
# ---------------------------------------------------------------------------
function Show-TrayNote {
    param([string]$Text)
    $notify.ShowBalloonTip(4000, 'Agent Traffic Light', $Text, [System.Windows.Forms.ToolTipIcon]::None)
}

# The terminal takes a moment to open its window, so the card looks for it a
# few times in quick succession instead of on its next three-second sweep.
$script:quickSweeps = 0
function Request-QuickSweeps {
    $script:quickSweeps = 4
    $sweepTimer.Interval = [TimeSpan]::FromMilliseconds(750)
}

# The environment Windows gives a fresh login of this user: the machine's and
# the user's variables, with PATH joined from both, and nothing any process
# set on its way. Windows builds it itself, so it is exactly what a terminal
# opened from the Start menu gets.
function Get-LoginEnvironment {
    if (-not ('TlLoginEnv' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class TlLoginEnv {
    [DllImport("userenv.dll", SetLastError = true)]
    static extern bool CreateEnvironmentBlock(out IntPtr block, IntPtr token, bool inherit);
    [DllImport("userenv.dll", SetLastError = true)]
    static extern bool DestroyEnvironmentBlock(IntPtr block);
    public static Dictionary<string, string> Get() {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        IntPtr block;
        using (var id = WindowsIdentity.GetCurrent()) {
            if (!CreateEnvironmentBlock(out block, id.Token, false)) throw new System.ComponentModel.Win32Exception();
        }
        try {
            IntPtr p = block;
            while (true) {
                string entry = Marshal.PtrToStringUni(p);
                if (string.IsNullOrEmpty(entry)) break;
                int eq = entry.IndexOf('=', 1);
                if (eq > 0 && entry[0] != '=') result[entry.Substring(0, eq)] = entry.Substring(eq + 1);
                p = new IntPtr(p.ToInt64() + (entry.Length + 1) * 2);
            }
        } finally { DestroyEnvironmentBlock(block); }
        return result;
    }
}
'@
    }
    return [TlLoginEnv]::Get()
}

# A card started from a shell that is not a fresh login's, as one a Claude
# session runs commands in when it restarts the card, carries that shell's
# variables, and every session the card starts would inherit them: Claude's
# own markers made a new session take itself for a helper and save no
# transcript, NO_COLOR drew it in grey, and GIT_EDITOR=true would have
# swallowed every commit message typed in it. So the card takes a fresh
# login's environment before each launch.
function Reset-LaunchEnvironment {
    $fresh = Get-LoginEnvironment
    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
        if (-not $fresh.ContainsKey($name)) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
    }
    foreach ($name in @($fresh.Keys)) { [Environment]::SetEnvironmentVariable($name, $fresh[$name], 'Process') }
}

# A new Claude session in a folder, in a terminal window of its own: never a
# tab, since the card follows one session per window. -NoExit leaves a prompt
# in the folder when Claude ends, as typing claude there would.
function Start-ClaudeSession {
    param([string]$Folder, [string]$Resume = '')
    $name = Split-Path -Leaf $Folder
    if (-not [System.IO.Directory]::Exists($Folder)) {
        $script:launchCache = $null
        Show-TrayNote -Text "$name no longer exists"
        return
    }
    try { Reset-LaunchEnvironment } catch { Write-ErrorLog -Where 'launch' -Problem $_ }
    $claude = @('-NoExit', '-Command', 'claude', '--permission-mode', 'auto')
    # A closed session is resumed by its id, which the resumed session keeps.
    if ($Resume) { $claude += @('--resume', $Resume) }
    try {
        $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
        if ($wt) {
            # Start-Process joins the arguments with spaces and quotes nothing.
            Start-Process -FilePath $wt.Source -ArgumentList (@('-w', 'new', '-d', ('"' + $Folder + '"'), 'powershell') + $claude)
        } else {
            Start-Process -FilePath 'powershell.exe' -WorkingDirectory $Folder -ArgumentList $claude
        }
    } catch {
        Write-ErrorLog -Where 'launch' -Problem $_
        Show-TrayNote -Text "Could not open a session in $name"
        return
    }
    # A session asked for is one to see: a card hidden, by hand or by itself,
    # comes back with its row.
    if (-not $window.IsVisible) { $script:autoHidden = $true }
    Request-QuickSweeps
}

function Hide-LaunchRepo {
    param([string]$Path)
    if (@($script:settings.HiddenLaunchRepos | Where-Object { $_ -ieq $Path }).Count -eq 0) {
        $script:settings.HiddenLaunchRepos = @($script:settings.HiddenLaunchRepos) + $Path
        Save-Settings
    }
    $script:launchCache = $null
}

# The tray's New session entry, filled afresh each time the menu opens. A tray
# menu entry shows "&" as the next letter's shortcut, so it is doubled.
function Update-TrayLaunchMenu {
    $newSessionItem.DropDownItems.Clear()
    $repos = @(Get-LaunchMenuRepos)
    if ($repos.Count -eq 0) {
        $none = $newSessionItem.DropDownItems.Add('No recent repos')
        $none.Enabled = $false
        return
    }
    foreach ($repo in $repos) {
        $item = $newSessionItem.DropDownItems.Add(($repo.Name -replace '&', '&&'))
        $item.Tag = $repo.Path
        $item.Add_Click({
            param($sender, $e)
            try { Start-ClaudeSession -Folder ([string]$sender.Tag) } catch { Write-ErrorLog -Where 'launch' -Problem $_ }
        })
    }
    $newSessionItem.DropDownItems.Add('-') | Out-Null
    $hide = New-Object System.Windows.Forms.ToolStripMenuItem 'Hide from this list'
    foreach ($repo in $repos) {
        $item = $hide.DropDownItems.Add(($repo.Name -replace '&', '&&'))
        $item.Tag = $repo.Path
        $item.Add_Click({
            param($sender, $e)
            try { Hide-LaunchRepo -Path ([string]$sender.Tag) } catch { Write-ErrorLog -Where 'launch' -Problem $_ }
        })
    }
    [void]$newSessionItem.DropDownItems.Add($hide)
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
# New session first: with nothing running the card is hidden, and the tray is
# then the only place to start the day's first session from.
$newSessionItem = New-Object System.Windows.Forms.ToolStripMenuItem 'New session'
[void]$menu.Items.Add($newSessionItem)
$menu.Items.Add('-') | Out-Null
$menu.Add_Opening({ try { Update-TrayLaunchMenu } catch { Write-ErrorLog -Where 'launch' -Problem $_ } })
$showItem = $menu.Items.Add('Show / hide')
$showItem.Add_Click({ Set-CardVisible -Visible (-not $window.IsVisible) })
$menu.Items.Add('-') | Out-Null
$quitItem = $menu.Items.Add('Quit')
$quitItem.Add_Click({
    Save-Position
    try { Save-WorkClock } catch { Write-ErrorLog -Where 'workclock' -Problem $_ }
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Application]::Current.Shutdown()
})
$notify.ContextMenuStrip = $menu
$notify.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Set-CardVisible -Visible (-not $window.IsVisible) -Activate
    }
})

# ---------------------------------------------------------------------------
# Window behaviour
# ---------------------------------------------------------------------------
$window.Add_SourceInitialized({
    $helper = New-Object System.Windows.Interop.WindowInteropHelper $window
    $hwnd = $helper.Handle
    # Verified missing by default: without this the card is an Alt-Tab entry,
    # which defeats the point of a thing that is always visible anyway.
    $ex = [TlNative]::GetWindowLong($hwnd, $GWL_EXSTYLE)
    [TlNative]::SetWindowLong($hwnd, $GWL_EXSTYLE, $ex -bor $WS_EX_TOOLWINDOW) | Out-Null
})

$script:pressRow = $null
$script:pressPoint = $null
$script:pressDouble = $false
$script:pressSpot = $null

# The card moves only from where there is no row: its empty edge, the gaps
# between rows and the group headings. Rows handle their own press, so it never
# reaches this.
$window.FindName('Card').Add_MouseLeftButtonDown({
    $script:pressRow = $null
    $window.DragMove()
    Save-Position
})

# The menu button sits on that draggable edge, so its press is taken before it
# can bubble up and start a window drag instead of opening the menu.
$menuButton.Add_MouseLeftButtonDown({
    param($sender, $e)
    $e.Handled = $true
})
$menuButton.Add_MouseLeftButtonUp({
    param($sender, $e)
    try { Show-SettingsMenu } catch { Write-ErrorLog -Where 'settings' -Problem $_ }
    $e.Handled = $true
})

# A press on a row that travels far enough stops being a click and becomes a
# drag of that row within its group. Four pixels is below what a normal click
# produces and above the jitter of a hand resting on the mouse.
$window.Add_MouseMove({
    param($sender, $e)
    try {
        if ($null -ne $script:drag) {
            Move-DraggedRow -PointerY $e.GetPosition($rowCanvas).Y
            return
        }
        if ($null -eq $script:pressRow) { return }
        if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
        $now = $e.GetPosition($window)
        $dx = $now.X - $script:pressPoint.X
        $dy = $now.Y - $script:pressPoint.Y
        if ([Math]::Sqrt($dx * $dx + $dy * $dy) -lt 4) { return }
        $row = $script:pressRow
        $script:pressRow = $null
        Start-RowDrag -Element $row -PointerY $e.GetPosition($rowCanvas).Y
    } catch { Write-ErrorLog -Where 'drag' -Problem $_ }
})

$window.Add_Closing({
    Save-Position
    try { Save-WorkClock } catch { Write-ErrorLog -Where 'workclock' -Problem $_ }
})

# A throw inside a timer tick does not reach the trap above, and an unlogged
# crash in a hidden-console app looks exactly like the widget silently freezing.
$titleTimer = New-Object System.Windows.Threading.DispatcherTimer
$titleTimer.Interval = [TimeSpan]::FromMilliseconds($titlePollMs)
$titleTimer.Add_Tick({
    try { Update-Card } catch { Write-ErrorLog -Where 'poll' -Problem $_ }
})

$sweepTimer = New-Object System.Windows.Threading.DispatcherTimer
$sweepTimer.Interval = [TimeSpan]::FromMilliseconds($windowSweepMs)
$sweepTimer.Add_Tick({
    try { Sweep-Windows } catch { Write-ErrorLog -Where 'sweep' -Problem $_ }
    if ($script:quickSweeps -gt 0) {
        $script:quickSweeps--
        if ($script:quickSweeps -eq 0) { $sweepTimer.Interval = [TimeSpan]::FromMilliseconds($windowSweepMs) }
    }
})

# Running timers turn over on the wall-clock second. Start times are already cut
# to whole seconds, so every row changes together; this timer makes that land
# right on the second instead of whenever the 400 ms poll next comes round,
# which ticked unevenly. It re-aims at the next boundary each time it fires,
# plus a little, so it never lands just before one.
$clockTimer = New-Object System.Windows.Threading.DispatcherTimer
$clockTimer.Interval = [TimeSpan]::FromMilliseconds(1015 - (Get-Date).Millisecond)
$clockTimer.Add_Tick({
    param($sender, $e)
    try { Update-Timers } catch { Write-ErrorLog -Where 'clock' -Problem $_ }
    try { Update-WorkClock } catch { Write-ErrorLog -Where 'workclock' -Problem $_ }
    try { Update-Usage } catch { Write-ErrorLog -Where 'usage' -Problem $_ }
    $sender.Interval = [TimeSpan]::FromMilliseconds(1015 - (Get-Date).Millisecond)
})

Sweep-Windows
$window.Show()
# Once the window has its handle: holds its height through a drag.
[TlMoveSize]::Attach($window)
Update-Card
$titleTimer.Start()
$sweepTimer.Start()
$clockTimer.Start()

$app = New-Object System.Windows.Application
# Hiding the card must not end the process, or the tray icon would go with it.
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$app.Run() | Out-Null

$notify.Visible = $false
$notify.Dispose()
