# New Session Launch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start a new Claude Code session in a recent repo from the tray menu, the card's settings menu, or a "+" on a repo heading.

**Architecture:** One function builds the repo list from `~/.claude/projects` (file dates, one `cwd` read per project folder, `Get-RepoRoot`), cached for 60 seconds. One function starts a session in a folder (`wt -w new ... claude --permission-mode auto`). The tray menu (Windows Forms) and the settings menu (WPF) each have a small builder over that list; the heading "+" calls the launcher with its group's folder.

**Tech Stack:** Windows PowerShell 5.1, WPF via `XamlReader`, Windows Forms for the tray, no build step, no test framework (checks run through `-Probe` and the layout dump).

**Spec:** `docs/superpowers/specs/2026-10-14-new-session-launch-design.md`

## Global Constraints

- Windows PowerShell 5.1; `AgentTrafficLight.ps1` is read as ANSI without a BOM: no literal non-ASCII characters in it.
- 14 days, at most 5 repos, 60 second cache, first 20 KB of a transcript: named variables in the Tuning style (`$launchDays`, `$launchMax`, `$launchCacheSec`, `$launchCwdBytes`).
- Launch command, exactly: `wt -w new -d "<folder>" powershell -NoExit -Command claude --permission-mode auto`; without `wt.exe`: `powershell -NoExit -Command claude --permission-mode auto` with the folder as working directory.
- Hidden repos live in `state\settings.json` as `HiddenLaunchRepos`, a list of root paths, default empty, matched ignoring case.
- Errors go to `state\error.log` under `[launch]`; a menu must open even when the list cannot be built.
- Match the surrounding code: comments explain why, in full sentences; functions are `Verb-Noun`; WPF menu entries use `New-CardMenuItem` and `Add-CardMenuAction`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; commit with a message file or heredoc.

## Review Focus

1. A repo name holding `_` or `&` shows as typed in both menus. Pinned in Task 3, Step 3 (the escape helper is checked on `a_b&c`).
2. A transcript being written by a live session while the list reads it: the read must share the file and never block or fail the menu. Pinned in Task 1, Step 4 (the fixture holds one transcript open for writing while the probe runs).
3. A project folder whose `cwd` no longer exists but whose parent is a repo must read as `gone`, not as that parent repo. Pinned in Task 1 by the fixture's `p-gone`, whose missing folder sits inside the repo `alpha`.
4. The card hidden with no rows, a launch from the tray: the new row shows and the card comes back by itself. Checked by hand in Task 2, Step 6.
5. Pressing the heading "+" must not start a card drag or a row drag. Checked by hand in Task 4, Step 7.

## Shared test setup

All commands run in Windows PowerShell from the repository root. Check scripts and fixtures live in
the session scratchpad:

```powershell
$Repo = 'C:\Users\LennartUhrmacher\wkspaces\agent-traffic-light'
$Scratch = 'C:\Users\LENNAR~1\AppData\Local\Temp\claude\C--Users-LennartUhrmacher-wkspaces-agent-traffic-light\e59ad5cc-b074-40a1-bf46-9518611e669f\scratchpad'
```

`$Scratch\live.ps1`, dot-sourced by the checks that need the running card:

```powershell
$Repo = 'C:\Users\LennartUhrmacher\wkspaces\agent-traffic-light'
function Restart-Card {
    Get-CimInstance Win32_Process |
        Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -match '-File.*AgentTrafficLight\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
    Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-STA',
        '-WindowStyle','Hidden','-File',(Join-Path $Repo 'AgentTrafficLight.ps1')
    Start-Sleep -Seconds 8
}
function Get-Dump {
    Set-Content (Join-Path $Repo 'state\dump.flag') 'x'
    Start-Sleep -Seconds 2
    Get-Content (Join-Path $Repo 'state\dump.txt')
}
function Get-NewErrors([datetime]$Since) {
    $log = Join-Path $Repo 'state\error.log'
    if (-not (Test-Path $log)) { return @() }
    @(Get-Content $log | Where-Object { $_ -match '^\d{4}-' -and [datetime]::Parse($_.Substring(0, 33)) -gt $Since })
}
```

---

### Task 1: The repo list, and `-Probe -Launch`

