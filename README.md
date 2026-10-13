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

Each row also shows the model in the coloured stripe on its left, and a thin bar along its bottom
showing how much of the context window is in use. The bar turns amber past 80 %.

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
bottom edge; or Caterpillar, a light hazard print: pale board with a register lattice, a black frame
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
