# Configuration

Beansprout is configured with a [KDL](https://kdl.dev) file located at:

```
$XDG_CONFIG_HOME/beansprout/config.kdl
```

If `$XDG_CONFIG_HOME` is not set, this defaults to `~/.config/beansprout/config.kdl`.

An example config can be found at [examples/config.kdl](../examples/config.kdl).

If the config file is missing, beansprout falls back to its built-in defaults (which
is missing keybinds!). Similarly, if an individual node or block is invalid, it will
try to ignore the error and continue on.

All configuration is applied top down, so later options will overwrite earlier ones.

## General Settings

```kdl
// Whether new windows should go to the top or bottom of the window stack
attach_mode "top"

// Number of windows in the primary stack
primary_count 1

// Proportion of output width taken by the primary stack
primary_ratio 0.55

// Whether mousing over a new window should move focus
focus_follows_pointer #true

// Whether the focus should warp to the center of newly-focused windows
pointer_warp_on_focus_change #true

// Path to image to use as wallpaper
// The same image is displayed on all outputs, but scaled separately
// If this config is missing, then the background is blank black screen
wallpaper_image_path "~/Pictures/wallpaper.png"
```

| Setting                      | Type   | Default | Description                                         |
|------------------------------|--------|---------|-----------------------------------------------------|
| `attach_mode`                | enum   | `top`   | Where new windows go in the stack (`top` or `bottom`) |
| `primary_count`              | u8     | `1`     | Number of windows in the primary stack (0+)         |
| `primary_ratio`              | float  | `0.55`  | Proportion of output width for the primary stack (0.10-0.90) |
| `focus_follows_pointer`      | bool   | `#true` | Focus follows the pointer between windows           |
| `pointer_warp_on_focus_change` | bool | `#true` | Warp pointer to center of newly-focused windows     |
| `wallpaper_image_path`       | string | none    | Path to wallpaper image                             |

Boolean values can be written as `#true`/`#false` or `true`/`false`.

## Borders

Border settings are placed inside a `borders` block:

```kdl
borders {
    width 2
    color_focused "0x89b4fa"
    color_unfocused "0x1e1e2e"
}
```

| Setting           | Type   | Default      | Description                        |
|-------------------|--------|--------------|------------------------------------|
| `width`           | u8     | `2`          | Border width in pixels             |
| `color_focused`   | color  | `0x89b4fa`   | Border color of the focused window |
| `color_unfocused` | color  | `0x1e1e2e`   | Border color of unfocused windows  |

Colors are specified in `0xRRGGBB` or `0xRRGGBBAA` hex format.

## Window Rules

Window rules let you set certain properties on windows when they first appear,
based on their `app_id` and/or `title`. Crucially, you can override them any time after
that, it's only when the window is first created. Rules are placed inside a `window_rules` block:

```kdl
window_rules {
    // Float Firefox picture-in-picture windows
    float app_id="firefox" title="Picture-in-Picture"
    // Float any window with "Preferences" in the title
    float title="*Preferences*"
    // Keep mpv windows tiled
    no_float app_id="mpv"
    // Send Slack to tag 3 (1<<2 = 0x0004)
    tags 0x0004 app_id="Slack"
}
```

### Rule Types

| Rule       | Argument         | Description                              |
|------------|------------------|------------------------------------------|
| `float`    |                  | Make matching windows float              |
| `no_float` |                  | Keep matching windows tiled              |
| `tags`     | u32 (bitmask)    | Assign matching windows to specific tags |

### Matching

Each rule can have an `app_id=` and/or `title=` property. Both support glob patterns:

| Pattern       | Matches                        |
|---------------|--------------------------------|
| `"foo"`       | Exact match only               |
| `"foo*"`      | Starts with "foo"              |
| `"*foo"`      | Ends with "foo"                |
| `"*foo*"`     | Contains "foo"                 |
| `"*"`         | Everything                     |

A rule with no `app_id=` or `title=` property matches all windows. If both are
specified, both must match.

### Evaluation

Rules are evaluated top-to-bottom. Each matching rule applies only the properties it
specifies, so multiple rules can contribute different properties to the same window.
For the same property, later rules override earlier ones.

Rules are applied once during window initialization. Title changes after initialization
do not re-trigger rules.

## Bar

The bar is an optional widget that shows the time on your screen. Right now, that's it.
It is only created when a `bar` block is present in the config. All settings have
defaults, with the color based on the Catppuccin Mocha theme. An empty block can be used
to enable the widget with all defaults:

```kdl
bar {
}
```

### Bar Settings

| Setting            | Type   | Default            | Description                       |
|--------------------|--------|--------------------|-----------------------------------|
| `fonts`            | string | `monospace:size=14` | Comma-separated FontConfig fonts |
| `text_color`       | color  | `0xcdd6f4`         | Text color                        |
| `background_color` | color  | `0x1e1e2e`         | Background color                  |
| `position`         | enum   | `top`              | Bar position (`top` or `bottom`)  |

### Margins

The `margins` child block sets pixel offsets from the anchored edge(s).

| Setting  | Type | Default |
|----------|------|---------|
| `top`    | i32  | `0`     |
| `right`  | i32  | `0`     |
| `bottom` | i32  | `0`     |
| `left`   | i32  | `0`     |

## Tag Overlay

The tag overlay is an optional widget that briefly shows your tag state when switching tags.
It is only created when a `tag_overlay` block is present in the config. All settings have
defaults, with the color based on the Catppuccin Mocha theme. An empty block can be used
to enable the widget with all defaults:

```kdl
tag_overlay {
}
```

### Tag Overlay Settings

| Setting                             | Type  | Default      | Description                               |
|-------------------------------------|-------|--------------|-------------------------------------------|
| `border_width`                      | u8    | `2`          | Widget border width in pixels             |
| `tag_amount`                        | u8    | `9`          | Number of displayed tags (1-32)           |
| `tags_per_row`                      | u8    | `32`         | Tags per row (1-32)                       |
| `square_size`                       | u8    | `40`         | Size of tag squares in pixels             |
| `square_inner_padding`              | u8    | `10`         | Padding around occupied indicator         |
| `square_padding`                    | u8    | `15`         | Padding around tag squares                |
| `square_border_width`               | u8    | `1`          | Border width of tag squares               |
| `timeout`                           | u32   | `500`        | Display duration in milliseconds          |
| `background_color`                  | color | `0x1e1e2e`   | Widget background color                   |
| `border_color`                      | color | `0x6c7086`   | Widget border color                       |
| `square_active_background_color`    | color | `0x89b4fa`   | Active tag square background              |
| `square_active_border_color`        | color | `0x6c7086`   | Active tag square border                  |
| `square_active_occupied_color`      | color | `0xcdd6f4`   | Active tag occupied indicator             |
| `square_inactive_background_color`  | color | `0x585b70`   | Inactive tag square background            |
| `square_inactive_border_color`      | color | `0x6c7086`   | Inactive tag square border                |
| `square_inactive_occupied_color`    | color | `0xcdd6f4`   | Inactive tag occupied indicator           |

### Anchors

The `anchors` child block controls which edge(s) of the screen the overlay
attaches to. Each direction is a boolean (`#true` / `#false`). Default: none, i.e. centered on output.

| Setting  | Type | Default  |
|----------|------|----------|
| `top`    | bool | `#false` |
| `right`  | bool | `#false` |
| `bottom` | bool | `#false` |
| `left`   | bool | `#false` |

### Margins

The `margins` child block sets pixel offsets from the anchored edge(s).

| Setting  | Type | Default |
|----------|------|---------|
| `top`    | i32  | `0`     |
| `right`  | i32  | `0`     |
| `bottom` | i32  | `0`     |
| `left`   | i32  | `0`     |

## Keybinds

Keyboard bindings are placed inside a `keybinds` block. Each binding has the
form:

```
command modifiers keysym [arguments...]
```

### Modifiers

Modifiers are combined with `+`. They are case-insensitive.

| Modifier         | Description        |
|------------------|--------------------|
| `None`           | No modifier, e.g. for media keys        |
| `Mod4` or `Super` | Super/Windows key |
| `Shift`          | Shift key          |
| `Ctrl`           | Control key        |
| `Mod1` or `Alt`  | Alt key            |
| `Mod3`           | Mod3 key           |
| `Mod5`           | Mod5 key           |

Example: `Mod4+Shift`, `Ctrl+Alt`, `None`

### Keysyms

Keysym names follow the XKB naming convention (case-insensitive). Most keys
are simply the character that is typed, e.g. `T`, or `f`, while others have
names such as `Return` for the "enter" or "return" key, `Space`, or
`XF86AudioRaiseVolume`.

A full list of the key names can typically be found at
`/usr/include/xkbcommon/xkbcommon-keysyms.h`.

### Commands

```kdl
keybinds {
    // Launch a program. The third argument is the command to run.
    spawn Mod4 T "foot"

    // Focus the next/previous window in the stack
    focus_next_window Mod4 J
    focus_prev_window Mod4 K

}
```

Full command reference:

| Command                  | Arguments        | Description                                       |
|--------------------------|------------------|---------------------------------------------------|
| `spawn`                  | command (string) | Launch a program                                  |
| `focus_next_window`      |                  | Focus next window in stack                        |
| `focus_prev_window`      |                  | Focus previous window in stack                    |
| `focus_next_output`      |                  | Focus next output                                 |
| `focus_prev_output`      |                  | Focus previous output                             |
| `send_to_next_output`    |                  | Send focused window to next output                |
| `send_to_prev_output`    |                  | Send focused window to previous output            |
| `zoom`                   |                  | Swap focused window with the primary window       |
| `swap_next`              |                  | Swap focused window with the next in stack        |
| `swap_prev`              |                  | Swap focused window with the previous in stack    |
| `toggle_float`           |                  | Float/unfloat the focused window                  |
| `toggle_fullscreen`      |                  | Toggle fullscreen on focused window               |
| `close_window`           |                  | Close the focused window                          |
| `change_ratio`           | float            | Adjust primary/stack ratio on current output      |
| `increment_primary_count`|                  | Add a window to the primary side                  |
| `decrement_primary_count`|                  | Remove a window from the primary side             |
| `move_up`                | pixels           | Move floating window up                           |
| `move_down`              | pixels           | Move floating window down                         |
| `move_left`              | pixels           | Move floating window left                         |
| `move_right`             | pixels           | Move floating window right                        |
| `resize_width`           | pixels           | Resize floating window width (negative to shrink) |
| `resize_height`          | pixels           | Resize floating window height (negative to shrink)|
| `center_float`           |                  | Center the focused floating window on its output  |
| `set_output_tags`        | tags (u32 bitmask) | Set the tags on the focused output              |
| `set_window_tags`        | tags (u32 bitmask) | Set the tags on the focused window              |
| `toggle_output_tags`     | tags (u32 bitmask) | Toggle a tag on the focused output              |
| `toggle_window_tags`     | tags (u32 bitmask) | Toggle a tag on the focused window              |
| `reload_config`          |                  | Reload the config file                            |

### Tag Binds

Tags use a 32-bit bitfield. Instead of binding each tag key individually,
you can also use the special `tag_bind` command to automatically generates
bindings for keys `1` through `9`, mapped to tags `1<<0` through `1<<8`:

```kdl
keybinds {
    // Mod4+1 switches to tag 1, Mod4+2 to tag 2, etc.
    tag_bind Mod4 set_output_tags
    // Mod4+Shift+1 moves the focused window to tag 1, etc.
    tag_bind Mod4+Shift set_window_tags
    // Mod4+Ctrl+1 toggles tag 1 visibility, etc.
    tag_bind Mod4+Ctrl toggle_output_tags
    // Mod4+Ctrl+Shift+1 toggles tag 1 on the focused window, etc.
    tag_bind Mod4+Ctrl+Shift toggle_window_tags
}
```

As mentioned in the table above, you can also bind specific tag values directly
using the regular keybind syntax with the `set_output_tags`, `set_window_tags`,
`toggle_output_tags`, and `toggle_window_tags` commands. The argument is a
32-bit integer representing the tag bitfield, e.g. `0x0001` is tag `1`, `0x0003`
is tags 1 and 2. Any format supported by Zig's `parseInt()` is accepted. This
can be useful if you don't want to use keys 1-9 for your binds or if you want
more than 10 tags in use, for example, for a "scratchpad".

## Pointer Binds

Mouse button bindings are placed inside a `pointer_binds` block:

```kdl
pointer_binds {
    // Mod4 + left click to move floating windows
    move_window Mod4 BTN_LEFT
    // Mod4 + right click to resize floating windows
    resize_window Mod4 BTN_RIGHT
}
```

| Action          | Description                      |
|-----------------|----------------------------------|
| `move_window`   | Drag to move the window          |
| `resize_window` | Drag to resize the window        |

Button names: `BTN_LEFT` / `button1`, `BTN_RIGHT` / `button3`,
`BTN_MIDDLE` / `button2`. Numeric button codes (decimal or hex) are also
accepted. Button names are case-insensitive.

To find button codes, you can usually look in `/usr/include/linux/input-event-codes.h`.

## Input Device Configuration

Input device settings are placed inside `input` blocks. A block without a
`name=` property applies to all devices. A block with `name=` applies only to
the matching device:

```kdl
// Default settings for all devices
input {
    accel_profile "flat"
}

// Settings for a specific device (overrides the defaults)
input name="PIXA3854:00 093A:0274 Touchpad" {
    accel_profile "adaptive"
    click_method "clickfinger"
    natural_scroll "enabled"
    tap "disabled"
}
```

### Input Settings

All libinput configuration options supported by river should also be supported by beansprout.

| Setting                | Type   | Values                                               |
|------------------------|--------|------------------------------------------------------|
| `accel_profile`        | enum   | `none`, `flat`, `adaptive`, `custom`                 |
| `accel_speed`          | float  |                                                      |
| `click_method`         | enum   | `none`, `button_areas`, `clickfinger`                |
| `clickfinger_button_map` | enum | `lrm`, `lmr`                                         |
| `drag`                 | enum   | `disabled`, `enabled`                                |
| `drag_lock`            | enum   | `disabled`, `enabled_timeout`, `enabled_sticky`      |
| `dwt`                  | enum   | `disabled`, `enabled`                                |
| `dwtp`                 | enum   | `disabled`, `enabled`                                |
| `left_handed`          | enum   | `disabled`, `enabled`                                |
| `middle_emulation`     | enum   | `disabled`, `enabled`                                |
| `natural_scroll`       | enum   | `disabled`, `enabled`                                |
| `rotation`             | u32    | Rotation angle in degrees                            |
| `scroll_button`        | button | Button name or code (see Pointer Binds)              |
| `scroll_button_lock`   | enum   | `disabled`, `enabled`                                |
| `scroll_method`        | enum   | `no_scroll`, `two_finger`, `edge`, `on_button_down`  |
| `send_events`          | enum   | `enabled`, `disabled`, `disabled_on_external_mouse`  |
| `tap`                  | enum   | `disabled`, `enabled`                                |
| `tap_button_map`       | enum   | `lrm`, `lmr`                                         |
| `three_finger_drag`    | enum   | `disabled`, `enabled_3fg`, `enabled_4fg`             |

**dwt** = disable while typing. **dwtp** = disable while trackpointing.

## Per-Host Configuration

Any node can also have a `host=` property to restrict it to a specific
hostname. This is useful for sharing a config file across machines:

```kdl
// Per-host wallpaper
wallpaper_image_path "~/Pictures/desktop.png" host="desktop"
wallpaper_image_path "~/Pictures/laptop.png" host="laptop"

// Per-host border width inside a borders block
borders {
    width 4 host="desktop"
    width 2 host="laptop"
}

// Per-host keybind
keybinds {
    spawn Mod4 T "foot" host="laptop"
    spawn Mod4 T "alacritty" host="desktop"
}
```

Nodes without a `host=` property apply to all hosts.