**Files:**
- Modify: `AgentTrafficLight.ps1` (param block; settings at `Read-Settings`/`Save-Settings`; a new section just before the "Stage 1: console probe" banner; the probe block)
- Test: `$Scratch\fixture.ps1`

**Interfaces:**
- Produces: `Get-LaunchRepos -ProjectsDir <string> -Hidden <string[]> -Now <datetime>` returning `@{ Repos = @(@{ Path; Name; Count }); Skipped = @(@{ Folder; Why }) }`; `Get-LaunchMenuRepos` returning the cached `Repos` array; `$script:launchCache` (set to `$null` to force a rebuild); `$script:settings.HiddenLaunchRepos`.

- [ ] **Step 1: Write the fixture check**

`$Scratch\fixture.ps1` builds fake repos and project folders, runs the probe over them, and compares:

```powershell
$Repo = 'C:\Users\LennartUhrmacher\wkspaces\agent-traffic-light'
$F = Join-Path $PSScriptRoot 'fixture'
if (Test-Path $F) { Remove-Item $F -Recurse -Force }
$repos = Join-Path $F 'repos'; $projects = Join-Path $F 'projects'
foreach ($r in 'alpha', 'beta', 'r1', 'r2', 'r3', 'r4') { New-Item -ItemType Directory -Force (Join-Path $repos "$r\.git") | Out-Null }
New-Item -ItemType Directory -Force (Join-Path $repos 'alpha\sub'), (Join-Path $repos 'plain') | Out-Null
function Add-Project([string]$Name, [string]$Cwd, [int]$Count, [int]$DaysAgo = 0) {
    $dir = New-Item -ItemType Directory -Force (Join-Path $projects $Name)
    for ($i = 0; $i -lt $Count; $i++) {
        $file = Join-Path $dir "s$i.jsonl"
        $line = if ($Cwd) { '{"type":"user","cwd":"' + ($Cwd -replace '\\', '\\') + '","sessionId":"x"}' } else { '{"type":"mode"}' }
        Set-Content $file $line
        (Get-Item $file).LastWriteTime = (Get-Date).AddDays(-$DaysAgo).AddMinutes(-$i)
    }
}
Add-Project 'p-alpha'    (Join-Path $repos 'alpha') 3
Add-Project 'p-alphasub' (Join-Path $repos 'alpha\sub') 2
Add-Project 'p-beta'     (Join-Path $repos 'beta') 4
foreach ($r in 'r1', 'r2', 'r3', 'r4') { Add-Project "p-$r" (Join-Path $repos $r) 1 }
Add-Project 'p-plain'    (Join-Path $repos 'plain') 1
Add-Project 'p-gone'     (Join-Path $repos 'alpha\vanished') 1
Add-Project 'p-old'      (Join-Path $repos 'beta') 1 30
Add-Project 'p-nocwd'    '' 1
# A transcript a live session holds open for writing.
$held = [System.IO.File]::Open((Join-Path $projects 'p-beta\s0.jsonl'), 'Open', 'ReadWrite', 'ReadWrite')
try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'AgentTrafficLight.ps1') -Probe -Launch -ProjectsDir $projects
} finally { $held.Dispose() }
$out | ForEach-Object { "  | $_" }
$expect = @(
    '^\s+5\s+alpha\s', '^\s+4\s+beta\s', '^\s+1\s+r1\s', '^\s+1\s+r2\s', '^\s+1\s+r3\s',
    '^\s+skip\s+over limit\s+r4', '^\s+skip\s+old\s+p-old', '^\s+skip\s+no cwd\s+p-nocwd',
    '^\s+skip\s+not a repo\s+p-plain', '^\s+skip\s+gone\s+p-gone'
)
$fail = @($expect | Where-Object { $p = $_; -not ($out | Where-Object { $_ -match $p }) })
$order = @($out | Where-Object { $_ -match '^\s+\d+\s' } | ForEach-Object { ($_ -split '\s+')[2] }) -join ','
if ($order -ne 'alpha,beta,r1,r2,r3') { $fail += "order was $order" }
if ($fail.Count) { "FAIL:"; $fail } else { 'PASS' }
```

- [ ] **Step 2: Run it to see it fail**

