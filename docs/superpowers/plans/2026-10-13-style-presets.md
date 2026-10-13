# Style Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Built-in style presets for the card, picked under Style in the settings menu and applied on the spot, starting with Classic (today's look) and Terminal.

**Architecture:** Every look value moves into `presets\Classic.xaml`, a WPF `ResourceDictionary` merged into the window's resources. The templates read each value with `{DynamicResource Key}`. A second merged dictionary, the chosen preset, overrides any subset of Classic's keys. The script reads the colours and density it uses from the merged resources, and a switch swaps the second dictionary, re-reads those values, repaints each row and re-runs the layout.

**Tech Stack:** Windows PowerShell 5.1, WPF (PresentationFramework) loaded with `XamlReader`, no build step, no test framework.

**Spec:** `docs/superpowers/specs/2026-10-13-style-presets-design.md`

## Global Constraints

- Windows PowerShell 5.1. The script is read as ANSI without a BOM: no literal non-ASCII characters in `AgentTrafficLight.ps1`. XAML files are UTF-8 and use `&#x....;` for symbols as the existing ones do.
- Classic must look exactly like today's card. Every Classic value is copied from the current files, not re-chosen.
- What the colours mean stays fixed across presets: blue working, green finished, amber blocked, the blue dot for "wants you", no red.
- Presets other than Classic hold only the keys they change. A key a preset sets must exist in Classic.
- A preset that is missing or does not parse is logged to `state\error.log`; at start the card uses Classic, on a switch it keeps the current preset.
- The preset name is the file name in `presets\` without `.xaml`. The choice is saved as `Preset` in `state\settings.json`, default `Classic`.
- Font families are fallback lists where a font might be missing: `Cascadia Mono, Consolas`.
- Match the surrounding code: comments explain why, in full sentences; functions are `Verb-Noun`; menu entries are built with `Add-CardMenuAction`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commit with `git commit -F <file>`: Windows PowerShell mangles double quotes in `-m`.

## Review Focus

1. A preset switch while a row is Blocked: the row takes the new colours and keeps pulsing; its timer and its sound bookkeeping are untouched. Pinned in Task 2 by the look checks, which call `Set-RowLook` on a Blocked row and check its brushes, and by `Set-RowLook` not touching `WorkSince`, `FinishedAt` or `Since`.
2. `Preset` in `settings.json` names a file that was deleted or renamed: the card starts on Classic, logs it once, and the Style menu ticks Classic. Pinned in Task 3, Step 7.
3. A preset file with broken XML picked from the menu: the current preset stays, nothing on the card changes, the error is logged. Pinned in Task 3, Step 8.
4. Menus and their submenus opened after a switch use the new preset. Pinned in Task 3 by the check that `New-CardMenu` hands the menu the window's current dictionaries; the submenu popup is checked by eye in Task 4, Step 7.
5. After a switch to a denser preset the card shrinks to fit and dragging a row uses the new row pitch. Pinned in Task 4, Step 6 (pitch and height from the layout dump); the drag is checked by hand in Task 4, Step 7.

## Shared test setup

All commands run in Windows PowerShell from the repository root,
`C:\Users\LennartUhrmacher\wkspaces\agent-traffic-light`. Check scripts live in the session scratchpad,
not in the repository:

```powershell
$Scratch = 'C:\Users\LENNAR~1\AppData\Local\Temp\claude\C--Users-LennartUhrmacher-wkspaces-agent-traffic-light\21890962-8e61-4d6d-9069-5621f6abbada\scratchpad'
```

Restarting the card and reading its layout, used by several tasks. Save as `$Scratch\live.ps1`:

```powershell
# Helpers for checking the running card. Dot-source it: . "$Scratch\live.ps1"
$Repo = 'C:\Users\LennartUhrmacher\wkspaces\agent-traffic-light'

function Restart-Card {
    Get-CimInstance Win32_Process |
        Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'AgentTrafficLight\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-STA',
        '-WindowStyle','Hidden','-File',(Join-Path $Repo 'AgentTrafficLight.ps1')
    Start-Sleep -Seconds 8
}

# The layout dump: the first line, then each row's top.
function Get-Dump {
    Set-Content (Join-Path $Repo 'state\dump.flag') 'x'
    Start-Sleep -Seconds 2
    Get-Content (Join-Path $Repo 'state\dump.txt')
}

# Asks the running card to switch preset, the way the Style menu does.
function Switch-Preset([string]$Name) {
    Set-Content (Join-Path $Repo 'state\preset.flag') $Name
    Start-Sleep -Seconds 2
}

function Get-NewErrors([datetime]$Since) {
    $log = Join-Path $Repo 'state\error.log'
    if (-not (Test-Path $log)) { return @() }
    @(Get-Content $log | Where-Object { $_.Length -gt 33 -and [datetime]::Parse($_.Substring(0, 33)) -gt $Since })
}
```

---

### Task 1: Classic preset and templates that read it

Moves every look value into `presets\Classic.xaml` and points the templates at it by key, with the card looking exactly as before. Includes the static check script used by every later task.

**Files:**
- Create: `presets\Classic.xaml`
- Modify: `AgentTrafficLight.xaml` (whole file, given below)
- Modify: `Row.xaml` (attribute replacements below)
- Modify: `UnityRow.xaml` (whole file, given below)
- Modify: `Header.xaml` (whole file, given below)
- Modify: `AgentTrafficLight.ps1:1180` (merge Classic before anything reads resources)
- Test: `$Scratch\check-presets.ps1`

**Interfaces:**
- Produces: the resource keys of the spec's "Keys" section, all defined in `presets\Classic.xaml`; `$window.Resources.MergedDictionaries[0]` is Classic.

- [ ] **Step 1: Record a baseline layout dump**

```powershell
. "$Scratch\live.ps1"
Restart-Card
Get-Dump | Set-Content "$Scratch\baseline-dump.txt"
Get-Content "$Scratch\baseline-dump.txt"
```

Expected: a first line with the date and `drag=False`, then `group ...` lines and one `top=...` line per row. Row tops within a group step by 48 (42 + 6).

- [ ] **Step 2: Write the static check script**

Save as `$Scratch\check-presets.ps1`:

```powershell
param([string]$Repo = 'C:\Users\LennartUhrmacher\wkspaces\agent-traffic-light')
# Static checks of the presets against the templates and the script. Run in an
# STA PowerShell: powershell -NoProfile -STA -File check-presets.ps1
Add-Type -AssemblyName PresentationFramework
$fail = 0
function Fail([string]$What) { "FAIL  $What"; $script:fail++ }
function Load([string]$Path) {
    $s = [System.IO.File]::OpenRead($Path)
    try { [System.Windows.Markup.XamlReader]::Load($s) } finally { $s.Dispose() }
}

# The type each key must hold, by its name.
function Get-Expected([string]$Key) {
    switch -Regex ($Key) {
        '^Brush'                     { return [System.Windows.Media.SolidColorBrush] }
        'Thickness$'                 { return [System.Windows.Thickness] }
        'Corner$'                    { return [System.Windows.CornerRadius] }
        '^Font'                      { return [System.Windows.Media.FontFamily] }
        '^LabelWeight$'              { return [System.Windows.FontWeight] }
        'Shadow$'                    { return [System.Windows.Media.Effects.Effect] }
        '^(Size|Row(Height|Width|Gap)$|HeaderHeight$|GroupGap$|CardPadding$|SwatchRadius$)' { return [double] }
    }
    return $null
}
function Test-Value([string]$File, [string]$Key, $Value) {
    $want = Get-Expected $Key
    if ($null -eq $want) { Fail "$File : $Key has no known type"; return }
    if ($null -eq $Value) {
        if ($want -ne [System.Windows.Media.Effects.Effect]) { Fail "$File : $Key is null" }
        return
    }
    if (-not ($Value -is $want)) { Fail "$File : $Key is $($Value.GetType().Name), want $($want.Name)" }
}

$presetDir = Join-Path $Repo 'presets'
$classicPath = Join-Path $presetDir 'Classic.xaml'
if (-not (Test-Path $classicPath)) { Fail 'presets\Classic.xaml missing'; "$fail failed"; exit 1 }
$classic = Load $classicPath
$classicKeys = @($classic.Keys | ForEach-Object { [string]$_ })
foreach ($k in $classicKeys) { Test-Value 'Classic' $k $classic[$k] }

