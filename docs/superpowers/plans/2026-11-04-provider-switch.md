# Provider Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the card start and resume sessions on the Claude subscription or on a Bedrock setup chosen under Settings, and tag each row with the setup it runs on.

**Architecture:** A setup is a Claude settings file that turns Bedrock on; the card finds them in `~/.claude`, keeps the list per machine in `state\settings.json`, and starts a session on one by adding `--settings '<file>'` to the claude command. A session's setup is read back from its `claude.exe` command line, so sessions started by the card and from a shell are told apart the same way. Everything is checked through `-Probe -Providers`, the layout dump, and a few launches by hand.

**Tech Stack:** Windows PowerShell 5.1, WPF via `XamlReader`, Windows Terminal, Claude Code 2.1.318. No build step, no test framework.

**Spec:** `docs/superpowers/specs/2026-11-04-provider-switch-design.md`

## Global Constraints

- Windows PowerShell 5.1; `AgentTrafficLight.ps1` is read as ANSI without a BOM: no literal non-ASCII characters in it.
- "Turns Bedrock on" means `env.CLAUDE_CODE_USE_BEDROCK` is `1` or `true`, any case. Nothing else counts.
- `state\settings.json` keys: `Providers`, a list of `{ Name, File }`, missing until discovery finds something; `DefaultProvider`, a name, default `Subscription`.
- Built-in entry names, exactly: `Subscription` and `Bedrock (your settings)`.
- Nothing appears on the card or in a menu when the list holds only `Subscription`.
- Old `state\settings.json`, `state\open.json` and `state\closed.json` without the new keys must load with no entry in `state\error.log`.
- No user path, AWS profile, region or model id in the code or committed files. Fixtures live in the scratchpad.
- Remote launches through `claude-in` (`Start-KeptSession`, `Open-KeptSession`) are not touched.
- Errors go to `state\error.log` under `[providers]`; a menu must still open when the list cannot be built.
- Match the surrounding code: comments explain why, in full sentences; functions are `Verb-Noun`; WPF menu entries use `New-CardMenuItem` and `Add-CardMenuAction`, headers go through `ConvertTo-MenuHeader`.
- Work on branch `provider-switch`. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; commit with a message file or heredoc.

## Review Focus

1. A setup file whose path holds a space or an apostrophe must launch and be recognised. Pinned in Task 2, Step 6 (launch by hand from `with space\it's settings.json`) and Task 3, Step 1 (probe case `quoted`).
2. `~/.claude` holds large unrelated JSON files (`stats-cache.json`); discovery must not read them whole at every start. Pinned in Task 1, Step 1 (fixture `huge.json` is skipped as `too large`).
3. A setup named with `_` shows as typed in the menu, not as an access key. Pinned in Task 4, Step 3 (fixture name `bedrock_eu`).
4. Saved state from before this change loads cleanly, and a missing `Providers` key triggers discovery once. Pinned in Task 1, Step 5 and Task 3, Step 6 (restart on the old files, no new errors).
5. A listed setup whose file was deleted: greyed in the menu, launch refused with a tray note, no crash. Pinned in Task 4, Step 4.

## Shared test setup

All commands run in Windows PowerShell from the repository root.

```powershell
$Repo = 'C:\Users\LennartUhrmacher\wkspaces\agent-traffic-light'
$Scratch = 'C:\Users\LENNAR~1\AppData\Local\Temp\claude\ab90de2987870248\f494ed2b-b31a-4ff9-8dbc-24504367e5ad\scratchpad'
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
function Get-ClaudeCommandLines {
    @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" | ForEach-Object { $_.CommandLine })
}
```