Run: `powershell -NoProfile -File "$Scratch\fixture.ps1"`
Expected: FAIL, every pattern missing (the probe does not know `-Launch` and runs the window probe, or errors on the unknown parameter).

- [ ] **Step 3: Implement**

Param block:

```powershell
param(
    [switch]$Probe,
    # Probe passes to run before exiting. 0 runs until Ctrl+C.
    [int]$Passes = 0,
    # With -Probe: print the repos the New session menus offer, and every
    # project folder left out and why, instead of the windows.
    [switch]$Launch,
    # With -Probe -Launch: read this folder in place of ~/.claude/projects, so
    # the list can be checked against a made-up one.
    [string]$ProjectsDir = ''
)
```

Settings: add `HiddenLaunchRepos = @()` to the `$script:settings` literal; in `Read-Settings`
`if ($null -ne $saved.HiddenLaunchRepos) { $script:settings.HiddenLaunchRepos = @($saved.HiddenLaunchRepos | ForEach-Object { [string]$_ }) }`;
in `Save-Settings` `HiddenLaunchRepos = @($script:settings.HiddenLaunchRepos)`. Extend the settings comment block with one paragraph:
"HiddenLaunchRepos lists repo folders the New session menus leave out. Added from those menus; taken out again only by editing this file."

New section before the probe banner:

```powershell
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
$launchCwdBytes = 20480
$claudeProjects = Join-Path $env:USERPROFILE '.claude\projects'
$script:launchCache = $null

# The folder a transcript's session ran in, or '' when its first lines do not
# say. Shared for writing, since the newest transcript is often one a live
# session is still writing.
function Read-TranscriptCwd {
    param([string]$Path)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
        $buffer = New-Object byte[] $launchCwdBytes
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        $m = [regex]::Match($text, '"cwd":"((?:[^"\\]|\\.)*)"')
        if ($m.Success) { return [regex]::Unescape($m.Groups[1].Value) }
    } catch { } finally { if ($stream) { $stream.Dispose() } }
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
```

In the probe block, first thing inside `if ($Probe) {`:

```powershell
    if ($Launch) {
        $dir = $(if ($ProjectsDir) { $ProjectsDir } else { $claudeProjects })
        $list = Get-LaunchRepos -ProjectsDir $dir -Hidden @($script:settings.HiddenLaunchRepos)
        # Written to the output, not the host, so a check script can capture it.
        foreach ($r in $list.Repos) { Write-Output ('  {0,4}  {1,-28} {2}' -f $r.Count, $r.Name, $r.Path) }
        foreach ($s in $list.Skipped) { Write-Output ('  skip  {0,-10}  {1}' -f $s.Why, $s.Folder) }
        return
    }
```

- [ ] **Step 4: Run the fixture check**

Run: `powershell -NoProfile -File "$Scratch\fixture.ps1"`
Expected: `PASS`.

- [ ] **Step 5: Run against the real projects folder**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\AgentTrafficLight.ps1 -Probe -Launch`
Expected: `draxonfullstack`, `Draxon-GroundHandling-VR`, `agent-traffic-light`, `AgentTrafficLight` with counts; `C--WINDOWS-system32` and `C--users-...-Desktop` skipped (`old` or `not a repo`).

- [ ] **Step 6: Commit**

```bash
git add AgentTrafficLight.ps1
git commit -F - <<'EOF'
Find the repos to offer new sessions in, and print them with -Probe -Launch

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 2: Starting a session, and the tray menu

**Files:**
- Modify: `AgentTrafficLight.ps1` (a launcher after `Set-TrayState`; the tray menu; the sweep timer)

**Interfaces:**
- Consumes: `Get-LaunchMenuRepos`, `$script:launchCache`, `$script:settings.HiddenLaunchRepos`, `Save-Settings`.
- Produces: `Start-ClaudeSession -Folder <string>`, `Hide-LaunchRepo -Path <string>`, `Show-TrayNote -Text <string>`, `Request-QuickSweeps`.

- [ ] **Step 1: Implement the launcher**

After `Set-TrayState`:

