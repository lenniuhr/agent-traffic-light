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
    [int]$Passes = 0
)

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

    public static System.Collections.Generic.Dictionary<int, int> ParentsOf(string exeName) {
        var map = new System.Collections.Generic.Dictionary<int, int>();
        IntPtr snap = CreateToolhelp32Snapshot(0x00000002, 0); // TH32CS_SNAPPROCESS
        if (snap == new IntPtr(-1)) { return map; }
        PROCESSENTRY32W pe = new PROCESSENTRY32W();
        pe.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
        if (Process32FirstW(snap, ref pe)) {
            do {
                if (string.Equals(pe.szExeFile, exeName, StringComparison.OrdinalIgnoreCase)) {
                    map[(int)pe.th32ProcessID] = (int)pe.th32ParentProcessID;
                }
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
    if ($label -eq '') { $label = 'Session' }
    return @{ State = $state; Label = $label }
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
    $claudeParents = [TlNative]::ParentsOf('claude.exe')

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

    $script:sessionByHwnd = $map
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
            if ($null -eq $cached) { $cached = @{ Model = ''; Prompt = 0 } }
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
# Sounds maps a terminal window handle to the sound that window's session plays
# when it needs you, '' being Off picked on purpose. Keyed by window like the row
# order, so a sound survives a /clear, a new session in the same window and a
# restart of the card, and it is dropped when the window closes. A window with no
# entry follows DefaultSound, which is Off until one is picked; nothing is copied
# from it, so changing it changes every window that follows it.
# ---------------------------------------------------------------------------
$settingsFile = Join-Path $stateDir 'settings.json'
$script:settings = @{ ShowUnityEditors = $true; GroupByRepo = $false; DefaultSound = ''; Preset = 'Classic'; Sounds = @{} }

function Read-Settings {
    try {
        $saved = Get-Content $settingsFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($null -ne $saved.ShowUnityEditors) { $script:settings.ShowUnityEditors = [bool]$saved.ShowUnityEditors }
        if ($null -ne $saved.GroupByRepo) { $script:settings.GroupByRepo = [bool]$saved.GroupByRepo }
        if ($null -ne $saved.DefaultSound) { $script:settings.DefaultSound = [string]$saved.DefaultSound }
        if ($saved.Preset) { $script:settings.Preset = [string]$saved.Preset }
        if ($null -ne $saved.Sounds) {
            foreach ($entry in $saved.Sounds.PSObject.Properties) {
                $script:settings.Sounds[[string]$entry.Name] = [string]$entry.Value
            }
        }
    } catch { }
}

function Save-Settings {
    try {
        [pscustomobject]@{
            ShowUnityEditors = $script:settings.ShowUnityEditors
            GroupByRepo      = $script:settings.GroupByRepo
            DefaultSound     = $script:settings.DefaultSound
            Preset           = $script:settings.Preset
            Sounds           = [pscustomobject]$script:settings.Sounds
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
                Memory      = [int64]0
                Cpu         = 0.0
            }
        }
        $entry = $byProject[$key]

        try { $entry.Memory += [int64]$process.WorkingSet64 } catch { }

        if ($commandLine -match 'AssetImportWorker') {
            $entry.Workers += 1
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

# Headers are pooled rather than created and destroyed, because a workspace
# appearing and disappearing is common and rebuilding elements on a 400 ms
# timer would churn the visual tree for nothing.
function Get-Header {
    param([int]$Index)
    while ($script:headerPool.Count -le $Index) {
        $element = Import-Xaml 'Header.xaml'
        $rowCanvas.Children.Add($element) | Out-Null
        [void]$script:headerPool.Add(@{
            Element = $element
            Label   = $element.FindName('HeaderLabel')
            Swatch  = $element.FindName('Swatch')
            Icon    = $element.FindName('Icon')
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
# Stage 1: console probe. Kept in the shipping script so the parsing can always
# be checked against reality without the UI in the way.
# ---------------------------------------------------------------------------
if ($Probe) {
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

# XAML is read from the tool's folder. Each file is read with its own folder as
# its base, so a preset can name an image that sits next to it.
$xamlRoot = $PSScriptRoot
function Import-Xaml {
    param([string]$Name)
    $path = Join-Path $xamlRoot $Name
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
    $dict = Import-Xaml (Join-Path 'presets' "$Name.xaml")
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
    return $dict
}

# Puts a preset over Classic in place of the one there now, or takes it away.
function Use-PresetLayer {
    param($Dict)
    $merged = $window.Resources.MergedDictionaries
    while ($merged.Count -gt 1) { $merged.RemoveAt(1) }
    if ($null -ne $Dict) { [void]$merged.Add($Dict) }
}

# Classic first, then the others by name.
function Get-PresetNames {
    $others = @(Get-ChildItem $presetDir -Filter '*.xaml' -File |
                ForEach-Object { $_.BaseName } | Where-Object { $_ -ne 'Classic' } | Sort-Object)
    return @('Classic') + $others
}

[void]$window.Resources.MergedDictionaries.Add((Import-Xaml 'presets\Classic.xaml'))
$script:preset = 'Classic'
try {
    Use-PresetLayer -Dict (Import-Preset -Name $script:settings.Preset)
    $script:preset = $script:settings.Preset
} catch { Write-ErrorLog -Where 'style' -Problem $_ }
$rowCanvas = $window.FindName('RowCanvas')
$warnText  = $window.FindName('WarnText')
$workClock     = $window.FindName('WorkClock')
$workClockText = $window.FindName('WorkClockText')
$workClockSub  = $window.FindName('WorkClockSub')
$menuButton    = $window.FindName('MenuButton')

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
        TextOnWait     = $window.FindResource('BrushTextOnWait')
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
# apart. It only runs while some row is working, so a card of finished sessions
# still costs nothing to draw.
$script:spinTurn = New-Object System.Windows.Media.RotateTransform
$script:spinAnimation = New-Object System.Windows.Media.Animation.DoubleAnimation
$script:spinAnimation.From = 0.0
$script:spinAnimation.To = 360.0
$script:spinAnimation.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds($spinTurnMs)
$script:spinAnimation.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
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
        CtxFill   = $element.FindName('CtxFill')
        SoundMark = $element.FindName('SoundMark')
        Spinner   = $element.FindName('Spinner')
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
    }

    $element.Tag = $Handle
    $rec.Spinner.RenderTransform = $script:spinTurn
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
        } elseif ($script:pressRow -eq $sender) {
            [TlNative]::Focus([IntPtr]$sender.Tag) | Out-Null
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
            }

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

    if ($State -eq 'Working') {
        $Rec.WorkSince = Get-WholeSecond -At $now
        $Rec.FinishedAt = $null
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

# The note on every row, after a row's choice or the default has changed.
function Update-SoundMarks {
    foreach ($rec in $rows.Values) {
        $mark = $(if (Get-RowSound -Key ([string][int64]$rec.Handle)) { 'Visible' } else { 'Collapsed' })
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
    $pitch = $script:rowHeight + $rowGap
    $first = [double]$slots.Top
    $last = $first + ($slots.Count - 1) * $pitch
    # Held inside its own group: a session cannot be dropped among another
    # workspace's rows, so its row cannot travel past its group's ends either.
    $top = [Math]::Max($first, [Math]::Min($last, $PointerY - $drag.Offset))
    [System.Windows.Controls.Canvas]::SetTop($drag.Rec.Element, $top)
    $drag.Rec.Top = $top
    $target = [int][Math]::Round(($top - $first) / $pitch)
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
    [void]$lines.Add(('{0:o}  drag={1}  order={2}  preset={3}  pitch={4}  height={5}' -f (Get-Date), ($null -ne $script:drag),
        ($script:userOrder -join ','), $script:preset, ($script:rowHeight + $rowGap), $window.Height))
    foreach ($name in @($script:groupOrder.Keys)) {
        [void]$lines.Add("group $name")
        foreach ($rec in @($script:groupOrder[$name])) {
            $drawn = [System.Windows.Controls.Canvas]::GetTop($rec.Element)
            [void]$lines.Add(('  top={0,-6} drawn={1,-6} started={2:HH:mm:ss} seq={3,-3} hwnd={4,-9} idx={5,-4} {6}' -f
                $rec.Top, [Math]::Round($drawn, 1),
                [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$rec.StartedAt).LocalDateTime,
                $rec.Seq, [int64]$rec.Handle, $script:orderIndex[[string][int64]$rec.Handle], $rec.Label))
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

    $seen = @{}

    foreach ($h in @($script:knownHandles)) {
        $title = Get-WindowTitle -Handle $h
        if ($null -eq $title) {
            # Window is gone. Drop it now rather than waiting for the sweep, so
            # a closed session never lingers on the card.
            $script:knownHandles.Remove($h)
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
        if (-not $rows.ContainsKey($key)) {
            $rows[$key] = New-Row -Handle $h -Label $parsed.Label -State $parsed.State
        }
        $rows[$key].PendingState = $parsed.State
        $rows[$key].PendingLabel = $parsed.Label
        $seen[$key] = $true
    }

    foreach ($key in @($rows.Keys)) {
        if (-not $seen.ContainsKey($key)) {
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
        $rec.PendingDetail = ''
        $rec.RoundAt = $null
        if (-not (Test-MarshalRow -Cwd $rec.Cwd -Label $rec.PendingLabel)) { continue }
        $look = Get-MarshalLook -State $rec.PendingState -Report (Read-MarshalReport -Path $marshalReportFile) -Now (Get-Date)
        $rec.PendingState  = $look.State
        $rec.PendingDetail = $look.Detail
        $rec.RoundAt       = $look.RoundAt
    }

    foreach ($rec in $ordered) {
        Set-RowState -Rec $rec -State $rec.PendingState -Label $rec.PendingLabel -Detail $rec.PendingDetail
    }
    Update-Needs -Ordered $ordered

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
    $body += $workClock.Height + $workClock.Margin.Top
    return $body + $shadowMargin * 2
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
        $script:groupSlots[$g.Name] = @{ Top = $y; Count = $inGroup.Count }
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

            $y += $script:rowHeight + $rowGap
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
    if ($liveFiles -gt $count) {
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
}

# Caught on its own, so a Unity hiccup can never stop the agent rows updating.
# With the group switched off nothing is collected at all, so the switch also
# takes the cost away, not only the rows.
function Update-UnityRows {
    try {
        if ($script:settings.ShowUnityEditors) {
            $script:unityEditors = @(Get-UnityEditors)
        } else {
            $script:unityEditors = @()
        }
        Sync-UnityRows
    } catch { Write-ErrorLog -Where 'unity' -Problem $_ }
}

# The card's own menu, behind the three bars left of the session clock.
function Show-SettingsMenu {
    $menu = New-CardMenu

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
    [void]$menu.Items.Add($unityItem)

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
    [void]$menu.Items.Add($repoItem)

    [void]$menu.Items.Add((New-CardMenuSeparator))
    [void]$menu.Items.Add((New-DefaultSoundMenu))
    [void]$menu.Items.Add((New-StyleMenu))

    $menu.PlacementTarget = $menuButton
    $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $menu.IsOpen = $true
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

$menu = New-Object System.Windows.Forms.ContextMenuStrip
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
    $sender.Interval = [TimeSpan]::FromMilliseconds(1015 - (Get-Date).Millisecond)
})

Sweep-Windows
$window.Show()
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
