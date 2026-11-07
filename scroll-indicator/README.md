# Scroll Indicator

Hyprland's scrolling layout has no built-in position indicator: you can't tell how many windows are
off-screen or where you are in the row. This bar widget adds one: one dot per column, **●** for the
focused column and **○** for the rest. You can also use a continuous line with a different color for
the focused column. It hides itself on workspaces that don't use the scrolling layout.

```
○ ● ○ ○      ← 4 columns, the 2nd is focused
```

Further down there's also optional Hyprland config for **visual cues**, which work even if you never
look at the bar: a small **bump** when you hit the first/last column
([Example keybinds](#example-keybinds)), and a vertical **drawer bounce** when you enter the scrolling
workspace ([Drawer bounce](#optional-a-drawer-bounce-when-entering-the-scrolling-workspace)).

## Plugin

| Field | Value |
| --- | --- |
| ID | `83raiders/scroll-indicator` |
| Entries | Bar widget: `dots` |

## Requirements

- Noctalia with plugin API **43 or newer**.
- Hyprland **0.56 or newer** (reads `tiledLayout` and workspace names from `hyprctl -j`).
- `hyprctl` on `PATH` (ships with Hyprland).
- `socat` on `PATH`, for live updates from Hyprland's event socket. Without it the widget falls back
  to polling every 0.4 s.

## Usage

1. Enable the plugin in **Settings → Plugins**, or run
   `noctalia msg plugins enable 83raiders/scroll-indicator`.
2. Add the `dots` widget to a bar section, for example in `settings.toml`:

   ```toml
   [bar.default]
   center = [ "workspaces", "scroll", "clock" ]

   [widget.scroll]
   type = "83raiders/scroll-indicator:dots"
   ```

3. Switch to a workspace that uses the scrolling layout. The dots update as you move between columns,
   open or close windows. Hover the widget for "Scrolling: column 2 of 4". Windows stacked in the same
   column count as one dot; floating windows are not counted. Hover a dot or line segment for a
   hover highlight and a native window-title tooltip. Stacked columns list all their window titles; empty
   titles fall back to the app name, then “Untitled window”. Right-click any segment to open settings.

### Settings

Open **Settings → Plugins → Scroll Indicator** (the gear on its row), or **right-click the indicator**.
Changes save through Noctalia and apply to the widget automatically. Settings follow the order below;
Noctalia currently displays a flat list without section headings. Existing configuration keys and
values remain compatible.

#### Indicator appearance

Choose how columns are represented on the bar.

- **Indicator style:** Dots (default) or Line. Line joins one equal-length segment per column into a
  continuous strip; the segment containing the focused app uses the focus color.
- **Dot shape / Fill unfocused dots:** choose round or square markers and outline or fill inactive dots.
- **Dot size (px) / Dot spacing (px):** adjust the diameter and the gap between dots.
- **Segment length (px) / Line thickness (px):** adjust the length per column and the thickness of the line.
- **Segment gap (px) / Segment corner radius (px):** use zero gap for a continuous strip, or add gaps and rounded
  corners for dashes or pills. Radius is capped at half the segment's shortest side.
- **Outer end radius (px):** rounds only the two outside ends of the line, independently of segment
  rounding. Set the segment corner radius to zero for a continuous line with straight internal joins.
  End radii are capped at half the segment length or line thickness, whichever is smaller.

#### Position on the bar

Center the indicator or place it against a bar edge.

- **Alignment:** Center (default), Top / left, or Bottom / right. For edge alignment, set
  **Bar thickness (px)** to your bar thickness and adjust **Distance from edge (px)**. On a horizontal bar
  this positions the indicator at the top or bottom; on a vertical bar it positions it left or right.
  If the widget has a custom scale, divide the bar thickness by that scale for the alignment size.

#### Focus and colors

Make the focused column stand out from the others.

- **Focused marker size (%):** resize the focused marker from 50% to 400%. 100% keeps its normal
  size; 200% doubles both dimensions. Scaled markers overlap neighboring segments without changing
  their spacing or tooltip targets. Cross-axis room is reserved for the largest configured size.
  When focused and hovered, the larger state size wins. Scaling works with every transition style
  and in vertical bars.
- **Use theme colors:** enabled by default, using the theme's primary color for focus and secondary
  text color for other columns. Turn it off to choose **Focused column color** and **Unfocused column color**.
  Color controls use Noctalia’s native selector: choose a theme role, or **Custom** to open its color
  picker. The highlight color uses the same picker. Opacity and curve sliders support fractional steps.
- **Unfocused opacity:** fade the other columns while keeping the focused column fully opaque.

#### Hover feedback

Customize the marker and highlight shown under the pointer.

- **Marker size on hover (%):** resize the marker under the pointer independently of the focused
  marker size. Defaults to 100%; the larger size wins when focused and hovered.
- **Show hover highlight:** enabled by default. Turn off to hide the colored highlight while keeping
  window-title tooltips, marker scaling, and right-click settings. Highlight values are retained,
  including any previously configured zero opacity.
- **Highlight appearance:** choose the theme foreground or a custom color, opacity, length coverage (10–100%),
  thickness, and corner radius. Coverage is centered within each segment. Zero thickness follows the
  marker size; a larger thickness also enlarges the tooltip target. Keep it within the bar's available
  space. Zero opacity hides the cover while retaining window-title tooltips. Highlights fade in and out
  smoothly when animations are enabled; rapid pointer changes preserve the fade's momentum.
  Highlight length, thickness, and corner radius are available under **Show advanced**.

#### Motion

Control transitions when focus changes or columns appear and disappear.

- **Enable animations:** enabled by default. New columns expand and fade in; closing columns
  shrink and fade out while neighboring columns move into place. The last column finishes its exit
  before the widget hides. Opening or closing a window in an existing stack keeps the same column
  marker. Rapid open/close changes continue from the current size, and workspace switches reset
  immediately. Disable for immediate updates; Noctalia’s global animation switch also applies.
- **Transition style:** Crossfade (default) blends the focus color between columns; Slide moves one
  highlight along the whole track; Grow expands the focus highlight from the marker's center; Wipe
  fills along the bar direction. All four work with dots, lines, and vertical bars. Slide can travel
  across gaps between markers. With Bouncy, both highlight edges move on independent springs:
  the leading edge pulls ahead and the trailing edge catches up. **Slide stretch** controls this
  deformation; zero keeps a fixed-length highlight. Rapid focus changes preserve position and
  velocity, so the highlight flows through reversals instead of restarting from rest.
- **Duration (ms):** defaults to 180 ms. Noctalia's global animation switch and speed apply
  to every animation style and curve. For Bouncy, duration sets spring response time; motion ends
  when both position and velocity settle, so it can continue beyond that duration.
- **Motion curve:** Linear has a constant pace; Ease in accelerates; Ease out (default) slows into
  place; Ease in-out accelerates and then slows; Exponential out moves quickly and settles gently;
  Bouncy uses a damped spring with a gentle start and natural settling. Slide can overshoot interior
  columns; at the ends it compresses against the track boundary and releases as the spring rebounds.
  Grow briefly expands past its final size. Opacity and Wipe geometry remain bounded.
  The preset applies to focus changes and new-column fade-ins.
- **Curve tuning:** Easing power adjusts Ease in/out/in-out; Exponential strength adjusts Exponential
  out; Bounce depth adjusts Bouncy's spring damping (0 settles without overshoot, 1 is the default,
  higher values produce a deeper rebound). These fine-tuning controls appear under **Show advanced** for the selected curve.
- **Custom Bézier:** select this curve to edit X1, Y1, X2, and Y2. X controls time and Y controls progress;
  all four range from 0 to 1. The initial values are `(0.25, 0.1, 0.25, 1)`. Use `(0, 0, 1, 1)` for a
  straight, linear curve. Bounded controls keep opacity and sliding highlights within valid limits.

Conditional controls use Noctalia’s single-setting visibility rules. Slide stretch appears for Slide
and applies only with Bouncy. Curve tuning may remain visible when animations are off, but has no
effect until animations are enabled. Highlight appearance controls remain available while the
highlight is hidden so you can configure them before turning it back on.

Sizes are in logical pixels. The indicator follows the bar orientation, including vertical bars.
When a floating app is focused, all columns use the inactive color. Stacked apps still share one
column marker. Middle-click continues to open Noctalia's widget settings.

For example, to select a thin line with custom colors in `settings.toml`:

```toml
[plugin_settings."83raiders/scroll-indicator"]
style = "line"
segment_length = 20
line_thickness = 3
alignment = "bottom"
alignment_size = 34 # match your bar thickness (adjust for widget scale)
edge_inset = 2
line_gap = 0
line_radius = 0
outer_radius = 2
hover_highlight = true
hover_use_theme_color = false
hover_color = "#ffffff"
hover_opacity = 0.18
hover_coverage = 100
hover_thickness = 12
hover_radius = 4
active_scale = 150
hover_scale = 200
inactive_opacity = 0.6
animations = true
animation_duration = 180
animation_style = "slide"
animation_curve = "bouncy"
slide_fluidity = 0.65
curve_power = 3.0
use_theme_colors = false
focused_color = "#89b4fa"
inactive_color = "#9399b2"
```

### Example setup

Built for one scrolling workspace with **2/3-width columns** on a large (4K) screen, used as a parking
spot for apps you want to keep open but don't need to look at often (Hyprland has no minimize). Each
window keeps plenty of room, and a slice of the next column stays visible.

```lua
-- Hyprland Lua config: workspace 10 (the ALT+0 key) uses the scrolling layout
hl.workspace_rule({ workspace = "10", layout = "scrolling", persistent = true })

hl.config({
  scrolling = {
    column_width = 2/3,
    follow_focus = true,
  },
})
```

The widget works with any column width and on any workspace using the scrolling layout.

### Example keybinds

Optional, but they make a scrolling workspace pleasant to use next to normal tiling. The same keys do
the right thing for each layout.

> **This is the author's setup**, tuned for mostly tiling with one scrolling "drawer" workspace for apps
> kept open in the background. It makes workspace switching the easiest key, and scrolling columns
> `SHIFT + arrows`. Plain focus moves and column swaps exist but get used less. The author uses `ALT` as
> the modifier; set `mod` to whatever you use. If you live *in* the scrolling layout, you'll probably
> prefer plain arrows for columns, Niri-style. Adapt freely.

| Keys | On a scrolling workspace | On other layouts |
| --- | --- | --- |
| `SUPER + SHIFT + Left/Right` | move to the previous/next column (a small "bump" at the first/last one) | move the window |
| `SUPER + M` / `SUPER + N` | swap the column left/right | swap split / toggle split |
| `SUPER + Left/Right` | previous/next workspace; `Right` on the last workspace (10) wraps to 1 | previous/next workspace |

Add to your Hyprland Lua config (change `mod` if you use another modifier, for example `"ALT"`):

```lua
local mod = "SUPER"
local COLUMN_WIDTH = 2/3   -- keep in sync with scrolling.column_width

-- Run a different action depending on the focused workspace's layout.
-- Each action is a dispatcher (hl.dsp.*) or a function.
local function per_layout(actions)
    return function()
        local ws = hl.get_active_special_workspace() or hl.get_active_workspace()
        local action = ws and actions[ws.tiled_layout]
        if type(action) == "function" then
            action()
        elseif action then
            hl.dispatch(action)
        end
    end
end

-- Focus the next column; if focus didn't move (first/last column), briefly widen it as a "bump".
local function column_or_bump(dir)
    return function()
        local before = hl.get_active_window()
        hl.dispatch(hl.dsp.focus({ direction = dir }))
        local after = hl.get_active_window()
        if before and after and before.address == after.address then
            hl.dispatch(hl.dsp.layout(string.format("colresize %.6f", COLUMN_WIDTH + 0.07)))
            hl.timer(function()
                hl.dispatch(hl.dsp.layout(string.format("colresize %.6f", COLUMN_WIDTH)))
            end, { timeout = 180, type = "oneshot" })
        end
    end
end

hl.bind(mod .. " + SHIFT + Left", per_layout({
    scrolling = column_or_bump("l"),
    dwindle   = hl.dsp.window.move({ direction = "l" }),
    master    = hl.dsp.window.move({ direction = "l" }),
}))
hl.bind(mod .. " + SHIFT + Right", per_layout({
    scrolling = column_or_bump("r"),
    dwindle   = hl.dsp.window.move({ direction = "r" }),
    master    = hl.dsp.window.move({ direction = "r" }),
}))

hl.bind(mod .. " + M", per_layout({
    scrolling = hl.dsp.layout("swapcol l"),
    dwindle   = hl.dsp.layout("swapsplit"),
}))
hl.bind(mod .. " + N", per_layout({
    scrolling = hl.dsp.layout("swapcol r"),
    dwindle   = hl.dsp.layout("togglesplit"),
}))

hl.bind(mod .. " + Left",  hl.dsp.focus({ workspace = "r-1" }))

-- Next workspace; from the last one (10, e.g. the scrolling "drawer") wrap back to 1
local LAST_WS = 10
hl.bind(mod .. " + Right", function()
    local ws = hl.get_active_workspace()
    if ws and ws.id and ws.id >= LAST_WS then
        hl.dispatch(hl.dsp.focus({ workspace = 1 }))
    else
        hl.dispatch(hl.dsp.focus({ workspace = "r+1" }))
    end
end)
```

The "bump" uses `colresize`, because Hyprland's scrolling layout won't nudge the row by pixels. If your
columns aren't all the same width, drop the bump and use `hl.dsp.focus({ direction = "l" })` directly.

Floating windows on a scrolling workspace aren't columns: while one is focused, no dot is filled. To
keep an app in the row, give it a `tile = true` window rule.

### Optional: a "drawer" bounce when entering the scrolling workspace

Makes the scrolling workspace feel like a drawer: switching to it slides in **vertically** and
**overshoots slightly before settling** (a bounce), while every other workspace keeps a normal sideways
slide. Hyprland's workspace rules can't set an animation per workspace, so the keybinds swap the
`workspaces` animation just before switching.

```lua
local mod = "SUPER"
local SCROLL_WS = 10   -- your scrolling workspace

-- Overshoots past the end and settles back. Raise 1.56 for a bigger bounce; 1.0 = no bounce.
hl.curve("drawer", { type = "bezier", points = { {0.34, 1.56}, {0.64, 1} } })
hl.curve("smooth", { type = "bezier", points = { {0.16, 1}, {0.3, 1} } })

local function goto_ws(target, move)
    if target == SCROLL_WS then
        hl.animation({ leaf = "workspaces", enabled = true, speed = 7, bezier = "drawer", style = "slidefadevert 25%" })
    else
        hl.animation({ leaf = "workspaces", enabled = true, speed = 6, bezier = "smooth", style = "slidefade 10%" })
    end
    if move then
        hl.dispatch(hl.dsp.window.move({ workspace = target, follow = true }))
    else
        hl.dispatch(hl.dsp.focus({ workspace = target }))
    end
end

for i = 1, 10 do
    local key = i % 10   -- workspace 10 is the 0 key
    hl.bind(mod .. " + " .. key, function() goto_ws(i) end)
    hl.bind(mod .. " + SHIFT + " .. key, function() goto_ws(i, true) end)
end
```

This replaces your existing `mod + 1–0` and `mod + SHIFT + 1–0` workspace binds. Switching another
way (clicking a workspace on the bar, `r+1`/`r-1` binds) uses whichever animation was set last; route
those through `goto_ws` too if you want them consistent.

### Pairs well with: a scroll overview

Hyprland's scrolling layout ships without two things that make it easy to live with: a **position
indicator** (this widget) and an **overview** of the whole row. For the overview, the
[hyprland-scroll-overview](https://github.com/yayuuu/hyprland-scroll-overview) plugin by yayuuu shows
every workspace and column zoomed out, Niri-style, and lets you jump around with the arrow keys:

```sh
hyprpm add https://github.com/yayuuu/hyprland-scroll-overview.git
hyprpm update
hyprpm enable scrolloverview
```

Bind it (and its arrow keys) as its README describes, for example a toggle on `mod + TAB`. Define its
`scrolloverview` submap **once**: defining it in two config files binds every key twice, so each press
fires twice.

Some versions of the overview stop responding to Left/Right when a **floating** window is selected on
a scrolling workspace. If you hit that, update the plugin, or give apps you park there a
`tile = true` window rule.

The layout-aware binding style is inspired by the CachyOS and JaKooLit Hyprland configs.

## Notes

Everything the plugin runs:

| Process | When | Why |
| --- | --- | --- |
| `sh -c "hyprctl -j activeworkspace; hyprctl -j activewindow; hyprctl -j clients"` | on each relevant Hyprland event, plus every 2 s as a safety net (every 0.4 s without `socat`) | read the workspace layout, the focused window and window positions |
| `socat -U - UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock` | once, while the widget is loaded | listen to Hyprland's read-only event socket so the dots update instantly |

Animation frames reuse the latest Hyprland snapshot; they do not launch additional processes. The
widget ticks every 16 ms only during a transition, then resumes the existing safety-poll interval.
Hover targets stay in fixed column positions above the animation layers, so tooltips remain usable
while the focus highlight is moving. Hovering never launches additional processes. Window-title
changes update the cached titles through Hyprland's `windowtitlev2` event.
Columns that close disappear immediately. Changing appearance settings rebuilds the widget through
Noctalia, so transitions apply to focus and column appearance rather than interpolating settings edits.

No network access and no file writes. Hyprland only; other compositors are not supported.

Source and issues: https://github.com/83raiders/hypr-scroll-indicator

Idea from [jtams/waybar-hyprland-scroll-indicator](https://github.com/jtams/waybar-hyprland-scroll-indicator)
(a Go module for Waybar). This is an independent Luau implementation for Noctalia.

## Development checks

From the repository root:

```sh
python3 .github/scripts/check.py
noctalia plugins lint scroll-indicator
lua .github/scripts/test_widget.lua
```

The Lua test simulates host calls and a clock to check every animation style and curve, interrupted
animations, slide geometry, column identity, animation preferences, orientations, styling, and the
Hyprland query budget. It also checks segment hover state, tooltip titles and fallbacks, stacked
columns, title-change events, removal of hovered columns, cover customization, tuned curves, and
independent outer-end rounding. On a live desktop, try the four animation styles on dots and lines, including
vertical bars: check rapid focus reversals, skipped columns, and closing a focused column during a
slide. Confirm new columns fade in and disabling transitions makes updates immediate. Hover each
segment during a slide to check its native highlight and tooltip, then rename a window and confirm
the tooltip updates without changing focus.

For the additional styling settings, check highlight color/opacity/length on both focused and inactive
segments, including zero opacity and **Show hover highlight** off with tooltips and marker scaling still enabled.
Check that highlighting returns at its saved opacity when enabled again. Try a larger highlight thickness on top- and
bottom-aligned indicators. Check outer rounding on a single-column line and a continuous multi-column
line with zero segment radius. Compare each curve's tuning controls and a custom Bézier curve while
rapidly reversing focus; verify the highlight stays inside the track.

For fluid motion, select **Slide + Bouncy**. Check that the highlight stretches during travel,
compresses at the track ends, and keeps its momentum when switching focus back before it finishes.
Compare **Slide stretch** at zero and one. Hover covers should fade smoothly and animation-disabled
updates should remain immediate. Spring regression tests compare frame cadences, reversal velocity,
stretch/compression, settling, and the subprocess query budget.