# 1. Every key the templates and the script use exists in Classic.
$templates = 'AgentTrafficLight.xaml', 'Row.xaml', 'UnityRow.xaml', 'Header.xaml'
$used = @{}
foreach ($t in $templates) {
    $text = Get-Content (Join-Path $Repo $t) -Raw
    foreach ($m in [regex]::Matches($text, '\{DynamicResource (\w+)\}')) { $used[$m.Groups[1].Value] = $t }
    # Everything the look is made of comes from a preset now.
    foreach ($m in [regex]::Matches($text, '"#[0-9A-Fa-f]{6,8}"')) { Fail "$t : hard-coded colour $($m.Value)" }
}
$script = Get-Content (Join-Path $Repo 'AgentTrafficLight.ps1') -Raw
foreach ($m in [regex]::Matches($script, "FindResource\('(\w+)'\)")) { $used[$m.Groups[1].Value] = 'AgentTrafficLight.ps1' }
$styles = 'CardMenu', 'CardMenuItem', 'CardMenuSeparator'
foreach ($k in $used.Keys) {
    if ($styles -contains $k) { continue }
    if ($classicKeys -notcontains $k) { Fail "$($used[$k]) uses $k, which Classic does not define" }
}
foreach ($k in $classicKeys) {
    if (-not $used.ContainsKey($k)) { Fail "Classic defines $k, which nothing uses" }
}

# 2 and 3. Every other preset parses, sets only Classic's keys, with their types.
foreach ($file in Get-ChildItem $presetDir -Filter '*.xaml' -File) {
    if ($file.BaseName -eq 'Classic') { continue }
    try { $dict = Load $file.FullName } catch { Fail "$($file.Name) does not parse: $($_.Exception.Message)"; continue }
    if (-not ($dict -is [System.Windows.ResourceDictionary])) { Fail "$($file.Name) is not a ResourceDictionary"; continue }
    foreach ($k in @($dict.Keys | ForEach-Object { [string]$_ })) {
        if ($classicKeys -notcontains $k) { Fail "$($file.Name) sets $k, which Classic does not define"; continue }
        Test-Value $file.Name $k $dict[$k]
    }
}

# The templates load and lay out with Classic merged above them.
$window = Load (Join-Path $Repo 'AgentTrafficLight.xaml')
[void]$window.Resources.MergedDictionaries.Add($classic)
$canvas = $window.FindName('RowCanvas')
foreach ($t in 'Row.xaml', 'UnityRow.xaml', 'Header.xaml') {
    try {
        $el = Load (Join-Path $Repo $t)
        [void]$canvas.Children.Add($el)
    } catch { Fail "$t does not load: $($_.Exception.Message)" }
}

"$fail failed"
exit $fail
```

- [ ] **Step 3: Run it to see it fail**

Run: `powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$Scratch\check-presets.ps1"`
Expected: `FAIL  presets\Classic.xaml missing`, `1 failed`.

- [ ] **Step 4: Create `presets\Classic.xaml`**

```xml
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                    xmlns:sys="clr-namespace:System;assembly=mscorlib">

  <!-- The card's own look, and the base of every other preset. Each key here is
       read by name, by the templates through DynamicResource and by the script
       through FindResource. Another preset in this folder holds only the keys
       it changes; the card loads this file first and lays the chosen preset over
       it, so anything a preset leaves out comes from here. Add a key here first
       and a preset can then override it. -->

  <SolidColorBrush x:Key="BrushCard"        Color="#14161A" />
  <SolidColorBrush x:Key="BrushCardEdge"    Color="#0A0B0E" />
  <SolidColorBrush x:Key="BrushCardInner"   Color="#1AFFFFFF" />
  <SolidColorBrush x:Key="BrushText"        Color="#E8EBEF" />
  <SolidColorBrush x:Key="BrushTextDim"     Color="#8B94A1" />

  <!-- Row states. Blue is the calm one on purpose: it has the lowest salience
       of the three, so a card full of working sessions stays quiet.

       The two fills are deliberately dark and desaturated. A saturated block
       of colour on a dark card reads as an alarm even when the news is good,
       and a finished session is good news. These sit on the card rather than
       glowing off it, and the signal is carried by the fill covering the whole
       row and by where the row sorts to, not by shouting.

       Green for finished, amber for blocked, and no red anywhere: green
       against red is the one pair roughly one man in twelve cannot separate,
       and dropping red entirely is what frees green to mean "done". -->
  <SolidColorBrush x:Key="BrushWorking"     Color="#4C9BE8" />
  <SolidColorBrush x:Key="BrushWaiting"     Color="#2C6650" />
  <SolidColorBrush x:Key="BrushBlocked"     Color="#9A6526" />

  <!-- A working row is not transparent. Left as nothing it dissolved into the
       card and you could not see where one row ended and the next began; a
       lift of a few points over the card background is enough to give every
       row a visible shape without putting colour on a session that is simply
       getting on with its work. -->
  <SolidColorBrush x:Key="BrushRowBase"     Color="#1E222A" />
  <SolidColorBrush x:Key="BrushTextOnWait"  Color="#E6F3EC" />
  <SolidColorBrush x:Key="BrushTextOnBlock" Color="#FBEEDD" />

  <!-- The timer is secondary information on a filled row exactly as it is on
       a dark one, so it gets the same treatment: the row's text colour pulled
       back towards the fill underneath it. Full-strength white on the fill
       made the number compete with the label. -->
  <SolidColorBrush x:Key="BrushTimerOnWait"  Color="#9CBBAE" />
  <SolidColorBrush x:Key="BrushTimerOnBlock" Color="#D4B794" />

  <!-- The model name is set into the stripe, so it needs to read against a
       workspace hue rather than against the row. All the stripe colours are
       light, so it is near-black. -->
  <SolidColorBrush x:Key="BrushStripeText"   Color="#16181D" />

  <!-- The stripe when only one workspace is open and there is nothing to tell
       apart. It still has to hold the model name, so it stays light. -->
  <SolidColorBrush x:Key="BrushWsNeutral"    Color="#9AA3B2" />

  <!-- Context bar. Translucent white rather than a fixed colour, so the same
       two brushes read correctly on the dark row and on both fills. The high
       mark is a bright amber, which is the only moment this bar is meant to
       be looked at rather than merely noticed. -->
  <SolidColorBrush x:Key="BrushCtxTrack"     Color="#24FFFFFF" />
  <SolidColorBrush x:Key="BrushCtxFill"      Color="#8CFFFFFF" />
  <SolidColorBrush x:Key="BrushCtxHigh"      Color="#E8A33D" />

  <!-- Workspace hues for the stripe and the heading swatch. Assigned by
       position in the sorted list of open workspaces, so two of them never
       draw the same colour. Deliberately violet and pink first: neither can be
       mistaken for the blue working dot or for either of the two state fills. -->
  <SolidColorBrush x:Key="BrushWs0"         Color="#9B8CF0" />
  <SolidColorBrush x:Key="BrushWs1"         Color="#E48FB8" />
  <SolidColorBrush x:Key="BrushWs2"         Color="#5FC8D8" />
  <SolidColorBrush x:Key="BrushWs3"         Color="#B8B4C8" />

  <!-- Stripe of a Unity editor that runs headless. A warm sand, because every
       hue above already means a workspace or a state, and an editor row must
       not read as either. An editor with a window keeps the neutral stripe. -->
  <SolidColorBrush x:Key="BrushHeadless"    Color="#D9C38C" />

  <!-- An outline round each row, in the colour of its state. None here: the
       fill carries the state on this card. A preset that draws its rows as
       outlines sets the thickness and the three colours. A Unity row has no
       state and takes the working one. -->
  <Thickness x:Key="RowEdgeThickness">0</Thickness>
  <SolidColorBrush x:Key="BrushRowEdge"        Color="Transparent" />
  <SolidColorBrush x:Key="BrushRowEdgeOnWait"  Color="Transparent" />
  <SolidColorBrush x:Key="BrushRowEdgeOnBlock" Color="Transparent" />

  <!-- The card's menus. The text and the caption take BrushText and
       BrushTextDim; these are the menu's own surface. The tick is the working
       blue, the one accent the card uses. -->
  <SolidColorBrush x:Key="BrushMenu"          Color="#1E222A" />
  <SolidColorBrush x:Key="BrushMenuEdge"      Color="#2E333D" />
  <SolidColorBrush x:Key="BrushMenuHighlight" Color="#2A303A" />
  <SolidColorBrush x:Key="BrushMenuTick"      Color="#4C9BE8" />
  <SolidColorBrush x:Key="BrushMenuArrow"     Color="#8B94A1" />
  <SolidColorBrush x:Key="BrushMenuSeparator" Color="#24FFFFFF" />

  <!-- Corners. The card's inner stroke sits one pixel inside its edge, so its
       radius is one less. The stripe rounds only its left corners, so it sits
       flush inside the row's own corner instead of poking out of it. -->
  <CornerRadius x:Key="CardCorner">10</CornerRadius>
  <CornerRadius x:Key="CardInnerCorner">9</CornerRadius>
  <CornerRadius x:Key="RowCorner">8</CornerRadius>
  <CornerRadius x:Key="StripeCorner">6,0,0,6</CornerRadius>
  <CornerRadius x:Key="MenuCorner">8</CornerRadius>
  <CornerRadius x:Key="MenuItemCorner">5</CornerRadius>
  <sys:Double x:Key="SwatchRadius">2</sys:Double>

  <!-- A dark edge and, just inside it, a second lighter one. Together they keep
       the card's edge visible whether it is sitting on a grey editor or on a
       white browser window. -->
  <Thickness x:Key="CardEdgeThickness">1</Thickness>
  <Thickness x:Key="CardInnerThickness">1</Thickness>
  <Thickness x:Key="MenuEdgeThickness">1</Thickness>

  <!-- Shadows. A preset without them sets these to x:Null. The card's margin
       round the outside is the shadow's room, so it stays either way. -->
  <DropShadowEffect x:Key="CardShadow" Color="#000000" BlurRadius="20" ShadowDepth="2" Opacity="0.35" Direction="270" />
  <DropShadowEffect x:Key="MenuShadow" Color="#000000" BlurRadius="14" ShadowDepth="3" Opacity="0.45" Direction="270" />

  <!-- Type. Sentence case, never caps, in the rows: word shape is what you
       actually read at a glance. The clock has a face of its own, with tabular
       digits so it does not shift sideways as it counts. -->
  <FontFamily x:Key="FontText">Segoe UI</FontFamily>
  <FontFamily x:Key="FontClock">Bahnschrift</FontFamily>
  <FontWeight x:Key="LabelWeight">SemiBold</FontWeight>

  <!-- With Marshal's detail line showing, the label takes the Unity row's
       two-line size, 13 over 11, and lifts clear of the context bar; 15 over 11
       put the detail's descenders on the bar. -->
  <sys:Double x:Key="SizeLabel">15</sys:Double>
  <sys:Double x:Key="SizeLabelWithDetail">13</sys:Double>
  <sys:Double x:Key="SizeDetail">11</sys:Double>
  <sys:Double x:Key="SizeTimer">12</sys:Double>
  <sys:Double x:Key="SizeHeader">11</sys:Double>
  <sys:Double x:Key="SizeModel">9</sys:Double>
  <sys:Double x:Key="SizeClock">26</sys:Double>
  <sys:Double x:Key="SizeClockCaption">11</sys:Double>
  <sys:Double x:Key="SizeMenu">13</sys:Double>

  <!-- Density. The script lays the rows out from these, and works out the
       card's width and the context bar's from RowWidth and CardPadding. -->
  <sys:Double x:Key="RowHeight">42</sys:Double>
  <sys:Double x:Key="RowWidth">360</sys:Double>
  <sys:Double x:Key="RowGap">6</sys:Double>
  <sys:Double x:Key="HeaderHeight">22</sys:Double>
  <sys:Double x:Key="GroupGap">8</sys:Double>
  <sys:Double x:Key="CardPadding">10</sys:Double>
</ResourceDictionary>
```

