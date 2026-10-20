# Agent Traffic Light

An always-on-top card for Windows that shows the live state of every coding agent session you have
open, so a session that has finished or is waiting on a permission prompt gets noticed without
hunting through terminal windows.

It currently supports [Claude Code](https://claude.com/claude-code) CLI sessions running in Windows
Terminal. The name is generic on purpose, so other agents can be added later.

## What it shows

One row per session, grouped under the folder its terminal was opened in, or with "Group by working
repository" on, under the repository the session is really working in:

| Row | Meaning |
| --- | --- |
| Dark row, turning ring | Working. The time on the right counts up. |
| Green row | Finished and waiting for you. The time on the right is when it stopped. |
| Amber row, pulsing | Blocked on you: a permission prompt or a question. |
| Dark row, dimmed label, no ring, no dot | Watching: only the Marshal session, between rounds, with nothing for you. The time on the right is when its last round ended. |

The blue dot means this session wants something from you that you have not opened yet. It shows
on a green or amber row until that session's terminal window comes to the front, whether by
clicking the row, Alt+Tab or the taskbar, or because it already was in front when the session
stopped. Opening clears only the dot; the row keeps its colour. The dot comes back when the
session finishes again or asks something new, so the rows with a dot are the ones still to
handle. After the card itself restarts, every waiting session shows its dot again until opened.

"Group by working repository" is off by default and switched in the card's settings. With it on,
the repository comes from transcripts, so it needs no hook and nothing from the agent, and it works
for sessions that were already open: the session's own, and those of the helper agents it starts,
which is where a session that delegates its work does it. Every file read or written, every folder
a shell command names, and the shell's folder once that has moved count as votes for the
repository (a folder with `.git`, or `.plastic` for a Plastic workspace) they lie in. The card
keeps a running list of each session's votes, adding what every transcript has gained since the
last look; the repository with the most of the last 48 votes wins, and a tie keeps the current
one. A session that has touched no repository yet sits under the folder its terminal was opened
in. Marshal always stays under its own folder.

Marshal is a long-running coordinator session that runs a round every 15 minutes and idles in
between, so by its title alone it would sit green with a blue dot all day. The card finds its row by
the session's folder, `%USERPROFILE%\Marshal`, falling back to the window title "Marshal" only until
the folder is known. While a round runs the row is Working as usual. Between rounds it follows
`state\marshal.json`, which Marshal writes at the end of every round as
`{"needsYou": bool, "open": int, "summary": string, "at": ISO 8601 time}`: with `needsYou` true the
row is Blocked, with the summary on a second line under the label and its sound if one is set;
otherwise it is Watching. A missing report also reads as Watching, and one not rewritten for more
than 40 minutes adds a "stale" note, because that means Marshal has stopped. The tray colour ignores
a Watching row, but it still counts as a session, so the card does not hide.

Remote sessions show too, with a second line under the label saying where they are and what
closing them does. A terminal here running ssh to another machine is grouped under that host's
name and says "connected", and whether the session "keeps running when closed" (it runs in tmux
there) or "ends when closed". A session on this PC started from another machine, over ssh or
through WSL, has no terminal window here; its row says where it is connected from, takes its state
from the session's own busy or idle and its label from the session's task title.

A session of this PC stays on the card when its terminal closes or its Claude ends, as a slim faded
row of its title and when it closed, "closed 17:11". A click on it, or on its Resume button, a play
triangle, opens a new terminal in its folder running `claude --resume` with its id; the new
window's row takes the closed row's place. A row's buttons, shown in the time's place while the
pointer is on the row, are Close, which closes the window and keeps the row to resume, and Kill, a
skull, which asks, then closes the window and takes the session off the card. On a closed row Kill
only takes it off. The closed rows are kept in
`state\closed.json` across restarts of the card, and the sessions open now in `state\open.json`,
so a session that ends while the card is not running, at a shutdown say, is a closed row when the
card next starts. Writing `resume <session id>` or `forget <session id>` into `state\closed.flag`
does the same as a click or Kill on that closed row, for checks.

Sessions that keep running with no window connected to them stay on the card too, drawn faded and
marked "not connected, still running". Pointing at one shows "Reconnect", and a click opens a
terminal attached to it. Every such row carries two buttons, shown in the time's place while the
pointer is on the row: Disconnect, while a window here shows the session, closes that window and
leaves Claude running; Kill, a skull, stops Claude where it runs, after asking. The right-click
menu offers the same, in words. A preset draws the icons (`IconDisconnect`, `IconClose`,
`IconKill`, each a PathGeometry in a 16 by 16 box) and colours them at rest and under the
pointer. For that the card asks each
place listed in `state\remotes.txt`, one per line, every few seconds, and at once whenever a window
to it opens or closes: an ssh target such as `jonathan@office`, or `wsl` for this PC's own WSL
(`wsl:Ubuntu` names the distribution, needed when Docker Desktop has made itself the default). A
place answers with `office-sessions --list`, which lists its tmux sessions as
`name|window|state|claude session id|title`, and `office-sessions --end <name>` ends one. A place
that cannot be asked gets a row saying so, or asking for the sign-in Tailscale wants now and then.
On a machine several people use, such as the build PC, the list holds everyone's sessions, with the
owner's first name in front of the ones others started. "Show other people's sessions", on by
default under Settings, hides those when switched off: the card then asks with
`office-sessions --list --mine`. A place whose `office-sessions` predates `--mine` lists everything
either way.

Along the card's bottom, two bars show how much of the Claude subscription's limits is used: the
five-hour window and the week, each with the time it resets. The card reads the login Claude Code
keeps in `~/.claude/.credentials.json` and asks the endpoint Claude's own `/usage` reads, every
three minutes; it never refreshes the login itself. A reading more than 15 minutes old is dimmed.
Each bar is switched on and off under Settings in the card's menu.

New sessions start from the card. "New session" in the tray icon's menu, which is there while the
card is hidden, and first in the card's own menu, lists the repos Claude ran in over the last two
weeks, most used first, at most five: found in `~/.claude/projects`, with folders outside any repo,
gone or older left out. Each opens a new Windows Terminal window in that repo running
`claude --permission-mode auto`. "Hide from this list" leaves one out for good; it is kept as
`HiddenLaunchRepos` in `state\settings.json`, and taken out of there to bring it back. Pointing at a
repo's heading also shows a "+" right after its name, in the name's own style, which opens a
session in that folder. With "Group by working repository" on it opens the session in the folder
the heading's sessions were started in, the one most of them used, so a heading for a repository
inside a larger checkout starts the new session at the checkout's top, as its sessions were.
`-Probe -Launch` prints the list and why each other folder was left out.

Each row also shows the model in the coloured stripe on its left, and a thin bar along its bottom
showing how much of the context window is in use. The bar turns amber past 80 %.

A session with helper agents running shows a larger turning ring with their number inside, helpers
of helpers included, in place of the small ring. It shows on a row of any colour, in place of the
blue dot on a green row whose background helpers still run, and the dot comes back when the last
one ends. A helper counts until its meta file in the session's `subagents` folder says it
finished, or its own transcript ends on Claude's "Request interrupted by user" note, which is how
a stopped helper drops off at once. One untouched for half an hour, or left over from before a
resumed session started again, no longer counts. A remote session's count comes from its place, which adds it to its list
when asked with `office-sessions --list --helpers`; a place without that shows no count.

Right-click a session's row for its menu: Bring to front, Maximize window (or Put window back), and
Sound, which opens a list on hover: Default, naming the default sound, then Off and every sound, with
a tick on the current one. A note on the row shows that it has a sound. The sound plays every time
that session starts needing you, its row turning Waiting or Blocked, once per time rather than over
and over while it waits, across restarts of the card. It follows that session's own agent, so
subagents finishing inside it never trigger it, and different sessions can have different sounds. A
Marshal round in between does not count as a new need, so an open question sounds once, not every
round. The choice belongs to the terminal window and goes away when the window closes.

A session left on Default plays the default sound, picked under "Default sound" in the card's
settings and Off until one is. Changing the default changes it for every session on Default,
including those already open; a session with Off or a sound of its own keeps it.

The three bars left of the session clock open the card's settings, saved in `state\settings.json`.

Under Style the settings pick the card's look, applied on the spot: Classic, the card as described
here; Terminal, square, flat and monospaced, with denser rows drawn as boxes in the state's colour; or
Phosphor, a glowing green monochrome screen where, with one colour to work with, a row gets louder
the more it needs you: plain text while working, a bright box when finished, inverse video when
blocked; or Frutiger Aero, see-through glass from sky blue to green in the manner of Windows Vista
and 7, with glossy rows, bubbles and a halo behind the text; or Synthwave, the neon eighties of
Outrun, with every row a neon tube and a striped sunset sun over a glowing grid on the card's
bottom edge; or Elden Ring, Limgrave under the Erdtree's light in colours measured from the game,
with beams, motes of grace and golden leaves, gold corner brackets, a glowing clock and Cinzel
throughout; or Caterpillar, a light hazard print: pale board with a register lattice, a black frame
with a dashed acid green tread, rows that turn acid green when finished and black with amber when
blocked, and an icon on each workspace heading in place of the coloured square. Its stripes are
black, each session prints a white pattern of its own on its stripe, so it can be found again at a
glance, and the model's name shows on hovering the stripe; Unity editors are green, pale when
headless.

Five more come from the themes of the Nightjar audio studio. Two of them share Caterpillar's
stripes, patterns and heading icons in their own inks: Emulsion, a two colour print in key black and
fluorescent pink on lilac stock, with a hard pink offset for a shadow and registration crosses down
the margins, where finished is the pink plate rather than green; and Blueprint, a cyanotype on ruled
paper with every row drawn as an outline in its state's colour. The other three colour their
stripes by workspace and keep the model's name on them: Office, a 1970s mixing desk in warm
aluminium with lit push buttons, fader cap stripes and an orange lamp for the dot; Starburst, a
1999 homepage in Windows 98 grey with bevelled rows, loud web colours, homepage icons, a rainbow
under the title bar and five clashing faces: Comic Sans, a shaded WordArt clock, a script, comic
book capitals and a terminal face; and Tungsten, the game's main menu render behind smoked panes,
in black and white only, with white hairlines, grey stripes, a serif, and blocked rows in photo
negative.

Frutiger Aero costs noticeably more CPU than the others, for the halo on every text.
Each style is a file in `presets\`, a picture a style draws, such as Tungsten's backdrop, sits
in `presets\art\`, and a free font a style uses sits in `presets\fonts\` with its licence. Classic holds every colour, size, corner, outline, font and
shadow the card uses; any other preset holds only what it changes and is laid over Classic, so a new
one starts as a copy of Terminal with its values changed. Whatever the style, the colours keep their
meaning, except where a style says otherwise.

With "Show Unity editors" on, which is the default, a Unity group below the sessions lists every
running Unity editor, one row per project: the
project folder, whether it runs headless (sand stripe) or with a window (grey stripe), its Plastic
branch, and its memory and CPU with its asset import workers included. It is there mainly for
headless editors, which have no window or taskbar button to tell you they are still running.
Clicking an editor with a window brings it to the front. While the group is on, the card stays
visible as long as any editor runs.

The card also keeps headless editors from taking over the machine. Each one, with its import
workers, may use at most 25 % of the whole processor, and runs at idle priority, so anything you do
comes first. Right-clicking an editor's row picks its CPU limit, from No limit to 75 %, and the
choice is kept for that project. An editor with a window has no limit unless its row picks one.
Memory is never limited, because a hard memory limit crashes Unity. The limits hold whether the
Unity group is shown or not. A limited editor stays limited if the card closes, and an editor
started while the card is closed is limited once the card starts.

Clicking a row brings that session's window to the front. Double-clicking it maximizes the window
on the primary display, and double-clicking it again puts the window back exactly where it was:
same display, position, size, and normal, minimized or maximized. Only one window is maximized this
way at a time, so double-clicking another row first puts the previous window back. A window moved
by hand in between is left where it is, and the next double-click maximizes it afresh. Dragging a
row reorders it within its group, and the order is remembered. Drag the card by its empty edge to
move it.

The tray icon takes the colour of the most urgent row. Left click hides or shows the card; right
click quits. The card hides itself when no session is open.

The colours avoid red against green, the pair colour-blind people most often cannot separate.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in)
- Claude Code CLI, each session in its own Windows Terminal window

## Install

Clone or download this repository to wherever you want it to live, then run the installer once from
inside it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The installer:

1. Registers two hooks in `~/.claude/settings.json`. It keeps a backup of the file first, and
   restores the original if the edit looks wrong.
2. Adds an "Agent Traffic Light" shortcut to Startup, so the card starts at login, and to the Start
   Menu.
3. Starts the card.

Running it again is safe. It never duplicates hooks or shortcuts, and if you move the folder it
points the hooks at the new place.

However the card is started, from the shortcut, a terminal or an agent, it hands over at once to a
copy of itself with no console window, so it never shows as a terminal and closing a terminal never
ends it. Quit it from the tray icon.

## How it works

The card needs no configuration and no daemon. It reads three things:

- **Terminal window titles.** Claude Code puts a spinner glyph at the front of the window title
  while it works and `✳` while it waits. That gives the working and waiting states, and the title
  itself is the row's label.
- **Session files** in `~/.claude/sessions/`. The card links each window to its session through
  the process chain from the session to its shell to the terminal window, which gives the folder,
  the start time and the session id.
- **Two hooks.** The title has no sign for "blocked on a permission prompt", so a `Notification`
  hook writes a small marker file for that session and a `UserPromptSubmit` hook removes it.

It polls window titles every 400 ms and looks for new windows every 3 s. A full check takes about
10 ms.

Model and context come from the tail of each session's transcript, read only when that file
changes.

## Troubleshooting

If the card stays empty, check what it can see:

```powershell
powershell -File .\AgentTrafficLight.ps1 -Probe -Passes 3
```

This prints every agent window it finds, its state and its folder.

To see how the live card has laid out its rows, create an empty file called `state\dump.flag`.
The card writes its layout to `state\dump.txt` on its next poll.

Errors from the hidden card are logged to `state\error.log`.

## Limits

- **One session per window.** With two sessions as tabs in one window, only the active tab's title
  can be read. The card shows a warning when it counts more sessions than rows.
- **The title format is not a documented interface.** If a Claude Code update changes the glyphs,
  the card stops finding windows. `-Probe` is the quickest way to check.
- **Context is an estimate.** It is taken from the last reported token usage and measured against a
  fixed 1M-token window.
- Sessions inside the Claude desktop app are not shown, because they have no terminal window.
- A topmost window cannot draw over the Windows security prompt or over exclusive-fullscreen apps.

## Uninstall

1. Quit from the tray icon.
2. Delete the two "Agent Traffic Light" shortcuts from Startup (`shell:startup`) and the Start Menu.
3. Remove the two hook entries with `"statusMessage": "traffic light"` from `~/.claude/settings.json`.
4. Delete the folder.

## License

MIT, see [LICENSE](LICENSE).
