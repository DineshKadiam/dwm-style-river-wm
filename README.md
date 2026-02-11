<!--
SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>

SPDX-License-Identifier: GPL-3.0-or-later
-->

# beansprout wm

## TODOs

These are in rough order of my priority, though no promises I do them in this order.

- [ ] Support `None` modifier for keybinds (needed for media/brightness keys)
- [ ] Support per-host config using properties (maybe also per-output?)
- [ ] Add input configuration, i.e. pointer acceleration and that type of thing
- [ ] Support a basic bar
- [ ] Support starting programs at WM launch
- [ ] Support overriding config location
- [ ] Add support for multimedia/brightness keys (this might not be neccesary)
- [ ] Support window rules (float/tags/SSD by app-id/title)
- [ ] Support switch handling (e.g. lid close)
- [ ] Support multiple seats
- [ ] Support clipping floating windows on edge of/between outputs
- [ ] Support keybind modes (e.g. passthrough)
- [ ] Support `focus-follows-cursor` granularity (`normal` vs `always`)
- [ ] Support solid `background-color` fallback (no wallpaper)
- [x] Support changeable primary ratio
- [x] Support changeable primary count
- [x] Support multiple outputs
- [x] Support floating windows
- [x] Support wallpapers
- [x] Make "orelse return" bits into errors; handle gracefully
- [x] Implement runtime log levels
- [ ] Switch all structs to idiomatic Zig init/deinit pattern (init returns value, caller decides stack/heap)
  - I'm not sure I really need this