- [ ] **Step 5: Replace `AgentTrafficLight.xaml`**

The brushes leave for `presets\Classic.xaml`; the menu styles and the card read by key.

```xml
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Agent Traffic Light"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        Topmost="True"
        ShowInTaskbar="False"
        ResizeMode="NoResize"
        SizeToContent="Manual"
        Width="404"
        Height="120"
        Left="40"
        Top="40">

  <!-- Every colour, size, corner, outline, font and shadow comes from the
       presets folder: Classic.xaml first, then the chosen preset over it, both
       merged into these resources by the script before anything is drawn.
       Editing a preset and restarting the widget, or picking it again under
       Style, is the whole restyling loop. The width above is only the start;
       the script sets it from the preset's RowWidth. -->
  <Window.Resources>

    <!-- The card's menus: the settings menu and a row's right-click menu. Without
         these they draw in the system's light classic style, which sits badly
         against the dark card. A menu opens in a popup outside this window, so
         lookups from it do not reach the window's resources: New-CardMenu hands
         each menu the window's presets, and these styles read them by key. -->
    <Style x:Key="CardMenu" TargetType="ContextMenu">
      <Setter Property="OverridesDefaultStyle" Value="True" />
      <Setter Property="SnapsToDevicePixels" Value="True" />
      <Setter Property="FontFamily" Value="{DynamicResource FontText}" />
      <Setter Property="FontSize" Value="{DynamicResource SizeMenu}" />
      <Setter Property="Foreground" Value="{DynamicResource BrushText}" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContextMenu">
            <!-- The margin is the shadow's room, as on the card itself. -->
            <Border Margin="0,0,10,10"
                    Padding="4"
                    MinWidth="200"
                    Background="{DynamicResource BrushMenu}"
                    BorderBrush="{DynamicResource BrushMenuEdge}"
                    BorderThickness="{DynamicResource MenuEdgeThickness}"
                    CornerRadius="{DynamicResource MenuCorner}"
                    Effect="{DynamicResource MenuShadow}">
              <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle" />
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- An item with items of its own is a submenu header: it shows an arrow and
         opens its items beside the menu on hover, in a popup drawn like the menu.
         The popup must be called PART_Popup for the menu to manage it. The offsets
         line its first item up with the header and clear the menu's own edge;
         without room on the right, WPF opens it to the left. -->
    <Style x:Key="CardMenuItem" TargetType="MenuItem">
      <Setter Property="OverridesDefaultStyle" Value="True" />
      <Setter Property="Foreground" Value="{DynamicResource BrushText}" />
      <Setter Property="Cursor" Value="Hand" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Grid>
              <Border x:Name="ItemBg" Background="Transparent" CornerRadius="{DynamicResource MenuItemCorner}" Padding="6,6,14,6">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="22" />
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                  </Grid.ColumnDefinitions>
                  <TextBlock x:Name="Tick"
                             Text="&#x2713;"
                             Visibility="Hidden"
                             HorizontalAlignment="Center"
                             VerticalAlignment="Center"
                             FontFamily="Segoe UI Symbol"
                             FontSize="12"
                             Foreground="{DynamicResource BrushMenuTick}" />
                  <ContentPresenter Grid.Column="1"
                                    ContentSource="Header"
                                    RecognizesAccessKey="True"
                                    VerticalAlignment="Center" />
                  <TextBlock x:Name="Arrow"
                             Grid.Column="2"
                             Text="&#x203A;"
                             Visibility="Collapsed"
                             Margin="16,0,0,0"
                             VerticalAlignment="Center"
                             FontSize="15"
                             Foreground="{DynamicResource BrushMenuArrow}" />
                </Grid>
              </Border>
              <Popup x:Name="PART_Popup"
                     Placement="Right"
                     HorizontalOffset="6"
                     VerticalOffset="-5"
                     AllowsTransparency="True"
                     Focusable="False"
                     PopupAnimation="None"
                     IsOpen="{Binding IsSubmenuOpen, RelativeSource={RelativeSource TemplatedParent}}">
                <Border Margin="0,0,10,10"
                        Padding="4"
                        MinWidth="200"
                        Background="{DynamicResource BrushMenu}"
                        BorderBrush="{DynamicResource BrushMenuEdge}"
                        BorderThickness="{DynamicResource MenuEdgeThickness}"
                        CornerRadius="{DynamicResource MenuCorner}"
                        Effect="{DynamicResource MenuShadow}">
                  <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle" />
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="HasItems" Value="True">
                <Setter TargetName="Arrow" Property="Visibility" Value="Visible" />
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Tick" Property="Visibility" Value="Visible" />
              </Trigger>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="ItemBg" Property="Background" Value="{DynamicResource BrushMenuHighlight}" />
              </Trigger>
              <!-- Kept lit while its submenu is open, so it is clear which item the
                   submenu belongs to once the pointer has moved into it. -->
              <Trigger Property="IsSubmenuOpen" Value="True">
                <Setter TargetName="ItemBg" Property="Background" Value="{DynamicResource BrushMenuHighlight}" />
              </Trigger>
              <!-- A disabled item is the menu's caption, not a dead option. -->
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource BrushTextDim}" />
                <Setter Property="FontSize" Value="11" />
                <Setter Property="Cursor" Value="Arrow" />
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CardMenuSeparator" TargetType="Separator">
      <Setter Property="OverridesDefaultStyle" Value="True" />
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Separator">
            <Border Height="1" Margin="8,4,8,4" Background="{DynamicResource BrushMenuSeparator}" />
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <!-- The outer margin is the drop shadow's room to breathe. Without it the
       shadow is clipped by the window bounds and the card looks like a sticker. -->
  <Grid Margin="12">
    <Border x:Name="Card"
            Background="{DynamicResource BrushCard}"
            BorderBrush="{DynamicResource BrushCardEdge}"
            BorderThickness="{DynamicResource CardEdgeThickness}"
            CornerRadius="{DynamicResource CardCorner}"
            Effect="{DynamicResource CardShadow}">

      <!-- Second, lighter stroke just inside the dark one. Together they keep the
           card's edge visible whether it is sitting on a grey editor or on a white
           browser window. -->
      <Border BorderBrush="{DynamicResource BrushCardInner}"
              BorderThickness="{DynamicResource CardInnerThickness}"
              CornerRadius="{DynamicResource CardInnerCorner}">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
          </Grid.RowDefinitions>

          <!-- Today's time with at least one session open. The height is fixed
               because the script sizes the window from it before WPF has
               measured anything. Tabular digits keep the number from shifting
               sideways as it counts. The two small lines on the left together
               match the number's height, so neither side floats. Their bottom
               margin puts the lower line on the timer's baseline. The right
               margin lines the timer up with the row timers below. -->
          <Border x:Name="WorkClock" Grid.Row="0" Height="32" Margin="14,10,16,0">
            <Grid>
              <!-- The settings menu. Three bars rather than a gear, because it
                   opens a menu and that is the sign people read as one. The
                   transparent background makes the whole box clickable, not only
                   the strokes of the glyph. -->
              <TextBlock x:Name="MenuButton"
                         Text="&#x2630;"
                         HorizontalAlignment="Left"
                         VerticalAlignment="Center"
                         Padding="0,0,6,0"
                         FontSize="16"
                         Background="Transparent"
                         Cursor="Hand"
                         ToolTip="Settings"
                         Foreground="{DynamicResource BrushTextDim}" />
              <StackPanel HorizontalAlignment="Left"
                          VerticalAlignment="Bottom"
                          Margin="24,0,0,4">
                <TextBlock Text="VIBING SESSION"
                           FontFamily="{DynamicResource FontClock}"
                           FontWeight="SemiBold"
                           FontSize="{DynamicResource SizeClockCaption}"
                           Foreground="{DynamicResource BrushText}" />
                <TextBlock x:Name="WorkClockSub"
                           Text=""
                           FontFamily="{DynamicResource FontClock}"
                           FontSize="{DynamicResource SizeClockCaption}"
                           Typography.NumeralAlignment="Tabular"
                           Foreground="{DynamicResource BrushTextDim}" />
              </StackPanel>
              <TextBlock x:Name="WorkClockText"
                         Text="0:00:00"
                         HorizontalAlignment="Right"
                         VerticalAlignment="Bottom"
                         FontFamily="{DynamicResource FontClock}"
                         FontWeight="SemiBold"
                         FontStretch="Condensed"
                         FontSize="{DynamicResource SizeClock}"
                         Typography.NumeralAlignment="Tabular"
                         Foreground="{DynamicResource BrushText}" />
            </Grid>
          </Border>

          <!-- Rows are positioned by hand on a Canvas rather than stacked, because
               a row that changes state slides to its new place and only a Canvas
               lets us animate Top. The script sets the margin from CardPadding. -->
          <Canvas x:Name="RowCanvas" Grid.Row="1" Margin="10,10,10,0" />

          <TextBlock x:Name="WarnText"
                     Grid.Row="2"
                     Margin="14,2,14,8"
                     FontFamily="{DynamicResource FontText}"
                     FontSize="{DynamicResource SizeHeader}"
                     Foreground="{DynamicResource BrushBlocked}"
                     TextTrimming="CharacterEllipsis"
                     Visibility="Collapsed" />
        </Grid>
      </Border>
    </Border>
  </Grid>
</Window>
```

