# Opening new sessions from the card

Date: 2026-10-14

## Goal

Start a new Claude Code session in one of the repos you work in from the card, instead of typing
`draxon` or `claude` in PowerShell or using the Unity button. Almost all sessions run in a handful of
repos (here: `draxonfullstack`, `Draxon-GroundHandling-VR`, `agent-traffic-light`), so the card offers
those, found on its own, with no list to keep.

Not a goal: continuing or resuming an earlier conversation, starting sessions on another machine
(the remote places in `state\remotes.txt`), choosing a permission mode per launch, or a way to
un-hide a repo from the card.

## The repo list

Built from what Claude Code already keeps in `~/.claude/projects`, one folder per working directory
a session ran in, each holding that directory's transcripts (`*.jsonl`).

- For each project folder, count the transcripts last written in the past **14 days**, by file date
  alone. A folder with none is skipped without opening anything.
- Read the working directory from the newest transcript: the first `"cwd":"..."` within its first
  20 KB (JSON-unescaped).
- Turn it into its repo with `Get-RepoRoot`, the lookup the group headers already use (a folder
  holding `.git` or `.plastic`, the nearest one, a worktree counting as the repo it was made from).
  A directory in no repo is left out; this drops `C:\WINDOWS\system32` and the Desktop.
- Counts of folders that land in the same repo are added together, so a session in
  `draxonfullstack\lms-backend` counts towards `draxonfullstack`.
- Left out: a repo whose folder no longer exists, and one named in `HiddenLaunchRepos`.
- Order: most sessions first, ties by name. At most **5**. Each shows as its folder name.
- Built when a menu that shows it opens, and kept for 60 seconds. No timer.

Hiding: `HiddenLaunchRepos`, a list of repo root paths in `state\settings.json`, default empty.
Matching ignores case. Bringing a repo back means removing it from that file by hand.

## Where a session is started

**Tray icon, right-click menu.** A "New session" submenu first, then the existing entries:

```
New session >  draxonfullstack
               Draxon-GroundHandling-VR
               agent-traffic-light
               ---
               Hide from this list >  (the same repos)
---
Show / hide
---
Quit
```

This works while the card is hidden, which it is whenever nothing runs: the first session of the
day starts here.

**Card, the settings menu (the three bars).** The same "New session" submenu, first in the menu,
above the existing settings. Both menus are filled from one list; the tray's is Windows Forms, the
card's WPF, so each has a small builder of its own.

**Card, repo headers.** Hovering a group header fades in a small "+" at its right end; a click starts
a session in that group's repo, tooltip "New session in <name>". Only on headers whose group is a
local repo: not on remote groups (an ssh host) and not on Unity editor rows, where "new session" has
no single meaning. It does not depend on the list, so it works for a hidden repo too.

The "+" is drawn from a new preset key, `IconNew`, a `PathGeometry` in a 16 by 16 box, like
`IconDisconnect` and `IconKill`, with `BrushIconNew` and `BrushIconNewHover` for its colour at rest
and under the pointer. Classic defines all three, so every preset has a plus; a preset may draw its
own.

**No repos to offer** (a fresh install, or all hidden or old): "New session" stays in both menus,
holding one disabled entry, "No recent repos".

## The launch

Each launch opens a new Windows Terminal window, never a tab, because the card follows one session
per window:

```
wt -w new -d "<repo>" powershell -NoExit -Command claude --permission-mode auto
```

`-NoExit` leaves a prompt in the repo when Claude ends, the way `draxon` does. Without `wt.exe`,
`powershell -NoExit -Command claude --permission-mode auto` is started directly with the repo as its
working directory, the fallback `Open-KeptSession` uses.

After a launch the card looks for new windows at once instead of on its next 3 second sweep, so the
row appears quickly.

## Errors

- The repo folder is gone when clicked: nothing starts; a tray balloon says "<name> no longer
  exists"; the cached list is dropped so the next menu leaves it out.
- `wt.exe` or `powershell` fails to start: logged to `state\error.log` under `[launch]`, and a tray
  balloon says the session could not be opened.
- `claude` not on the PATH: PowerShell prints its own error in the new window, which stays open
  because of `-NoExit`. The card does nothing more.
- A transcript that cannot be read, or holds no `cwd` in its first 20 KB: that project folder is
  skipped. A broken `~/.claude/projects` never stops a menu from opening; the list is then empty.

## Checks

The repo has no test suite; it checks itself with `-Probe` and the layout dump, and this follows.

- `-Probe -Launch` prints the list as the menus would build it: each repo with its count, then every
  project folder left out and why (`old`, `no cwd`, `not a repo`, `gone`, `hidden`, `over limit`).
- The layout dump adds `new=` to each header line: `Visible` when its "+" is offered, `Collapsed`
  otherwise.
- By hand: a launch from the tray with the card hidden, from the settings menu, and from a header's
  "+"; hiding a repo; a repo folder renamed away between opening the menu and clicking; the "+" in
  Classic, Frutiger Aero and Caterpillar.
