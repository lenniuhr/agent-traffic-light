# Style presets

Date: 2026-10-13

## Goal

Try different looks for the card by picking a built-in preset from the settings menu. A preset changes
more than colours: outlines, corners, shadows, fonts and density too. The card switches on the spot,
without a restart, so presets can be compared by flipping between them.

Not a goal: style files dropped in by other people (everyone changes the code with Claude directly),
or presets that change what a row is made of (a three-lamp traffic light row, for example). Every
preset keeps the same parts in the same places.

What the colours mean stays fixed across presets: blue working, green finished, amber blocked, the
blue dot for "wants you", and no red. How they are drawn, fill or outline, and their exact shades,
are up to the preset. The Green phosphor preset planned after this one is the deliberate exception
and will be specified on its own.

First presets: **Classic**, today's card unchanged, and **Terminal**, a modern dark terminal look.

## Storage

- A new folder `presets\` holds one WPF `ResourceDictionary` per preset: `Classic.xaml` and
  `Terminal.xaml`. The file name is the preset's name in the menu.
- `Classic.xaml` is the complete base: every key listed under "Keys" below, with today's values,
  moved out of `AgentTrafficLight.xaml` and the inline attributes of the four templates.
- Every other preset holds only the keys it changes.
- The card always loads Classic as the first merged dictionary of the window's resources and the
  chosen preset as the second, so a key the preset leaves out falls back to Classic.
- The menu styles (`CardMenu`, `CardMenuItem`, `CardMenuSeparator`) stay in
  `AgentTrafficLight.xaml`, but read their colours, corners, outline and shadow by key.

## Keys

Values are Classic's, which are today's.

**Colours** (`SolidColorBrush`): the 25 existing brushes keep their names and values (`BrushCard`,
`BrushCardEdge`, `BrushCardInner`, `BrushText`, `BrushTextDim`, `BrushWorking`, `BrushWaiting`,
`BrushBlocked`, `BrushRowBase`, `BrushTextOnWait`, `BrushTextOnBlock`, `BrushTimerOnWait`,
`BrushTimerOnBlock`, `BrushStripeText`, `BrushWsNeutral`, `BrushCtxTrack`, `BrushCtxFill`,
`BrushCtxHigh`, `BrushWs0` to `BrushWs3`, `BrushHeadless`). New, for the menus:

| Key | Classic |
| --- | --- |
| `BrushMenu` | `#1E222A` |
| `BrushMenuEdge` | `#2E333D` |
| `BrushMenuHighlight` | `#2A303A` |
| `BrushMenuTick` | `#4C9BE8` |
| `BrushMenuArrow` | `#8B94A1` |
| `BrushMenuSeparator` | `#24FFFFFF` |

The menu's text and caption take `BrushText` and `BrushTextDim`, which they match today.

**Row outline** (new): `RowEdgeThickness` (`Thickness`, Classic `0`), and one brush per state:
`BrushRowEdge` (working and watching), `BrushRowEdgeOnWait`, `BrushRowEdgeOnBlock`, all transparent
in Classic. Applies to agent rows; a Unity row takes `BrushRowEdge`.

**Corners** (`CornerRadius`, `SwatchRadius` a `Double`):

| Key | Classic |
| --- | --- |
| `CardCorner` | `10` |
| `CardInnerCorner` | `9` |
| `RowCorner` | `8` |
| `StripeCorner` | `6,0,0,6` |
| `MenuCorner` | `8` |
| `MenuItemCorner` | `5` |
| `SwatchRadius` | `2` |

**Outlines** (`Thickness`): `CardEdgeThickness` `1`, `CardInnerThickness` `1`,
`MenuEdgeThickness` `1`.

**Shadows** (`Effect`, or `x:Null` for none): `CardShadow` (blur 20, depth 2, opacity 0.35),
`MenuShadow` (blur 14, depth 3, opacity 0.45), both black, direction 270.

**Fonts**: `FontText` (`FontFamily`, `Segoe UI`) for labels, details, timers, headers, the model
name, the warning line and the menus; `FontClock` (`Bahnschrift`) for the work clock and its caption;
`LabelWeight` (`FontWeight`, `SemiBold`) for row labels and Unity labels. The symbol glyphs (tick,
note) keep `Segoe UI Symbol`, which is not a preset key.

**Font sizes** (`Double`):

| Key | Classic | Used by |
| --- | --- | --- |
| `SizeLabel` | 15 | agent row label |
| `SizeLabelWithDetail` | 13 | agent row label while the detail line shows, and the Unity label |
| `SizeDetail` | 11 | detail lines, Unity CPU |
| `SizeTimer` | 12 | row timer, Unity memory |
| `SizeHeader` | 11 | group headers, the warning line |
| `SizeModel` | 9 | model name in the stripe |
| `SizeClock` | 26 | work clock |
| `SizeClockCaption` | 11 | the two lines left of the clock |
| `SizeMenu` | 13 | menus |

**Density** (`Double`):

| Key | Classic | Replaces |
| --- | --- | --- |
| `RowHeight` | 42 | `Height` of both row templates, `$rowHeight` |
| `RowWidth` | 360 | `Width` of the row and header templates |
| `RowGap` | 6 | `$rowGap` |
| `HeaderHeight` | 22 | `Height` of `Header.xaml`, `$headerHeight` |
| `GroupGap` | 8 | `$groupGap` |
| `CardPadding` | 10 | `$cardPadding`, the row canvas margin |

The window width (404 today), `$cardWidth` (380) and `$ctxBarWidth` (330) are derived from `RowWidth`
and `CardPadding` instead of written separately: card width = `RowWidth` + 2 × `CardPadding`, window
width = card width + 2 × the shadow margin, context bar = `RowWidth` − 30.