- [ ] **Step 6: Point `Row.xaml` at the keys**

Make exactly these replacements, each on the element named:

| Element | Old | New |
| --- | --- | --- |
| root `Border` (`RowBg`) | `Width="360"` | `Width="{DynamicResource RowWidth}"` |
| root `Border` | `Height="42"` | `Height="{DynamicResource RowHeight}"` |
| root `Border` | `CornerRadius="8"` | `CornerRadius="{DynamicResource RowCorner}"` followed by new lines `BorderThickness="{DynamicResource RowEdgeThickness}"` and `BorderBrush="{DynamicResource BrushRowEdge}"` |
| `Stripe` | `CornerRadius="6,0,0,6"` | `CornerRadius="{DynamicResource StripeCorner}"` |
| `Model` | `FontFamily="Segoe UI"` | `FontFamily="{DynamicResource FontText}"` |
| `Model` | `FontSize="9"` | `FontSize="{DynamicResource SizeModel}"` |
| `Label` | `FontFamily="Segoe UI"` | `FontFamily="{DynamicResource FontText}"` |
| `Label` | `FontWeight="SemiBold"` | `FontWeight="{DynamicResource LabelWeight}"` |
| `Label` style | `<Setter Property="FontSize" Value="15" />` | `<Setter Property="FontSize" Value="{DynamicResource SizeLabel}" />` |
| `Label` style trigger | `<Setter Property="FontSize" Value="13" />` | `<Setter Property="FontSize" Value="{DynamicResource SizeLabelWithDetail}" />` |
| `Detail` | `FontFamily="Segoe UI"` | `FontFamily="{DynamicResource FontText}"` |
| `Detail` | `FontSize="11"` | `FontSize="{DynamicResource SizeDetail}"` |
| `Timer` | `FontFamily="Segoe UI"` | `FontFamily="{DynamicResource FontText}"` |
| `Timer` | `FontSize="12"` | `FontSize="{DynamicResource SizeTimer}"` |

`SoundMark` keeps `Segoe UI Symbol` at 12; the context bar keeps its sizes. The stripe's comment about corners stays as it is.

- [ ] **Step 7: Replace `UnityRow.xaml`**

```xml
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="RowBg"
        Width="{DynamicResource RowWidth}"
        Height="{DynamicResource RowHeight}"
        CornerRadius="{DynamicResource RowCorner}"
        BorderThickness="{DynamicResource RowEdgeThickness}"
        BorderBrush="{DynamicResource BrushRowEdge}"
        Background="{DynamicResource BrushRowBase}">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="18" />
      <ColumnDefinition Width="*" />
      <ColumnDefinition Width="72" />
    </Grid.ColumnDefinitions>

    <!-- Same shape and place as an agent row's stripe, so the group reads as part
         of the same card. Its colour says headless or not: a headless editor is
         the one with no window to find, which is why this group exists. -->
    <Border x:Name="Stripe"
            Grid.Column="0"
            Width="14"
            HorizontalAlignment="Left"
            VerticalAlignment="Stretch"
            CornerRadius="{DynamicResource StripeCorner}"
            Background="{DynamicResource BrushWsNeutral}" />

    <!-- Two lines where an agent row has one: the project folder alone does not
         tell two checkouts of the same project apart, the branch does. -->
    <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="4,0,0,0">
      <TextBlock x:Name="Label"
                 FontFamily="{DynamicResource FontText}"
                 FontWeight="{DynamicResource LabelWeight}"
                 FontSize="{DynamicResource SizeLabelWithDetail}"
                 Foreground="{DynamicResource BrushText}"
                 TextTrimming="CharacterEllipsis"
                 Text="" />
      <TextBlock x:Name="Detail"
                 FontFamily="{DynamicResource FontText}"
                 FontSize="{DynamicResource SizeDetail}"
                 Foreground="{DynamicResource BrushTextDim}"
                 TextTrimming="CharacterEllipsis"
                 Text="" />
    </StackPanel>

    <!-- Memory on top because it is the number that runs a machine out of room;
         CPU under it as a share of the whole machine, as Task Manager shows it. -->
    <StackPanel Grid.Column="2" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="0,0,10,0">
      <TextBlock x:Name="Memory"
                 HorizontalAlignment="Right"
                 FontFamily="{DynamicResource FontText}"
                 FontSize="{DynamicResource SizeTimer}"
                 Foreground="{DynamicResource BrushText}"
                 Typography.NumeralAlignment="Tabular"
                 Text="" />
      <TextBlock x:Name="Cpu"
                 HorizontalAlignment="Right"
                 FontFamily="{DynamicResource FontText}"
                 FontSize="{DynamicResource SizeDetail}"
                 Foreground="{DynamicResource BrushTextDim}"
                 Typography.NumeralAlignment="Tabular"
                 Text="" />
    </StackPanel>
  </Grid>
</Border>
```