```powershell
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

# A new Claude session in a folder, in a terminal window of its own: never a
# tab, since the card follows one session per window. -NoExit leaves a prompt
# in the folder when Claude ends, as typing claude there would.
function Start-ClaudeSession {
    param([string]$Folder)
    $name = Split-Path -Leaf $Folder
    if (-not [System.IO.Directory]::Exists($Folder)) {
        $script:launchCache = $null
        Show-TrayNote -Text "$name no longer exists"
        return
    }
    $claude = @('-NoExit', '-Command', 'claude', '--permission-mode', 'auto')
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
```

Sweep timer tick becomes:

```powershell
$sweepTimer.Add_Tick({
    try { Sweep-Windows } catch { Write-ErrorLog -Where 'sweep' -Problem $_ }
    if ($script:quickSweeps -gt 0) {
        $script:quickSweeps--
        if ($script:quickSweeps -eq 0) { $sweepTimer.Interval = [TimeSpan]::FromMilliseconds($windowSweepMs) }
    }
})
```

- [ ] **Step 2: Implement the tray menu**

Replace the tray menu block's start with:

```powershell
$menu = New-Object System.Windows.Forms.ContextMenuStrip
# New session first: with nothing running the card is hidden, and the tray is
# then the only place to start the day's first session from. Filled each time
# the menu opens, from the list the card's own menu uses.
$newSessionItem = New-Object System.Windows.Forms.ToolStripMenuItem 'New session'
[void]$menu.Items.Add($newSessionItem)
$menu.Items.Add('-') | Out-Null
$menu.Add_Opening({ try { Update-TrayLaunchMenu } catch { Write-ErrorLog -Where 'launch' -Problem $_ } })
$showItem = $menu.Items.Add('Show / hide')
```

and add, before it:

```powershell
# A tray menu entry shows "&" as the next letter's shortcut, so it is doubled.
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
```

`Update-TrayLaunchMenu` refers to `$newSessionItem` at call time, so it may be defined before the variable.

- [ ] **Step 3: Restart and check startup**

Run: `. "$Scratch\live.ps1"; $t = Get-Date; Restart-Card; Get-NewErrors $t`
Expected: no lines.

- [ ] **Step 4: Check the menu by hand**

Right-click the tray icon. Expected: "New session" first, holding the repos in the probe's order, a separator, "Hide from this list" with the same repos; then "Show / hide", "Quit".

- [ ] **Step 5: Launch from the tray**

Click "New session > agent-traffic-light". Expected: a new Windows Terminal window in the repo running Claude in auto mode; within about 2 s `Get-Dump` lists a new row under `group agent-traffic-light`. Close that window afterwards.

- [ ] **Step 6: The card hidden**

With every session closed except this one, use "Show / hide" to hide the card, then launch from the tray. Expected: the row appears and the card shows itself when the new window's row arrives (Review Focus 4). If closing sessions is not practical, check instead that a hidden card comes back on a tray launch.

- [ ] **Step 7: Commit**

```bash
git add AgentTrafficLight.ps1
git commit -F - <<'EOF'
Start new sessions from the tray menu

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 3: The settings menu

**Files:**
- Modify: `AgentTrafficLight.ps1` (a builder near `New-StyleMenu`; `Show-SettingsMenu`)

**Interfaces:**
- Consumes: `Get-LaunchMenuRepos`, `Start-ClaudeSession`, `Hide-LaunchRepo`, `New-CardMenuItem`, `New-CardMenuSeparator`, `Add-CardMenuAction`.
- Produces: `New-LaunchMenu` returning a `MenuItem`; `ConvertTo-MenuHeader -Text <string>`.

- [ ] **Step 1: Implement**

```powershell
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
```

In `Show-SettingsMenu`, right after `$menu = New-CardMenu`:

```powershell
    [void]$menu.Items.Add((New-LaunchMenu))
    [void]$menu.Items.Add((New-CardMenuSeparator))
```

- [ ] **Step 2: Restart and check startup**

Run: `. "$Scratch\live.ps1"; $t = Get-Date; Restart-Card; Get-NewErrors $t`
Expected: no lines.

- [ ] **Step 3: Check the escape helper**

`ConvertTo-MenuHeader` and the tray's `-replace '&', '&&'` are one-liners; check both on `a_b&c` in a plain shell:
Run: `'a_b&c' -replace '_', '__'; 'a_b&c' -replace '&', '&&'`
Expected: `a__b&c` and `a_b&&c` (Review Focus 1).

- [ ] **Step 4: Check by hand**

Click the three bars. Expected: "New session" first with the repos, a separator, then the existing entries. Launch one; expected as Task 2, Step 5. Hide `AgentTrafficLight` from this menu; wait over a minute or restart the card; expected: it is gone from both menus and `state\settings.json` lists it under `HiddenLaunchRepos` as an array.

- [ ] **Step 5: Commit**

```bash
git add AgentTrafficLight.ps1
git commit -F - <<'EOF'
Offer New session first in the card's menu

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 4: The "+" on repo headings, and the README