Left out on purpose: dot and ring sizes, the stripe width, the symbol font, the tray icon colours
(drawn in code by Windows Forms, outside the card) and a text glow (added with the Green phosphor
preset).

## Templates

`AgentTrafficLight.xaml`, `Row.xaml`, `UnityRow.xaml` and `Header.xaml` refer to every key above with
`{DynamicResource Key}` in place of the inline value. A value set in a style trigger (the row label's
smaller size while the detail shows) refers to it the same way.

## Script

**Loading.** At start the script loads `presets\Classic.xaml` and the saved preset with the existing
`Import-Xaml`, adds both to `$window.Resources.MergedDictionaries`, and then reads its brush table and
density values. Settings gain `Preset` (string, default `Classic`), read and saved like the others.

**Reading values.** The `$brush` table (`AgentTrafficLight.ps1`, after the window is loaded) is built
by a function, `Read-StyleValues`, that also sets `$script:rowHeight`, `$rowGap`, `$headerHeight`,
`$groupGap`, `$cardPadding`, `$cardWidth`, `$ctxBarWidth` and the window width from the resources.
These become script-scope variables where they are plain ones today. `New-Row` stops reading
`$script:rowHeight` back from the row element.

**Row outline.** `Set-RowState` sets `BorderBrush` alongside the fill: `BrushRowEdge` for Working and
Watching, `BrushRowEdgeOnWait` for Waiting, `BrushRowEdgeOnBlock` for Blocked. `BorderThickness` comes
from the template.

**Menus.** `New-CardMenu` adds the window's two merged dictionaries to the menu's own resources, so
the menu and its submenu popups resolve the same keys as the card.

**Switching.** The settings menu gets a **Style** submenu after Default sound, listing the files in
`presets\` with a tick on the current one. Picking one calls `Set-Preset`, which:

1. loads the file and replaces the second merged dictionary with it;
2. calls `Read-StyleValues`;
3. repaints every agent row with `Set-RowLook`, the per-state painting split out of `Set-RowState`,
   which leaves the row's timers, state and sound bookkeeping alone;
4. re-applies the Unity rows' stripes;
5. runs `Update-Layout`;
6. saves `Preset`.

Rows are not rebuilt. Everything bound with `DynamicResource` updates by itself.

A preset's name written to `state\preset.flag` makes the next poll call `Set-Preset`, the way
`state\dump.flag` makes it dump the layout, so checks can switch the live card without clicking.

**Failure.** A preset file that is missing or does not parse is written to the error log and Classic
is used, at start and on a switch. A switch that fails leaves the current preset in place. Font
families are written as fallback lists (`Cascadia Mono, Consolas`), so a missing font falls through.

## The Terminal preset

`presets\Terminal.xaml`, a modern dark terminal. Overrides only:

- Surface: `BrushCard` `#0C0C0C`; `BrushCardEdge` `#3A3A3A`; `CardInnerThickness` `0`; every corner
  key `0`; `CardShadow` and `MenuShadow` none.
- Rows: `BrushRowBase` `#141414`; `RowEdgeThickness` `1`; `BrushRowEdge` `#2A2A2A`;
  `BrushWaiting` `#0F2416` with `BrushRowEdgeOnWait` `#16C60C`; `BrushBlocked` `#2E2606` with
  `BrushRowEdgeOnBlock` `#C19C00`. The fills stay dark so the outline and the dot carry the state.
- Blue: `BrushWorking` and `BrushMenuTick` `#3B78FF`.
- Text: `BrushText` `#CCCCCC`, `BrushTextDim` `#767676`, `BrushTextOnWait` and `BrushTextOnBlock`
  `#E6E6E6`, `BrushTimerOnWait` `#7FBF8A`, `BrushTimerOnBlock` `#C9B46A`.
- Workspace hues from the terminal palette, without the three state colours: `BrushWs0` magenta
  `#D670D6`, `BrushWs1` cyan `#61D6D6`, `BrushWs2` lavender `#B4A0FF`, `BrushWs3` grey `#A0A0A0`.
- Menus: `BrushMenu` `#0C0C0C`, `BrushMenuEdge` `#3A3A3A`, `BrushMenuHighlight` `#262626`.
- Type: `FontText` and `FontClock` `Cascadia Mono, Consolas`; `LabelWeight` `Normal`; `SizeLabel`
  13, `SizeLabelWithDetail` 12, `SizeClock` 22, `SizeClockCaption` 10.
- Density: `RowHeight` 32, `RowGap` 2, `CardPadding` 8. `RowWidth` stays 360 so the card keeps its
  width; `HeaderHeight` and `GroupGap` stay.

## Other files

- `Install.ps1`: `presets\Classic.xaml` joins the list of files that must be present.
- `README.md`: a short paragraph on Style in the settings, and on adding a preset (copy a file in
  `presets\`, keep only the keys that differ).
- The comment at the top of `AgentTrafficLight.xaml` that says all colour and size decisions live
  there moves to `presets\Classic.xaml`.

## Verification

There is no test suite. A check script, kept in the session scratchpad rather than the repository,
verifies:

1. every `{DynamicResource X}` in the four templates and every key the script looks up exists in
   `Classic.xaml`;
2. every preset parses, and sets only keys Classic defines;
3. every key holds the type its uses need (brush, thickness, corner radius, double, font family,
   font weight, effect or null).

Then, on the running card: start on Classic, switch to Terminal and back through `Set-Preset`, and
confirm from the layout dump (`state\dump.flag`) that the rows move to the new row pitch and back,
with no entries in the error log. The visual check and a click through the menus are done by hand.