- [ ] **Step 8: Replace `Header.xaml`**

```xml
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="HeaderRoot"
        Width="{DynamicResource RowWidth}"
        Height="{DynamicResource HeaderHeight}"
        Background="Transparent">
  <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom" Margin="4,0,0,4">
    <!-- Same hue as the stripe down every row in this group. The swatch is what
         ties the heading to its rows without repeating the name on each one. -->
    <Rectangle x:Name="Swatch"
               Width="8" Height="8"
               RadiusX="{DynamicResource SwatchRadius}" RadiusY="{DynamicResource SwatchRadius}"
               VerticalAlignment="Center" />
    <TextBlock x:Name="HeaderLabel"
               Margin="8,0,0,0"
               VerticalAlignment="Center"
               FontFamily="{DynamicResource FontText}"
               FontSize="{DynamicResource SizeHeader}"
               FontWeight="SemiBold"
               Foreground="{DynamicResource BrushTextDim}"
               TextTrimming="CharacterEllipsis"
               Text="" />
  </StackPanel>
</Border>
```

- [ ] **Step 9: Merge Classic into the window in the script**

In `AgentTrafficLight.ps1`, directly after `$window    = Import-Xaml 'AgentTrafficLight.xaml'` (line 1180), add:

```powershell
# The look comes from the presets folder, Classic first. Merged before anything
# reads a resource, so the lookups below and every row built later find them.
[void]$window.Resources.MergedDictionaries.Add((Import-Xaml 'presets\Classic.xaml'))
```

Then, so the static check's "nothing uses" rule passes for the keys the script will read in Task 2, extend the existing `$brush` table at lines 1188-1209 with the three outline brushes (Task 2 replaces this table with a function):

```powershell
    RowEdge      = $window.FindResource('BrushRowEdge')
    RowEdgeOnWait  = $window.FindResource('BrushRowEdgeOnWait')
    RowEdgeOnBlock = $window.FindResource('BrushRowEdgeOnBlock')
```

placed after the `Headless = ...` line. Also, in the same spot, read the three density keys no template uses, so the check counts them as used (the check finds uses by the literal text `FindResource('Key')`):

```powershell
[void]$window.FindResource('RowGap')
[void]$window.FindResource('GroupGap')
[void]$window.FindResource('CardPadding')
```

placed after the closing `}` of the `$brush` table. Task 2 replaces both.

- [ ] **Step 10: Run the static check**

Run: `powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$Scratch\check-presets.ps1"`
Expected: `0 failed`. A `FAIL ... uses X, which Classic does not define` is a typo in a template; fix the template.

- [ ] **Step 11: Check the running card is unchanged**

```powershell
. "$Scratch\live.ps1"
$t = Get-Date
Restart-Card
$now = Get-Dump
Compare-Object (Get-Content "$Scratch\baseline-dump.txt" | Select-Object -Skip 1) ($now | Select-Object -Skip 1)
Get-NewErrors $t
```

Expected: no differences (rows that changed state or label in between may differ in their label text only) and no new errors. Look at the card: it must look exactly as before, including the menus.

- [ ] **Step 12: Commit**

```powershell
git add presets/Classic.xaml AgentTrafficLight.xaml Row.xaml UnityRow.xaml Header.xaml AgentTrafficLight.ps1
git commit -F "$Scratch\msg.txt"
```

with `$Scratch\msg.txt`:

```
Move the card's look into presets\Classic.xaml

Every colour, corner, outline, font, size and shadow is now a named
resource in presets\Classic.xaml, merged into the window before anything
is drawn, and the templates and menu styles read them by key. The card
looks exactly as before.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

---

### Task 2: The script reads its look from the presets

The script's brush table and layout numbers come from the merged resources through one function, and the per-state look of a row is split from its state bookkeeping so it can be re-applied. Rows get their state outline.

**Files:**
- Modify: `AgentTrafficLight.ps1:46-59` (tuning block), `:1188-1213` (brush table), `:1294` (`New-Row` row height read-back), `:1482-1572` (`Set-RowState`), `:2172` (`Write-LayoutDump`), `:2686` (Unity row height in `Update-Layout`)
- Test: `$Scratch\check-look.ps1`

**Interfaces:**
- Consumes: the resource keys from Task 1.
- Produces: `Read-StyleValues` (no parameters; sets `$script:brush`, `$script:rowHeight`, `$script:rowGap`, `$script:headerHeight`, `$script:groupGap`, `$script:cardPadding`, `$script:cardWidth`, `$script:ctxBarWidth`, `$window.Width`, `$rowCanvas.Margin`); `Set-RowLook -Rec <row hashtable>` (paints the row for `$Rec.State`, touches no timer or state field); `$brush.RowEdge`, `$brush.RowEdgeOnWait`, `$brush.RowEdgeOnBlock`.

- [ ] **Step 1: Write the look check**

Save as `$Scratch\check-look.ps1`. It loads the real functions out of the script and paints a real row:

```powershell
param([string]$Repo = 'C:\Users\LennartUhrmacher\wkspaces\agent-traffic-light')
# Paints a real row in each state with the script's own functions, under
# Classic and under a test preset, and checks the brushes it ends up with.
Add-Type -AssemblyName PresentationFramework
$fail = 0
function Check($What, $Got, $Want) {
    if ([object]::ReferenceEquals($Got, $Want) -or "$Got" -ceq "$Want") { "ok    $What" } else { "FAIL  $What : got '$Got', want '$Want'"; $script:fail++ }
}
function Import-Xaml([string]$Name) {
    $s = [System.IO.File]::OpenRead((Join-Path $Repo $Name))
    try { [System.Windows.Markup.XamlReader]::Load($s) } finally { $s.Dispose() }
}

$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'AgentTrafficLight.ps1'), [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ('Read-StyleValues', 'Set-RowLook', 'Start-FillAnimation', 'Start-Alarm' -contains $f.Name) {
        . ([scriptblock]::Create($f.Extent.Text))
    }
}
$flipMs = 180; $blinkMs = 600; $breatheMs = 2000; $shadowMargin = 12

$window = Import-Xaml 'AgentTrafficLight.xaml'
$rowCanvas = $window.FindName('RowCanvas')
[void]$window.Resources.MergedDictionaries.Add((Import-Xaml 'presets\Classic.xaml'))
Read-StyleValues

Check 'row height'   $script:rowHeight 42
Check 'row gap'      $script:rowGap 6
Check 'card width'   $script:cardWidth 380
Check 'ctx bar'      $script:ctxBarWidth 330
Check 'window width' $window.Width 404
Check 'canvas'       $rowCanvas.Margin '10,10,10,0'

$el = Import-Xaml 'Row.xaml'
[void]$rowCanvas.Children.Add($el)
$rec = @{ Element = $el; Bg = $el; Alarm = $null; State = ''
          LabelText = $el.FindName('Label'); DetailText = $el.FindName('Detail'); TimerText = $el.FindName('Timer')
          SoundMark = $el.FindName('SoundMark'); Spinner = $el.FindName('Spinner')
          WorkSince = 'w'; FinishedAt = 'f'; Since = 's' }

$expect = @{
    Working  = @{ Edge = 'RowEdge';        Label = 'Text';        Timer = 'TextDim' }
    Waiting  = @{ Edge = 'RowEdgeOnWait';  Label = 'TextOnWait';  Timer = 'TimerOnWait' }
    Blocked  = @{ Edge = 'RowEdgeOnBlock'; Label = 'TextOnBlock'; Timer = 'TimerOnBlock' }
    Watching = @{ Edge = 'RowEdge';        Label = 'TextDim';     Timer = 'TextDim' }
}
foreach ($state in 'Working', 'Waiting', 'Blocked', 'Watching') {
    $rec.State = $state
    Set-RowLook -Rec $rec
    $e = $expect[$state]
    Check "$state edge"  $rec.Bg.BorderBrush        $brush[$e.Edge]
    Check "$state label" $rec.LabelText.Foreground  $brush[$e.Label]
    Check "$state timer" $rec.TimerText.Foreground  $brush[$e.Timer]
    Check "$state note"  $rec.SoundMark.Foreground  $rec.TimerText.Foreground
    Check "$state detail" $rec.DetailText.Foreground $rec.LabelText.Foreground
    Check "$state alarm"  ($null -ne $rec.Alarm) ($state -eq 'Blocked')
}
Check 'timers untouched' ("{0}{1}{2}" -f $rec.WorkSince, $rec.FinishedAt, $rec.Since) 'wfs'