**Files:**
- Modify: `Header.xaml`, `presets/Classic.xaml` (after `IconKill` and its brushes), `AgentTrafficLight.ps1` (`Get-Header`, `Update-Layout`, `Write-LayoutDump`, a new `Get-GroupFolder`), `README.md`

**Interfaces:**
- Consumes: `Start-ClaudeSession`, `Get-RepoRoot`, `Set-Fade`.
- Produces: header records gain `NewButton`; `Get-GroupFolder -Name <string> -Recs <array>` returning a path or `''`; `$script:groupNew[<name>]` holding the button's visibility for the dump.

- [ ] **Step 1: Header.xaml**

Wrap the existing `StackPanel` in a `Grid` (the `StackPanel` keeps its attributes), and add after it, inside the `Grid`:

```xml
    <!-- New session in this group's folder, at the heading's right end where
         the rows have their buttons. Shown by the script only for a group
         whose rows have a folder on this PC, and faded in while the pointer
         is on the heading, so a calm card shows no extra marks. -->
    <Border x:Name="NewButton" Width="24" Height="20" Margin="0,0,8,1" Cursor="Hand"
            HorizontalAlignment="Right" VerticalAlignment="Bottom" Opacity="0" Visibility="Collapsed"
            CornerRadius="{DynamicResource IconButtonCorner}"
            BorderThickness="{DynamicResource IconButtonEdgeThickness}">
      <Border.Style>
        <Style TargetType="Border">
          <Setter Property="Background" Value="{DynamicResource BrushIconButtonBg}" />
          <Setter Property="BorderBrush" Value="{DynamicResource BrushIconButtonEdge}" />
          <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter Property="Background" Value="{DynamicResource BrushNewHoverBg}" />
              <Setter Property="BorderBrush" Value="{DynamicResource BrushNewHoverEdge}" />
            </Trigger>
          </Style.Triggers>
        </Style>
      </Border.Style>
      <Path Width="16" Height="16" Stretch="None" HorizontalAlignment="Center" VerticalAlignment="Center"
            SnapsToDevicePixels="True" Data="{DynamicResource IconNew}"
            RenderOptions.EdgeMode="{DynamicResource IconEdgeMode}">
        <Path.Style>
          <Style TargetType="Path">
            <Setter Property="Fill" Value="{DynamicResource BrushIconButton}" />
            <Style.Triggers>
              <DataTrigger Binding="{Binding IsMouseOver, ElementName=NewButton}" Value="True">
                <Setter Property="Fill" Value="{DynamicResource BrushNewHoverIcon}" />
              </DataTrigger>
            </Style.Triggers>
          </Style>
        </Path.Style>
      </Path>
    </Border>
```

- [ ] **Step 2: Classic keys**

After `BrushKillHoverEdge` in `presets/Classic.xaml`:

```xml
  <!-- The "+" at a repo heading's right end, starting a new session there. On
       whole pixels, so it stays sharp where a preset draws icons aliased. -->
  <PathGeometry x:Key="IconNew" Figures="M7,3 H9 V7 H13 V9 H9 V13 H7 V9 H3 V7 H7 Z" />
  <SolidColorBrush x:Key="BrushNewHoverBg"           Color="#3A4250" />
  <SolidColorBrush x:Key="BrushNewHoverIcon"         Color="#E8EBEF" />
  <SolidColorBrush x:Key="BrushNewHoverEdge"         Color="Transparent" />
```

- [ ] **Step 3: Wire the pooled headers**

In `Get-Header`, add `NewButton = $element.FindName('NewButton')` to the record, and after creating it:

```powershell
        $newButton = $element.FindName('NewButton')
        # Fades in with the pointer anywhere on the heading, not only on the
        # button, so it is there by the time the pointer reaches it.
        $element.Tag = $newButton
        $element.Add_MouseEnter({ param($sender, $e) if ($sender.Tag.Visibility -eq 'Visible') { Set-Fade -Element $sender.Tag -To 1 } })
        $element.Add_MouseLeave({ param($sender, $e) Set-Fade -Element $sender.Tag -To 0 })
        # Its own press, so it neither drags the card nor reaches a row.
        $newButton.Add_MouseLeftButtonDown({ param($sender, $e) $e.Handled = $true })
        $newButton.Add_MouseLeftButtonUp({
            param($sender, $e)
            $e.Handled = $true
            try { if ($sender.Tag) { Start-ClaudeSession -Folder ([string]$sender.Tag) } } catch { Write-ErrorLog -Where 'launch' -Problem $_ }
        })
```

- [ ] **Step 4: The group's folder**

Next to `Set-HeaderMark`:

```powershell
# The folder a heading's "+" starts a session in: the one its rows' sessions
# started in, or with GroupByRepo on the repository the heading names. Only a
# row with a session on this PC has a folder, so a group on another machine
# gets no "+".
function Get-GroupFolder {
    param([string]$Name, $Recs)
    foreach ($rec in @($Recs)) {
        if (-not $rec.Cwd) { continue }
        $cwd = ([string]$rec.Cwd).TrimEnd('\')
        if ((Split-Path -Leaf $cwd) -ieq $Name -and [System.IO.Directory]::Exists($cwd)) { return $cwd }
        $root = Get-RepoRoot -Path $cwd
        if ($root -and (Split-Path -Leaf $root) -ieq $Name) { return $root }
    }
    return ''
}
```

In `Update-Layout`: next to `$script:groupOrder = @{}` add `$script:groupNew = @{}`; in the `if ($showThisGroup)` block after `Set-HeaderMark`:

```powershell
            $folder = Get-GroupFolder -Name $g.Name -Recs $g.Group
            $header.NewButton.Tag = $folder
            $header.NewButton.Visibility = $(if ($folder) { 'Visible' } else { 'Collapsed' })
            $header.NewButton.ToolTip = $(if ($folder) { 'New session in ' + $g.Name } else { $null })
            $script:groupNew[$g.Name] = $header.NewButton.Visibility
```

In the Unity heading block, after its `Set-HeaderMark`: `$header.NewButton.Visibility = 'Collapsed'; $header.NewButton.Tag = ''`.

In `Write-LayoutDump`, the group line becomes `[void]$lines.Add("group $name  new=$($script:groupNew[$name])")`.

- [ ] **Step 5: Restart and check the dump**

Run: `. "$Scratch\live.ps1"; $t = Get-Date; Restart-Card; Get-Dump | Select-String '^group'; Get-NewErrors $t`
Expected: `group agent-traffic-light  new=Visible`, `group draxonfullstack  new=Visible`, `group Draxon-GroundHandling-VR  new=Visible`; no errors.

- [ ] **Step 6: README**

Under "How it works", after the paragraph about the limit bars, add:

```markdown
New sessions start from the card. "New session" in the tray icon's menu, which is there while the
card is hidden, and first in the card's own menu, lists the repos Claude ran in over the last two
weeks, most used first, at most five: found in `~/.claude/projects`, with folders outside any repo,
gone or older left out. Each opens a new Windows Terminal window in that repo running
`claude --permission-mode auto`. "Hide from this list" leaves one out for good; it is kept as
`HiddenLaunchRepos` in `state\settings.json`, and taken out of there to bring it back. Pointing at a
repo's heading also shows a "+" at its right end, which opens a session in that folder. A preset
draws it as `IconNew`. `-Probe -Launch` prints the list and why each other folder was left out.
```

- [ ] **Step 7: Check by hand**

Hover a heading: the "+" fades in; leave: it fades out. Press it and drag a little before releasing: the card does not move. Click it: a session opens in that folder. Switch the style to Frutiger Aero and to Caterpillar: the "+" is there and sharp.

- [ ] **Step 8: Commit**

```bash
git add Header.xaml presets/Classic.xaml AgentTrafficLight.ps1 README.md
git commit -F - <<'EOF'
Open a session from a repo heading's "+", and describe New session in the README

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```