Before Task 1, copy `state\settings.json`, `state\open.json` and `state\closed.json` to `$Scratch\state-before\`. They are the "old state" for Review Focus 4, and are put back after the last task.

---

### Task 1: The list of setups, and `-Probe -Providers`

**Files:**
- Modify: `AgentTrafficLight.ps1`: param block; `$script:settings`, `Read-Settings`, `Save-Settings`; a new section "Bedrock setups" just after `Get-LaunchMenuRepos`, before the "Stage 1: console probe" banner; move `Get-LoginEnvironment` (now in "New sessions: starting one") up into that section unchanged; the probe block; a call to `Initialize-Providers` right after `Read-Settings` runs.
- Test: `$Scratch\fixture1.ps1`

**Interfaces:**
- Produces:
  - Params `[switch]$Providers` and `[string]$ClaudeDir = ''`, both probe-only.
  - `$claudeDir` (`~\.claude`), `$setupMaxBytes = 262144`.
  - `Test-BedrockOn([string]$Value) -> bool`.
  - `Read-SettingsEnv([string]$Path) -> hashtable` of the file's `env`, empty when it has none; throws on unreadable or invalid JSON.
  - `Get-SetupName([string]$File) -> string`.
  - `Find-BedrockFiles([string]$Dir) -> @{ Found = @(@{ Name; File }); Skipped = @(@{ File; Why }) }`, `Why` one of `main settings`, `too large`, `unreadable`, `not bedrock`.
  - `Test-BedrockDefault([string]$Dir, [hashtable]$Environment) -> string`: `''`, `'settings'` or `'environment'`.
  - `Get-Providers([string]$Dir = $claudeDir) -> array of @{ Name; File; Kind; Missing }`, `Kind` one of `Subscription`, `YourSettings`, `File`. Order: Subscription, then YourSettings when Bedrock is the default here, then the saved entries in their order.
  - `Get-DefaultProvider -> hashtable`, the entry named by `DefaultProvider`, else Subscription.
  - `Add-FoundSetups([array]$Found) -> int`, appends entries whose `File` is not listed yet (ignoring case), renaming clashes, saves, returns how many it added.
  - `Initialize-Providers`, discovery at start.
  - `$script:settings.Providers` (`$null` while missing) and `$script:settings.DefaultProvider`.

- [ ] **Step 1: Write the fixture check**

`$Scratch\fixture1.ps1` builds `$Scratch\fake-claude\` afresh and checks the probe's output against these files and expected lines:

| File | Content | Expected line |
| --- | --- | --- |
| `bedrock-settings.json` | `{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}` | `  setup  bedrock  <path>` |
| `bedrock-br-x-settings.json` | `{"env":{"CLAUDE_CODE_USE_BEDROCK":"TRUE"}}` | `  setup  bedrock-br-x  <path>` |
| `settings-aws.json` | `{"env":{"CLAUDE_CODE_USE_BEDROCK":"true"}}` | `  setup  aws  <path>` |
| `bedrock_eu.json` | `{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}` | `  setup  bedrock_eu  <path>` |
| `other.json` | `{"env":{"CLAUDE_CODE_USE_BEDROCK":"0"}}` | `  skip   not bedrock  other.json` |
| `plain.json` | `{"theme":"dark"}` | `  skip   not bedrock  plain.json` |
| `broken.json` | `{` | `  skip   unreadable  broken.json` |
| `huge.json` | 300 KB of valid JSON that turns Bedrock on | `  skip   too large  huge.json` |
| `settings.json` | `{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}` | `  skip   main settings  settings.json` |
| `notes.txt` | anything | no line |

It runs the probe twice and checks the last line each time:

```powershell
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File "$Repo\AgentTrafficLight.ps1" -Probe -Providers -ClaudeDir "$Scratch\fake-claude"
# settings.json turns Bedrock on, so:   '  bedrock default: settings'
Remove-Item "$Scratch\fake-claude\settings.json"
$env:CLAUDE_CODE_USE_BEDROCK = '1'
$out2 = & powershell ... same ...
# expected last line:                   '  bedrock default: environment'
Remove-Item Env:\CLAUDE_CODE_USE_BEDROCK
```

The columns are separated by two spaces; the check compares lines with runs of spaces collapsed to one. Each run must print the `setup` lines in file-name order, then the `skip` lines in file-name order, then the default line, and nothing else. It prints `PASS` or every line that differs.

- [ ] **Step 2: Run it to see it fail**

Run: `powershell -NoProfile -File "$Scratch\fixture1.ps1"`
Expected: FAIL, the probe does not know `-Providers` and prints the window sweep.

- [ ] **Step 3: Implement the section and the probe**

In the new "Bedrock setups" section, with the interfaces above:
- `Get-SetupName`: the base name without `.json`; then, ignoring case, `-settings-` becomes `-`, and a leading `settings-` or a trailing `-settings` goes. If that leaves nothing, keep the base name.
- `Find-BedrockFiles`: only `*.json` directly in `$Dir`. `settings.json` is skipped first, then files over `$setupMaxBytes`, before anything is read.
- `Test-BedrockDefault`: `'settings'` when `$Dir\settings.json` turns Bedrock on, else `'environment'` when `$Environment['CLAUDE_CODE_USE_BEDROCK']` does, else `''`.
- `Add-FoundSetups`: a clashing name, compared ignoring case with every name in `Get-Providers`, gets ` 2`, ` 3` and so on.
- `Get-Providers`: an entry's `Missing` is true when its file does not exist.
- `Initialize-Providers`: when `$script:settings.Providers` is `$null`, run `Find-BedrockFiles $claudeDir`; when something is found, set `Providers` to an empty list, call `Add-FoundSetups`; otherwise change nothing and save nothing. Wrap in `try`, log under `[providers]`.
- `Read-Settings` and `Save-Settings`: `Providers` is written only when not `$null`, so an empty result stays missing.

The probe block, before `if ($Launch)`: with `-Providers`, take `$dir` from `-ClaudeDir` or `$claudeDir`, and the environment from the current process (`[Environment]::GetEnvironmentVariables('Process')`) when `-ClaudeDir` is given, else from `Get-LoginEnvironment`. Print the `setup` and `skip` lines, then `  bedrock default: <settings|environment|none>`, and return. With `-ClaudeDir`, nothing is read from or saved to `state\settings.json`.

- [ ] **Step 4: Run the fixture to see it pass**

Run: `powershell -NoProfile -File "$Scratch\fixture1.ps1"`
Expected: `PASS`.

- [ ] **Step 5: Check discovery on the real machine and old state**

```powershell
. "$Scratch\live.ps1"; $t = Get-Date
& powershell -NoProfile -File "$Repo\AgentTrafficLight.ps1" -Probe -Providers
Restart-Card
(Get-Content "$Repo\state\settings.json" -Raw | ConvertFrom-Json).Providers
Get-NewErrors $t
```

Expected: the probe lists `bedrock` and `bedrock-br-lennart` as setups and `bedrock default: none`; after the restart `Providers` holds those two entries; no new errors. A card with only Subscription is unchanged on screen.

- [ ] **Step 6: Commit**

```bash
git add AgentTrafficLight.ps1
git commit -F <message file: "Find Bedrock setups in ~/.claude and list them with -Probe -Providers">
```

---

### Task 2: Starting sessions on a setup

**Files:**
- Modify: `AgentTrafficLight.ps1`: `Start-ClaudeSession`; a new function next to it.
- Test: `$Scratch\override\` (Step 1), launches by hand (Step 6).

**Interfaces:**
- Consumes: `Get-DefaultProvider`, `Test-BedrockDefault`, `Get-LoginEnvironment`, `$claudeDir` from Task 1.
- Produces:
  - `$subscriptionFile = Join-Path $stateDir 'subscription-settings.json'`, written when missing with exactly `{"env":{"CLAUDE_CODE_USE_BEDROCK":"0"}}`.
  - `Get-ProviderLaunch([hashtable]$Provider, [string]$BedrockDefault) -> @{ Args = string[]; ClearBedrock = bool }`.
  - `Start-ClaudeSession -Folder <string> [-Resume <string>] [-Provider <hashtable>]`; no `-Provider` means `Get-DefaultProvider`.

- [ ] **Step 1: Verify that a `--settings` file turns Bedrock off**

The spec makes this the first thing to settle. It sends two one-word prompts on the subscription.

```powershell
New-Item -ItemType Directory -Force "$Scratch\override\.claude" | Out-Null
Set-Content "$Scratch\override\.claude\settings.json" '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","AWS_REGION":"xx-nowhere-1"}}'
Set-Content "$Scratch\override\off.json" '{"env":{"CLAUDE_CODE_USE_BEDROCK":"0"}}'
Push-Location "$Scratch\override"
claude -p "Reply with the word ok" --model haiku                                   # A
claude -p "Reply with the word ok" --model haiku --settings "$Scratch\override\off.json"   # B
$env:CLAUDE_CODE_USE_BEDROCK = '1'
claude -p "Reply with the word ok" --model haiku --settings "$Scratch\override\off.json"   # C
Remove-Item Env:\CLAUDE_CODE_USE_BEDROCK; Pop-Location
```

Expected: A fails with an AWS or Bedrock error, B and C answer `ok`. Project settings rank above user settings, so B passing means a `--settings` file outranks both. If A answers `ok`, the project settings were not applied and B proves nothing: report that instead of guessing. If B or C does not answer `ok`, stop and report: the spec's fallback (Subscription greyed) needs the user's go before it is built.

- [ ] **Step 2: Implement `Get-ProviderLaunch`**

| Provider `Kind` | Bedrock default here | `Args` | `ClearBedrock` |
| --- | --- | --- | --- |
| `File` | any | `--settings`, quoted `File` | false |
| `YourSettings` | any | none | false |
| `Subscription` | `''` | none | false |
| `Subscription` | `settings` or `environment` | `--settings`, quoted `$subscriptionFile` | true |

Quoted means wrapped in single quotes with each `'` inside doubled, since the command reaches `powershell -Command` as text. A `;` in the path is escaped as `\;` for `wt.exe`, which reads a bare `;` as its own separator.

- [ ] **Step 3: Change `Start-ClaudeSession`**

Resolve the provider. When its `Missing` is true, show the tray note `"<name>: settings file not found"`, log the path under `[providers]`, and return before anything starts. After `Reset-LaunchEnvironment`, when `ClearBedrock` is true, remove `CLAUDE_CODE_USE_BEDROCK` from the process environment and write `$subscriptionFile` if missing. Append `Args` to `$claude` after `claude` and after any `--resume <id>`. Both the `wt.exe` and the plain `powershell.exe` paths take the same `$claude`.

- [ ] **Step 4: Check that a subscription launch is unchanged**

With `DefaultProvider` missing, start "New session" in this repo from the card's menu.

```powershell
. "$Scratch\live.ps1"; Restart-Card; Get-ClaudeCommandLines
```

Expected: the new `claude.exe` has no `--settings`. Close that window.

- [ ] **Step 5: Check a launch on a setup**

Set `"DefaultProvider": "bedrock"` in `state\settings.json` by hand, `Restart-Card`, start "New session" in this repo, then `Get-ClaudeCommandLines`.
Expected: the new `claude.exe` carries `--settings` with the full path of `~\.claude\bedrock-settings.json`. Close the window without typing a prompt.

- [ ] **Step 6: Check a path with a space and an apostrophe**

Copy `~\.claude\bedrock-settings.json` to `$Scratch\with space\it's settings.json`. Add `{ "Name": "odd", "File": "<that path>" }` to `Providers` and set `DefaultProvider` to `odd` by hand. `Restart-Card`, start "New session", `Get-ClaudeCommandLines`.
Expected: the window opens Claude, not a PowerShell error, and the command line carries the whole path. Close the window, take `odd` out again and set `DefaultProvider` back to `Subscription`.

- [ ] **Step 7: Commit**

```bash
git add AgentTrafficLight.ps1
git commit -F <message file: "Start and resume sessions on the chosen setup">
```

---

### Task 3: Knowing a session's setup, and the tag

**Files:**
- Modify: `AgentTrafficLight.ps1`: new functions in the "Bedrock setups" section; probe block (`-CommandLine`); `Sync-SessionExtras` (sets `$info.Provider`); `New-Row` (`ProviderTag`); the per-row block in `Update-Layout` next to `ModelText`; closed-row drawing in `Update-Card`; `localSeen` in `Update-Card`; `Save-OpenSessions`, `Save-ClosedSessions`, `Read-ClosedSessions`, `Add-ClosedSession`; `Write-LayoutDump`.
- Modify: `Row.xaml`: put `SoundMark` and a new `ProviderTag` in a horizontal `StackPanel` in `Grid.Column="3"`.
- Test: `$Scratch\fixture3.ps1`

**Interfaces:**
- Consumes: `Get-Providers`, `Test-BedrockDefault`, `Read-SettingsEnv`, `Test-BedrockOn`, `Get-SetupName` from Task 1; `$subscriptionFile` from Task 2.
- Produces:
  - Probe param `[string]$CommandLine = ''`.
  - `Resolve-ProviderName([string]$CommandLine, [array]$List, [string]$BedrockDefault) -> string`, `''` meaning the subscription.
  - `Get-SessionProvider([int]$ProcessId) -> string`, cached per process id in `$script:providerByPid`, which drops ids no longer running.
  - `$info.Provider`, `$rec.Provider`, `Provider` in `open.json` and `closed.json` entries (missing reads as `''`), `$rec.ProviderTag`.

- [ ] **Step 1: Write the fixture check**

`$Scratch\fixture3.ps1` reuses `$Scratch\fake-claude\` from Task 1 (rebuilt the same way, `settings.json` left out) and runs, for each case, `AgentTrafficLight.ps1 -Probe -Providers -ClaudeDir "$Scratch\fake-claude" -CommandLine <line>`, which prints only `  provider: <name or subscription>`. `<fc>` stands for the fixture folder; an unlisted file `$Scratch\unlisted\aws-settings.json` turns Bedrock on.

| Case | Command line | Expected |
| --- | --- | --- |
| listed | `"C:\x\claude.exe" --settings "<fc>\bedrock-settings.json"` | `bedrock` |
| case | `claude.exe --settings "<FC upper-cased>\BEDROCK-SETTINGS.JSON"` | `bedrock` |
| equals | `claude.exe --settings=<fc>\settings-aws.json --resume abc` | `aws` |
| quoted | `claude.exe --settings "<fc>\with space\it's settings.json"` with that file listed as `odd` (written into the fixture folder by the check) | `odd` |
| unlisted | `claude.exe --settings "<Scratch>\unlisted\aws-settings.json"` | `aws` |
| off file | `claude.exe --settings "<repo>\state\subscription-settings.json"` | `subscription` |
| plain | `claude.exe --resume abc` | `subscription` |
| plain, default | `claude.exe --resume abc`, with `settings.json` turning Bedrock on put back into the fixture | `Bedrock (your settings)` |
| not bedrock | `claude.exe --settings "<fc>\other.json"` | `subscription` |

- [ ] **Step 2: Run it to see it fail**

Run: `powershell -NoProfile -File "$Scratch\fixture3.ps1"`
Expected: FAIL, `-CommandLine` is unknown.

- [ ] **Step 3: Implement detection**

`Resolve-ProviderName` takes the value after `--settings`, given as the next token or as `--settings=<value>`, double- or single-quoted or bare. The rules run in the spec's order: the off file (`$subscriptionFile`) means the subscription; a listed `File`, compared as full paths ignoring case, gives its `Name`; another file that turns Bedrock on gives `Get-SetupName`; otherwise, and with no `--settings`, `Bedrock (your settings)` when `$BedrockDefault` is not `''`, else the subscription. A file that cannot be read counts as not turning Bedrock on.

`Get-SessionProvider` reads the command line once per process through `Win32_Process`, as `Get-SshHost` does, and resolves it against `Get-Providers` and `Test-BedrockDefault` with the login environment. `Sync-SessionExtras` sets `$info.Provider` from the session's `Pid`. The probe's `-CommandLine` path resolves against the fixture folder's list as Task 1's probe builds it.

- [ ] **Step 4: Run the fixture to see it pass**

Run: `powershell -NoProfile -File "$Scratch\fixture3.ps1"`
Expected: `PASS`.

- [ ] **Step 5: Implement the tag and keep the setup with the row**

`ProviderTag` is a `TextBlock` after `SoundMark`, `Margin="6,0,0,0"`, `FontFamily="{DynamicResource FontText}"`, `FontSize="{DynamicResource SizeDetail}"`, `Foreground="{DynamicResource BrushTextDim}"`, collapsed by default, with the same fade under the row's buttons as `SoundMark`. In `Update-Layout`: when `$rec.Provider` is not `''`, the tag shows it, with the tooltip `Runs on Bedrock: <name>`; otherwise collapsed. `Set-RowLook` gives it the timer's foreground, as it does `SoundMark`. A closed row shows its entry's `Provider` the same way. The provider travels with `Model` everywhere the row's look is saved: `localSeen`, `open.json`, `Add-ClosedSession`, `closed.json`. `Write-LayoutDump` adds `provider=<rec.Provider>` to each row line.

- [ ] **Step 6: Check rows on the live card**

```powershell
. "$Scratch\live.ps1"; $t = Get-Date
Copy-Item "$Scratch\state-before\*.json" "$Repo\state\" -Force   # old files, no Provider keys
Restart-Card
```

Then, from a new terminal in this repo, start `claude --settings "$env:USERPROFILE\.claude\bedrock-settings.json"` and leave it at its prompt. `Get-Dump`, then close that window with its row's Close button and `Get-Dump` again.
Expected: this session's row says `provider=` (empty); the Bedrock one says `provider=bedrock` and shows the tag `bedrock`; after Close its closed row still says `provider=bedrock` and shows the tag. `Get-NewErrors $t` is empty. Kill the closed row.

- [ ] **Step 7: Commit**

```bash
git add AgentTrafficLight.ps1 Row.xaml
git commit -F <message file: "Tag rows with the Bedrock setup their session runs on">
```

---

### Task 4: The Settings menu, and the README

**Files:**
- Modify: `AgentTrafficLight.ps1`: `Show-SettingsMenu`.
- Modify: `README.md`: a new section after the paragraph on New sessions; the Settings list wherever the README names them.

**Interfaces:**
- Consumes: `Get-Providers`, `Get-DefaultProvider`, `Find-BedrockFiles`, `Add-FoundSetups`, `Save-Settings` from Task 1; `Start-ClaudeSession` from Task 2.

- [ ] **Step 1: Implement "New sessions on"**

In `Show-SettingsMenu`, a submenu `New sessions on`, added only when `Get-Providers` returns more than one entry. One checkable item per entry, header through `ConvertTo-MenuHeader`, ticked when it is the default. A `Missing` entry reads `<name> (file missing)` and is disabled. Choosing an item sets `DefaultProvider` and saves. A separator, then `Find Bedrock settings`: runs `Find-BedrockFiles $claudeDir`, then `Add-FoundSetups`, and shows the tray note `Found <n> new Bedrock settings` or `No new Bedrock settings`. Each handler is wrapped in `try` and logs under `[providers]`.

- [ ] **Step 2: Check the menu**

`Restart-Card`, open Settings.
Expected: `New sessions on` lists `Subscription` ticked, `bedrock`, `bedrock-br-lennart`, then `Find Bedrock settings`. Choosing `bedrock` moves the tick and writes `"DefaultProvider": "bedrock"`. A closed row's Resume then starts with `--settings` (`Get-ClaudeCommandLines`). Set it back to `Subscription`.

- [ ] **Step 3: Check a name with an underscore, and Find**

Copy `bedrock-settings.json` to `~\.claude\bedrock_eu.json`, use `Find Bedrock settings`, and reopen the menu.
Expected: the tray note says one new setting was found, and `bedrock_eu` shows with its underscore. Running Find again finds none. Delete `bedrock_eu.json` and remove its entry from `state\settings.json`.

- [ ] **Step 4: Check a setup whose file is gone**

Add `{ "Name": "gone", "File": "C:\\nowhere\\gone.json" }` to `Providers` by hand, set `DefaultProvider` to `gone`, `Restart-Card`, and start "New session".
Expected: the menu shows `gone (file missing)` disabled; the tray note `gone: settings file not found`; no window opens; one `[providers]` line in `state\error.log`, no other error. Remove the entry and set the default back.

- [ ] **Step 5: Check that a machine without Bedrock sees nothing**

Remove `Providers` and `DefaultProvider` from `state\settings.json`, rename `~\.claude\bedrock-settings.json` and `bedrock-br-lennart-settings.json` to `.json.off`, `Restart-Card`.
Expected: Settings has no `New sessions on`; no row shows a tag; `state\settings.json` gained no `Providers` key. Rename both back, `Restart-Card`, and the list is found again.

- [ ] **Step 6: Write the README section**

What the switch does; that setups are settings files found in `~/.claude` that turn Bedrock on, named after the file; the list and the default in `state\settings.json` as `Providers` and `DefaultProvider`, renamed or removed there by hand; how a machine where Bedrock is already the default gets `Bedrock (your settings)`; the tag; moving a running session by Close, switching under Settings, then Resume; the prompt cache caveat from the spec; `-Probe -Providers`.

- [ ] **Step 7: Commit**

```bash
git add AgentTrafficLight.ps1 README.md
git commit -F <message file: "Choose under Settings what new sessions start on">
```

After this task, put `$Scratch\state-before\*.json` back into `state\` only if the checks left the user's settings changed, and say so.