# A preset over Classic changes what Read-StyleValues and Set-RowLook use.
$test = New-Object System.Windows.ResourceDictionary
$test['RowHeight'] = [double]30
$test['RowEdgeThickness'] = New-Object System.Windows.Thickness 1
$test['BrushRowEdgeOnBlock'] = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Colors]::Yellow)
[void]$window.Resources.MergedDictionaries.Add($test)
Read-StyleValues
Check 'preset row height' $script:rowHeight 30
Check 'preset row gap'    $script:rowGap 6
$rec.State = 'Blocked'
Set-RowLook -Rec $rec
Check 'preset blocked edge' $rec.Bg.BorderBrush.Color ([System.Windows.Media.Colors]::Yellow)
Check 'preset thickness'    $el.BorderThickness '1,1,1,1'

"$fail failed"
exit $fail
```

- [ ] **Step 2: Run it to see it fail**

Run: `powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$Scratch\check-look.ps1"`
Expected: errors that `Read-StyleValues` is not recognized, and `FAIL` lines.

- [ ] **Step 3: Replace the tuning constants**

In the tuning block at the top of `AgentTrafficLight.ps1`, replace the comment line `# Tuning. Sizes and colours live in the XAML; only timings live here, because` and the next line with:

```powershell
# Tuning. Sizes and colours live in the presets folder; only timings live here,
# because they are driven from code rather than from storyboards.
```

Remove these lines (they are read from the preset by `Read-StyleValues` now):

```powershell
# Row height is read back from Row.xaml once a row exists, so the layout and the
# design file can never disagree about it. This is only the value used before
# the first row is built.
$rowHeight     = 42
$rowGap        = 6
$headerHeight  = 22   # drawn above every resolved workspace group
$groupGap      = 8
$ctxBarWidth   = 330  # row width less the stripe it starts after and its margins
```

and

```powershell
$cardPadding   = 10
$cardWidth     = 380
```

Keep `$shadowMargin  = 12` and every timing.

- [ ] **Step 4: Replace the brush table with `Read-StyleValues`**

Replace the whole `$brush = @{ ... }` table and the density `foreach` added in Task 1, Step 9, with:

```powershell
# The colours and sizes the script works with itself, read from the merged
# presets. Run at start and after every switch of preset; everything bound in
# the templates follows a switch by itself, these do not.
#
# The card's width follows the rows: a row, its padding either side, and the
# shadow's room round the card. The context bar starts after the stripe and
# stops short of the timer's margin, 30 in all.
function Read-StyleValues {
    $script:brush = @{
        Working        = $window.FindResource('BrushWorking')
        Waiting        = $window.FindResource('BrushWaiting')
        Blocked        = $window.FindResource('BrushBlocked')
        RowBase        = $window.FindResource('BrushRowBase')
        RowEdge        = $window.FindResource('BrushRowEdge')
        RowEdgeOnWait  = $window.FindResource('BrushRowEdgeOnWait')
        RowEdgeOnBlock = $window.FindResource('BrushRowEdgeOnBlock')
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
        Ws             = @(
            $window.FindResource('BrushWs0'),
            $window.FindResource('BrushWs1'),
            $window.FindResource('BrushWs2'),
            $window.FindResource('BrushWs3')
        )
    }
    $script:rowHeight    = [double]$window.FindResource('RowHeight')
    $script:rowGap       = [double]$window.FindResource('RowGap')
    $script:headerHeight = [double]$window.FindResource('HeaderHeight')
    $script:groupGap     = [double]$window.FindResource('GroupGap')
    $script:cardPadding  = [double]$window.FindResource('CardPadding')
    $rowWidth            = [double]$window.FindResource('RowWidth')
    $script:cardWidth    = $rowWidth + 2 * $script:cardPadding
    $script:ctxBarWidth  = $rowWidth - 30
    $window.Width = $script:cardWidth + 2 * $shadowMargin
    $rowCanvas.Margin = New-Object System.Windows.Thickness($script:cardPadding, $script:cardPadding, $script:cardPadding, 0)
}

Read-StyleValues
```

- [ ] **Step 5: Stop reading the row height back from the row**

In `New-Row`, remove:

```powershell
    # Keep the layout honest about the size the design file actually specifies.
    if ($element.Height -gt 0) { $script:rowHeight = $element.Height }
```

In `Update-Layout`, replace `$y += $unityRow.Element.Height + $rowGap` with:

```powershell
            $y += $script:rowHeight + $rowGap
```

- [ ] **Step 6: Split `Set-RowLook` out of `Set-RowState`**

In `Set-RowState`, replace everything from the line `# Stop whatever motion the previous state was running before starting the` to the end of the function (the closing `}` after `$Rec.DetailText.Foreground = $Rec.LabelText.Foreground`) with:

```powershell
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
```

- [ ] **Step 7: Put the density into the layout dump**

In `Write-LayoutDump`, replace its first `[void]$lines.Add(...)` line with:

```powershell
    [void]$lines.Add(('{0:o}  drag={1}  order={2}  preset={3}  pitch={4}  height={5}' -f (Get-Date), ($null -ne $script:drag),
        ($script:userOrder -join ','), $script:preset, ($script:rowHeight + $rowGap), $window.Height))
```

`$script:preset` is set in Task 3; until then it prints empty.

- [ ] **Step 8: Run both checks**

Run:

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$Scratch\check-look.ps1"
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$Scratch\check-presets.ps1"
```

Expected: `0 failed` from each.

- [ ] **Step 9: Check the running card is unchanged**

```powershell
. "$Scratch\live.ps1"
$t = Get-Date
Restart-Card
$now = Get-Dump
$now[0]
Compare-Object (Get-Content "$Scratch\baseline-dump.txt" | Select-Object -Skip 1) ($now | Select-Object -Skip 1)
Get-NewErrors $t
```

Expected: the first line ends `pitch=48  height=...`; no row differences beyond labels; no new errors. Drag a row within its group by hand: it moves one slot per 48 px as before.

- [ ] **Step 10: Commit**

`$Scratch\msg.txt`:

```
Read the card's colours and sizes from the presets

Read-StyleValues builds the brush table and the layout numbers from the
merged presets, and works out the card's width and the context bar's from
the row width. Set-RowLook paints a row for its state, apart from the
state's bookkeeping, and gives each state its outline, which Classic
leaves invisible.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

```powershell
git add AgentTrafficLight.ps1
git commit -F "$Scratch\msg.txt"
```

---

### Task 3: Switching presets

A saved `Preset` setting, a **Style** submenu that lists `presets\`, and `Set-Preset`, which swaps the preset over Classic and repaints. Menus take the current presets. A `state\preset.flag` lets a check switch the live card the way `dump.flag` lets it dump the layout.

**Files:**
- Modify: `AgentTrafficLight.ps1`: settings block (`$script:settings`, `Read-Settings`, `Save-Settings`), right after the line added in Task 1, Step 9, `New-CardMenu`, `Show-SettingsMenu`, `Update-Card` (after the dump flag)
- Test: `$Scratch\check-menu.ps1`, live checks below

**Interfaces:**
- Consumes: `Read-StyleValues`, `Set-RowLook`, `Sync-UnityRows`, `Update-Layout`, `Save-Settings`, `Add-CardMenuAction`, `New-CardMenuItem`, `Import-Xaml`.
- Produces: `Import-Preset -Name <string>` returns a `ResourceDictionary` or `$null` for Classic, throws if missing, unparsable or not a dictionary; `Use-PresetLayer -Dict <ResourceDictionary or $null>`; `Get-PresetNames` returns `Classic` then the other names sorted; `Set-Preset -Name <string>`; `New-StyleMenu` returns a `MenuItem`; `$script:preset` holds the active name; `$script:settings.Preset`.

- [ ] **Step 1: Write the menu check**

Save as `$Scratch\check-menu.ps1`:

```powershell
param([string]$Repo = 'C:\Users\LennartUhrmacher\wkspaces\agent-traffic-light')
# Checks preset loading, the layer swap, the Style menu and that a new menu
# carries the window's presets, with the script's own functions.
Add-Type -AssemblyName PresentationFramework
$fail = 0
function Check($What, $Got, $Want) { if ("$Got" -ceq "$Want") { "ok    $What" } else { "FAIL  $What : got '$Got', want '$Want'"; $script:fail++ } }
function Import-Xaml([string]$Name) {
    $s = [System.IO.File]::OpenRead((Join-Path $Repo $Name))
    try { [System.Windows.Markup.XamlReader]::Load($s) } finally { $s.Dispose() }
}
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'AgentTrafficLight.ps1'), [ref]$null, [ref]$null)
$wanted = 'Import-Preset', 'Use-PresetLayer', 'Get-PresetNames', 'New-StyleMenu', 'New-CardMenu', 'New-CardMenuItem', 'Add-CardMenuAction'
foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -contains $f.Name) { . ([scriptblock]::Create($f.Extent.Text)) }
}
function Write-ErrorLog { param($Where, $Problem) }
$window = Import-Xaml 'AgentTrafficLight.xaml'
[void]$window.Resources.MergedDictionaries.Add((Import-Xaml 'presets\Classic.xaml'))
$presetDir = Join-Path $Repo 'presets'

