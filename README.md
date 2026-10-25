# Display Arrange

An Omarchy (Quattro) shell plugin for arranging monitors. It works like the
macOS / GNOME *Displays* screen, inside your bar.

- **Drag** displays on a canvas. They snap flush to a neighbour's edge
  (start / centre / end alignment), and overlaps are impossible.
- Per display: **on/off**, **brightness** (laptop backlight or DDC/CI on
  externals, applied live), **resolution & refresh**, **scale** (only
  Hyprland-valid "clean" scales), **rotation**.
- **Text size** (global): shell, GTK and terminal text together, via
  `omarchy-display-text-size`. It is global because Hyprland/GTK have no
  per-monitor font size; use per-display *scale* for that.
- Scroll on the bar icon to change the focused display's brightness (with OSD).
- Replaces the stock `omarchy.monitor` Display widget (see below).
- **Apply** writes a managed block to `~/.config/hypr/monitors.lua` and
  reloads Hyprland. A **15 s Keep / Revert** countdown follows; if you don't
  confirm, the previous config is restored automatically.
- If Hyprland reports config errors after a reload, the old file is restored
  immediately.

## Why it writes `monitors.lua` (and not just `hyprctl eval`)

Omarchy's `omarchy-hyprland-monitor-watch` re-applies the internal panel's
scale/position from `monitors.lua` every couple of seconds while an external
display is connected. Live-only changes get undone, so this plugin persists
them. Everything it writes sits between these markers:

```lua
-- >>> display-arrange (managed by ...) >>>
hl.monitor({ output = "eDP-1", mode = "3840x2400@60.00", position = "0x0", scale = 2, transform = 0 })
hl.monitor({ output = "desc:JHW Z34B 0000000000001", mode = "3440x1440@75.00", position = "1920x0", scale = 1, transform = 0 })
-- <<< display-arrange <<<
```

The rest of the file is left untouched. The block goes at the end, so it
overrides Omarchy's catch-all `output = ""` rule. External displays are keyed
by EDID description (`desc:`), so the layout follows the screen across ports
and docks. The internal panel is keyed by connector, because Omarchy's
clamshell logic looks it up by name.

## Install

```sh
omarchy plugin add https://github.com/avb7/omarchy-display-arrange.git --enable
# or from a local checkout:
omarchy plugin add ~/plugins/display-arrange --enable --yes
```

## Replacing the stock Display widget

The stock widget is taken off the bar (still installed). `SUPER+CTRL+D` is
rebound in `~/.config/hypr/bindings.lua` to open this panel. Undo with:

```sh
omarchy bar put omarchy.monitor --after omarchy.audio
```

## Usage

Click the 󰍺 bar icon. Alternatively:

```sh
omarchy-shell shell toggle avb7.display-arrange '{}'
```

Keys: `Tab` selects the next display. The arrow keys / `hjkl` dock the
selected display to that side of the others. `Enter` applies (or keeps during
the countdown). `Esc` closes.

## CLI helper

`bin/display-arrange` is the only part that touches the system:

```sh
bin/display-arrange state            # hyprctl monitors all -j
bin/display-arrange print '<json>'   # preview the Lua block
bin/display-arrange apply '<json>'   # write + reload (auto-restores on config errors)
bin/display-arrange revert           # restore monitors.lua from before the last apply
bin/display-arrange clear            # remove the managed block
```

Backups: `~/.local/state/display-arrange/` (last 10 versions).

Security: every value that reaches Lua is validated. Outputs must match
`^[A-Za-z0-9._-]+$` or `desc:<printable>` and are then escaped, and numbers
are type-checked. A malicious EDID string therefore cannot inject code into
your Hyprland config. No sudo, no network.

## Recover from a bad layout

From a TTY (`Ctrl+Alt+F3`):

```sh
~/.config/omarchy/plugins/avb7.display-arrange/bin/display-arrange clear
```

## Tests

```sh
node test/model.test.js
```

## Remove

```sh
omarchy plugin remove avb7.display-arrange
```

This leaves your last applied block in `monitors.lua`; run `display-arrange
clear` first to drop it.
