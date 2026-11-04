# Switching sessions between the subscription and Bedrock

Date: 2026-11-04

## Why

The user runs Claude Code on the Claude subscription and falls back to Amazon Bedrock when the
subscription's usage limit is full. Today that means typing `/exit` in the session, then starting
Claude again with `--settings <bedrock file>`, from a shell function that only works in one folder.
Sessions the card starts or resumes always run plain `claude`, so they always land on the
subscription.

The card already starts and resumes sessions by id. So it is the natural place for the switch:
choose Bedrock under Settings, and every session the card starts or resumes runs there. Moving a
running session is the row's Close, then its Resume, both of which exist today.

The card is meant for anyone: the user's work PC, their home PC, a colleague's PC, a stranger from
GitHub. Nothing about the user's own AWS setup may be in the code.

## Goals

- Pick what sessions the card starts or resumes run on: the subscription or a Bedrock setup.
- See on each row which setup it runs on.
- Work on any machine with no paths, profiles or model names in the code.

## Non-goals

- A one-click move of a running session. Close, switch under Settings, then Resume does it (the
  user's call).
- A note or prompt when a usage limit is full (the user's call: overkill).
- Moving all sessions at once.
- Sessions on other machines, over ssh or through WSL. Their settings files live there.
- Creating a Bedrock setup, AWS login or credentials. A machine that uses this already has Bedrock
  working in Claude Code, login done (the user's call).
- Google Vertex, Microsoft Foundry or API keys. The list format can hold their settings files, but
  the card neither finds them nor knows how to switch them off. (My call.)
- Showing what Bedrock costs.

## Anti-goals

- The card moving work onto a paid AWS account without the user choosing it.
- Any user-specific path, AWS profile, region or model id in the code or the committed files.
- A visible change for someone without Bedrock: no new menu entries, no tag.

## How a setup is described

A setup is a Claude settings file that turns Bedrock on, like the user's
`~/.claude/bedrock-settings.json`:

```json
{ "env": { "CLAUDE_CODE_USE_BEDROCK": "1", "AWS_PROFILE": "<your profile>", "AWS_REGION": "<region>",
           "ANTHROPIC_MODEL": "<model id>" } }
```

Starting a session on it means adding `--settings "<file>"` to the claude command. Claude lays that
file over the user's own settings. The card never reads or shows the AWS details inside; it only
needs to know that the file turns Bedrock on.

"Turns Bedrock on" means `env.CLAUDE_CODE_USE_BEDROCK` is `1` or `true` (any case).

## The list of setups

Kept per machine in `state\settings.json`, which is already per machine and not in git:

```json
"Providers": [ { "Name": "bedrock", "File": "C:\\Users\\me\\.claude\\bedrock-settings.json" } ],
"DefaultProvider": "Subscription"
```

- "Subscription" is always there, first, and is not stored in `Providers`.
- `DefaultProvider` holds a name from the list. When missing or unknown, sessions start as plain
  `claude` did before: on "Bedrock (your settings)" where Bedrock is already the default, else on
  "Subscription". So updating the card changes nothing on a machine already on Bedrock.
- Names are unique, ignoring case.

**Filled by itself.** While `Providers` is missing from `state\settings.json`, the card looks in
`~/.claude` at every start for `*.json` files that turn Bedrock on. Once it finds any, it adds each
and saves the list, and stops looking at start. An empty result is not saved, so a machine that sets
up Bedrock after the card's first run picks it up at the next start. (My call.) The name is the file
name without `.json`, and without a `settings` part and the dash next to it:
`bedrock-settings.json` becomes "bedrock", `bedrock-br-lennart-settings.json` becomes
"bedrock-br-lennart". A file that fails to parse is skipped. `settings.json` itself is not a setup
(see "When Bedrock is already the default").

**Changing it.** Under Settings, a "Find Bedrock settings" entry looks again and adds files not yet
listed; it never removes. Renaming and removing are done by hand in `state\settings.json`, as
`HiddenLaunchRepos` is today. (My call: a rename box in a WPF menu is a lot of work for something
done once.)

**A file that has gone** stays in the list, shown greyed with "(file missing)". Starting a session on
it refuses with a tray note naming the file.

## When Bedrock is already the default

On some machines plain `claude` already goes to Bedrock:

1. `env.CLAUDE_CODE_USE_BEDROCK` turns Bedrock on in `~/.claude/settings.json`.
2. The variable is set in the user's Windows environment, which the card's launches inherit through
   `Get-LoginEnvironment`.

The card checks both whenever it builds the list. When either holds, the list gains a built-in
entry, "Bedrock (your settings)", which starts plain `claude`, and "Subscription" must turn Bedrock
off for that one launch:

- remove `CLAUDE_CODE_USE_BEDROCK` from the launch environment, after `Reset-LaunchEnvironment`, and
- pass `--settings` a file the card writes into `state\`, `{"env":{"CLAUDE_CODE_USE_BEDROCK":"0"}}`,
  which outranks the user's own settings.

**Builder must verify first:** that Claude treats `"0"` as off, and that a `--settings` file's `env`
outranks `env` in `~/.claude/settings.json`. If either fails, find what does turn it off before
building the rest of this section. If nothing does, "Subscription" shows greyed with the note
"Bedrock is on in your settings", and the Bedrock setups still switch among themselves. (My call.)
On a machine where neither case holds, as on the user's, this section does nothing.

Project and local settings (`.claude/settings.json` in a repo) that turn Bedrock on are not checked.
`--settings` outranks them too, so "Subscription" still wins if the override works.

## Where it shows

Nothing below appears when the list holds only "Subscription".

**Settings, "New sessions on".** A submenu listing every setup, a tick on `DefaultProvider`. Choosing
one saves it. "Find Bedrock settings" sits under it.

**New session, New session in, the "+" on a heading, Resume on a closed row.** All start on
`DefaultProvider`, as plain `claude` or `claude --resume <id>` plus that setup's `--settings`. Any
other flags a resumed session was started with are dropped, as Resume does today (the user's call).
Remote launches through `claude-in` are untouched.

**The tag.** A row running on a Bedrock setup shows a small tag with the setup's name, and its
tooltip says "Runs on Bedrock: <name>". A closed row shows the setup it last ran on. Subscription rows
show nothing. The tag uses brushes every preset already has, so no preset needs a change (my call).
Where it sits on a row this narrow is the builder's call.

## Knowing a session's setup

- **Started by the card:** the card knows, and keeps it with the session.
- **Started from a shell:** the card reads the `claude.exe` command line, as it already does for
  other processes through `Win32_Process`, and takes the path after `--settings`. A path in the list
  is that setup. A path not in the list that turns Bedrock on is tagged with its file name. No
  `--settings`: "Bedrock (your settings)" when Bedrock is the default here, else Subscription.
- **Closed rows:** the setup is saved with the row in `state\closed.json`, so the tag survives a
  restart of the card.

A session started with `CLAUDE_CODE_USE_BEDROCK` set by hand in its shell shows as whatever the
machine's default is. The card cannot read another process's variables cheaply. Accepted.

## Constraints

- Windows PowerShell 5.1, WPF, Windows Terminal, as the card is now. No new dependencies.
- Launch goes through `Start-ClaudeSession`. Its command passes through `wt.exe`, then
  `powershell -Command`, so a settings path with spaces must survive both. Test with one.
- Old `state\settings.json` and `state\closed.json` files without the new keys must load.
- `-Probe -Providers` prints the list, the default, which files were found or skipped and why, and
  whether Bedrock is already the default here. This matches `-Probe -Launch`. (My call.)

## README

A section saying what the switch does, where the list is kept, how to rename or remove a setup by
hand, and how to move a running session: Close its row, choose the setup under Settings, Resume. One
caveat: the first turn after such a move cannot use the previous setup's prompt cache, so on a long
session it bills the whole conversation at full input price.

## Left to the builder

- Where the tag sits on the row and how it is drawn.
- How the setup is kept with an open session in the card's state.