$probe = Join-Path $presetDir 'ZzProbe.xaml'
Set-Content $probe '<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:sys="clr-namespace:System;assembly=mscorlib" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><sys:Double x:Key="RowHeight">30</sys:Double></ResourceDictionary>' -Encoding UTF8
try {
    $names = @(Get-PresetNames)
    Check 'Classic listed first' $names[0] 'Classic'
    Check 'probe listed'         ($names -contains 'ZzProbe') 'True'

    Check 'Classic has no layer' ($null -eq (Import-Preset -Name 'Classic')) 'True'
    $threw = $false; try { Import-Preset -Name 'NoSuchPreset' | Out-Null } catch { $threw = $true }
    Check 'missing preset throws' $threw 'True'

    Use-PresetLayer -Dict (Import-Preset -Name 'ZzProbe')
    Check 'layer on top'     $window.Resources.MergedDictionaries.Count 2
    Check 'probe wins'       $window.FindResource('RowHeight') 30
    Check 'Classic beneath'  $window.FindResource('RowGap') 6
    Use-PresetLayer -Dict (Import-Preset -Name 'ZzProbe')
    Check 'still one layer'  $window.Resources.MergedDictionaries.Count 2
    Use-PresetLayer -Dict $null
    Check 'layer removed'    $window.Resources.MergedDictionaries.Count 1
    Check 'Classic again'    $window.FindResource('RowHeight') 42

    Use-PresetLayer -Dict (Import-Preset -Name 'ZzProbe')
    $menu = New-CardMenu
    Check 'menu has presets' $menu.Resources.MergedDictionaries.Count 2
    Check 'menu sees preset' $menu.TryFindResource('RowHeight') 30

    $script:preset = 'ZzProbe'
    $style = New-StyleMenu
    $ticked = @($style.Items | Where-Object { $_.IsChecked } | ForEach-Object { $_.Header })
    Check 'Style ticks current' ($ticked -join ',') 'ZzProbe'
} finally { Remove-Item $probe -Force }

"$fail failed"
exit $fail
```

- [ ] **Step 2: Run it to see it fail**

Run: `powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$Scratch\check-menu.ps1"`
Expected: errors that `Get-PresetNames` is not recognized, and `FAIL` lines.

- [ ] **Step 3: Add `Preset` to the settings**

In the settings comment block, after the `GroupByRepo` paragraph, add:

```powershell
# Preset is the name of a file in the presets folder, laid over Classic. One
# that has gone missing falls back to Classic when the card starts.
#
```

Change the defaults line to:

```powershell
$script:settings = @{ ShowUnityEditors = $true; GroupByRepo = $false; DefaultSound = ''; Preset = 'Classic'; Sounds = @{} }
```

In `Read-Settings`, after the `DefaultSound` line, add:

```powershell
        if ($saved.Preset) { $script:settings.Preset = [string]$saved.Preset }
```

In `Save-Settings`, after `DefaultSound     = $script:settings.DefaultSound`, add:

```powershell
            Preset           = $script:settings.Preset
```

- [ ] **Step 4: Load the saved preset at start**

Replace the two lines added in Task 1, Step 9 (the comment and the `MergedDictionaries.Add` of Classic) with:

```powershell
# The look comes from the presets folder: Classic, which holds every key, and
# the chosen preset laid over it, holding only what it changes. Merged before
# anything reads a resource, so the lookups below and every row built later
# find them.
$presetDir = Join-Path $PSScriptRoot 'presets'

# The chosen preset's dictionary, or null for Classic, which is the base and
# needs no second layer. Throws if the file is missing or is not a preset, so
# the caller decides what a failure means.
function Import-Preset {
    param([string]$Name)
    if ($Name -eq 'Classic') { return $null }
    $dict = Import-Xaml (Join-Path 'presets' "$Name.xaml")
    if (-not ($dict -is [System.Windows.ResourceDictionary])) { throw "presets\$Name.xaml is not a ResourceDictionary" }
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
```

This stays before `Read-StyleValues` is defined and called.

- [ ] **Step 5: Add `Set-Preset`, the Style menu, the menu hand-over and the flag**

Replace `New-CardMenu` with:

```powershell
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
```

After `New-DefaultSoundMenu`, add:

```powershell
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
```

In `Show-SettingsMenu`, after `[void]$menu.Items.Add((New-DefaultSoundMenu))`, add:

```powershell
    [void]$menu.Items.Add((New-StyleMenu))
```

In `Update-Card`, after the dump flag block (the `if (Test-Path $dumpFlag) { ... }`), add:

```powershell
    # Write a preset's name into state/preset.flag and this poll switches to it,
    # the way the Style menu does, so a check can switch the live card without
    # clicking through it.
    $presetFlag = Join-Path $stateDir 'preset.flag'
    if (Test-Path $presetFlag) {
        $name = ([string](Get-Content $presetFlag -Raw)).Trim()
        Remove-Item $presetFlag -Force -ErrorAction SilentlyContinue
        try { Set-Preset -Name $name } catch { Write-ErrorLog -Where 'style' -Problem $_ }
    }
```

- [ ] **Step 6: Run the checks**

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$Scratch\check-menu.ps1"
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$Scratch\check-look.ps1"
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$Scratch\check-presets.ps1"
```

Expected: `0 failed` from each.

- [ ] **Step 7: A saved preset that no longer exists**

```powershell
. "$Scratch\live.ps1"
Copy-Item state\settings.json "$Scratch\settings.before-task3.json"
$s = Get-Content state\settings.json -Raw | ConvertFrom-Json
$s | Add-Member -NotePropertyName Preset -NotePropertyValue 'Gone' -Force
$s | ConvertTo-Json -Depth 4 | Set-Content state\settings.json -Encoding UTF8
$t = Get-Date
Restart-Card
(Get-Dump)[0]
Get-NewErrors $t
```

Expected: the dump's first line has `preset=Classic  pitch=48`; exactly one new error line containing `[style]` and `Gone.xaml`. Then put the setting back:

```powershell
Copy-Item "$Scratch\settings.before-task3.json" state\settings.json -Force
Restart-Card
```

- [ ] **Step 8: Switching live, and a broken preset on a switch**

```powershell
. "$Scratch\live.ps1"
Set-Content presets\ZzDense.xaml '<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:sys="clr-namespace:System;assembly=mscorlib" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><sys:Double x:Key="RowHeight">30</sys:Double><sys:Double x:Key="RowGap">2</sys:Double></ResourceDictionary>' -Encoding UTF8
Set-Content presets\ZzBroken.xaml '<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><Oops' -Encoding UTF8
$t = Get-Date
Switch-Preset 'ZzDense';  $dense = (Get-Dump)[0]
Switch-Preset 'ZzBroken'; $broken = (Get-Dump)[0]
Switch-Preset 'Classic';  $back = (Get-Dump)[0]
$dense; $broken; $back
Get-NewErrors $t
Remove-Item presets\ZzDense.xaml, presets\ZzBroken.xaml
```

Expected:
- `$dense` has `preset=ZzDense  pitch=32` and a smaller `height=` than `$back`.
- `$broken` still has `preset=ZzDense  pitch=32`.
- `$back` has `preset=Classic  pitch=48`.
- Exactly one new error line, containing `[style]` (the XAML parse error of `ZzBroken`).

- [ ] **Step 9: Commit**

`$Scratch\msg.txt`:

```
Pick the card's style from the settings menu

Style in the settings menu lists the presets folder and lays the picked
preset over Classic on the spot: the bound values follow by themselves,
and the script reads its colours and sizes again, repaints every row and
lays the card out afresh. The choice is saved; a preset that is missing
or broken is logged, and the card keeps Classic at start or the current
preset on a switch. Each menu takes the presets in use when it opens.
state\preset.flag switches the live card for checks, like dump.flag.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

```powershell
git add AgentTrafficLight.ps1
git commit -F "$Scratch\msg.txt"
```

---

### Task 4: The Terminal preset, installer and README

**Files:**
- Create: `presets\Terminal.xaml`
- Modify: `Install.ps1` (required files list)
- Modify: `README.md` (settings section)

**Interfaces:**
- Consumes: every key from Task 1; `Set-Preset` via `state\preset.flag` from Task 3.

- [ ] **Step 1: Write `presets\Terminal.xaml`**

```xml
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                    xmlns:sys="clr-namespace:System;assembly=mscorlib">

  <!-- A modern dark terminal: black, square, flat and monospaced, with rows
       drawn as boxes. Only what differs from Classic is here.

       The state fills stay dark and the outline carries the state, the way a
       terminal UI draws a box in a colour rather than flooding it. The colours
       keep their meaning, in a terminal's palette: blue working, green
       finished, yellow blocked, no red. -->

  <SolidColorBrush x:Key="BrushCard"        Color="#0C0C0C" />
  <SolidColorBrush x:Key="BrushCardEdge"    Color="#3A3A3A" />
  <Thickness x:Key="CardInnerThickness">0</Thickness>

  <SolidColorBrush x:Key="BrushText"        Color="#CCCCCC" />
  <SolidColorBrush x:Key="BrushTextDim"     Color="#767676" />

  <SolidColorBrush x:Key="BrushWorking"     Color="#3B78FF" />
  <SolidColorBrush x:Key="BrushWaiting"     Color="#0F2416" />
  <SolidColorBrush x:Key="BrushBlocked"     Color="#2E2606" />

  <SolidColorBrush x:Key="BrushRowBase"     Color="#141414" />
  <SolidColorBrush x:Key="BrushTextOnWait"  Color="#E6E6E6" />
  <SolidColorBrush x:Key="BrushTextOnBlock" Color="#E6E6E6" />
  <SolidColorBrush x:Key="BrushTimerOnWait"  Color="#7FBF8A" />
  <SolidColorBrush x:Key="BrushTimerOnBlock" Color="#C9B46A" />

  <Thickness x:Key="RowEdgeThickness">1</Thickness>
  <SolidColorBrush x:Key="BrushRowEdge"        Color="#2A2A2A" />
  <SolidColorBrush x:Key="BrushRowEdgeOnWait"  Color="#16C60C" />
  <SolidColorBrush x:Key="BrushRowEdgeOnBlock" Color="#C19C00" />

  <!-- Workspace hues from the terminal palette, leaving out its blue, green
       and yellow, which mean a state here. -->
  <SolidColorBrush x:Key="BrushWs0"         Color="#D670D6" />
  <SolidColorBrush x:Key="BrushWs1"         Color="#61D6D6" />
  <SolidColorBrush x:Key="BrushWs2"         Color="#B4A0FF" />
  <SolidColorBrush x:Key="BrushWs3"         Color="#A0A0A0" />

  <SolidColorBrush x:Key="BrushMenu"          Color="#0C0C0C" />
  <SolidColorBrush x:Key="BrushMenuEdge"      Color="#3A3A3A" />
  <SolidColorBrush x:Key="BrushMenuHighlight" Color="#262626" />
  <SolidColorBrush x:Key="BrushMenuTick"      Color="#3B78FF" />

  <CornerRadius x:Key="CardCorner">0</CornerRadius>
  <CornerRadius x:Key="CardInnerCorner">0</CornerRadius>
  <CornerRadius x:Key="RowCorner">0</CornerRadius>
  <CornerRadius x:Key="StripeCorner">0</CornerRadius>
  <CornerRadius x:Key="MenuCorner">0</CornerRadius>
  <CornerRadius x:Key="MenuItemCorner">0</CornerRadius>
  <sys:Double x:Key="SwatchRadius">0</sys:Double>

  <x:Null x:Key="CardShadow" />
  <x:Null x:Key="MenuShadow" />

  <!-- Consolas where Cascadia Mono is not installed. -->
  <FontFamily x:Key="FontText">Cascadia Mono, Consolas</FontFamily>
  <FontFamily x:Key="FontClock">Cascadia Mono, Consolas</FontFamily>
  <FontWeight x:Key="LabelWeight">Normal</FontWeight>
  <sys:Double x:Key="SizeLabel">13</sys:Double>
  <sys:Double x:Key="SizeLabelWithDetail">12</sys:Double>
  <sys:Double x:Key="SizeClock">22</sys:Double>
  <sys:Double x:Key="SizeClockCaption">10</sys:Double>

  <!-- Denser rows, at the same width, so the card does not jump sideways
       when the style changes. -->
  <sys:Double x:Key="RowHeight">32</sys:Double>
  <sys:Double x:Key="RowGap">2</sys:Double>
  <sys:Double x:Key="CardPadding">8</sys:Double>
</ResourceDictionary>
```

- [ ] **Step 2: Run the static check**

Run: `powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$Scratch\check-presets.ps1"`
Expected: `0 failed`. If `x:Null` is reported as not parsing, replace the two `x:Null` lines with zero-strength shadows, `<DropShadowEffect x:Key="CardShadow" Opacity="0" />` and the same for `MenuShadow`, and run again.

- [ ] **Step 3: Require the Classic preset in `Install.ps1`**

In the `foreach ($needed in @(...))` list, after `(Join-Path $toolDir 'Header.xaml'),`, add:

```powershell
                      (Join-Path $toolDir 'presets\Classic.xaml'),
```

- [ ] **Step 4: Describe Style in the README**

In `README.md`, after the line `The three bars left of the session clock open the card's settings, saved in \`state\settings.json\`.`, add a blank line and:

```markdown
Under Style the settings pick the card's look, applied on the spot: Classic, the card as described
here, or Terminal, square, flat and monospaced, with denser rows drawn as boxes in the state's colour.
Each style is a file in `presets\`. Classic holds every colour, size, corner, outline, font and
shadow the card uses; any other preset holds only what it changes and is laid over Classic, so a new
one starts as a copy of Terminal with its values changed. Whatever the style, the colours keep their
meaning.
```

- [ ] **Step 5: Run every check**

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$Scratch\check-presets.ps1"
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$Scratch\check-look.ps1"
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$Scratch\check-menu.ps1"
```

Expected: `0 failed` from each.

- [ ] **Step 6: Switch the live card to Terminal and back**

```powershell
. "$Scratch\live.ps1"
$t = Get-Date
Restart-Card
$classic = (Get-Dump)[0]
Switch-Preset 'Terminal'; $terminal = Get-Dump
Restart-Card;             $kept = (Get-Dump)[0]
Switch-Preset 'Classic';  $back = (Get-Dump)[0]
$classic; $terminal[0]; $kept; $back
$terminal | Select-Object -Skip 1
Get-NewErrors $t
```

Expected:
- `$classic` and `$back`: `preset=Classic  pitch=48`, same `height=`.
- `$terminal[0]`: `preset=Terminal  pitch=34`, smaller `height=`; within each group the row tops step by 34.
- `$kept`: `preset=Terminal  pitch=34` (the choice survived a restart).
- No new errors.

- [ ] **Step 7: Look at it (by hand)**

With the card on Terminal, check:
- square card and rows, no shadow, monospace text, rows outlined: grey working, green finished, yellow blocked, a blocked row still pulsing;
- the settings menu and its Style, Default sound and a row's Sound submenus are square and black with no shadow;
- dragging a row moves it one slot per 34 px;
- switch to Classic from the menu: the card is exactly as before, menus included.

- [ ] **Step 8: Commit**

`$Scratch\msg.txt`:

```
Add the Terminal style

A modern dark terminal look: black, square, flat and monospaced, with
denser rows drawn as boxes in the colour of their state. The installer
now needs presets\Classic.xaml, and the README describes Style.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

```powershell
git add presets/Terminal.xaml Install.ps1 README.md
git commit -F "$Scratch\msg.txt"
```
