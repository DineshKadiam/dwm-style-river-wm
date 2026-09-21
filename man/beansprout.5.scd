BEANSPROUT(5)

# NAME

beansprout - configuration file

# DESCRIPTION

*beansprout*(1) is configured with a KDL file located at
_$XDG_CONFIG_HOME/beansprout/config.kdl_. If _$XDG_CONFIG_HOME_ is not set,
this defaults to _~/.config/beansprout/config.kdl_.

All configuration is applied top-down, so later options overwrite earlier ones.

Any node can have a *host=* property to restrict it to a specific hostname.
This is useful for sharing a config file across machines. Nodes without a
*host=* property apply to all hosts.

# GENERAL SETTINGS

*attach_mode* *top*|*bottom*
	Whether new windows go to the top or bottom of the window stack.
	(Default: *top*)

*primary_count* _count_
	Number of windows in the primary stack. (Default: 1)

*primary_ratio* _ratio_
	Proportion of output width taken by the primary stack. Must be between
	0.10 and 0.90. (Default: 0.55)

*primary_side* *left*|*right*
	Which side of the output the primary stack is on. (Default: *left*)

*single_window_ratio* _ratio_
	Proportion of output width taken when a single tiled window is visible.
	Must be between 0.10 and 1.00. When less than 1.0, the window is
	centered. (Default: 1.00)

*window_padding* _size_
	Extra padding added to windows during layout calculation. Equivalent to
	"inner gaps" in most other window managers (Default: 0)

*layout_margin* _size_
	Extra margin between the layout and screen edge added during layout
	calculation. Equivalent to "outer gaps" in most other window managers.
	(Default: 0)

*focus_follows_pointer* _bool_
	Whether mousing over a new window should move focus.
	(Default: *true*)

*output_focus_follows_pointer* _bool_
	Whether mousing over a new output should move output focus (i.e. the output new windows spawn on)
	(Default: *true*)

*pointer_warp_on_focus_change* _bool_
	Whether the pointer should warp to the center of newly-focused windows.
	(Default: *true*)

*focus_on_send* *if_visible*|*never*|*always*|*always_or*
	Controls output and window focus when a window is sent to another output
	with *send_to_next_output* or *send_to_prev_output*.
	(Default: *if_visible*)

	*if_visible*
		Follow the window to the destination output only if the window's tags
		are visible there. Otherwise, focus stays on the current output and
		falls back to the next visible window.

	*never*
		Focus never follows the window. Focus stays on the current output and
		falls back to the next visible window regardless of tag visibility.

	*always*
		Focus always follows the window. If the window's tags are not visible
		on the destination, its tags are OR'd onto the destination's active
		tags to make it visible.

	*always_or*
		Focus always follows the window and the window's tags are always OR'd
		onto the destination's active tags, even if the window would already
		be visible. This differs from *always* when the window has multiple
		tags and not all of them are currently shown on the destination.

*focus_next_direction* *prev*|*next*
	Controls next window focus after a currently focused window is closed or hidden.
	(Default: *next*)

*restore_focus* _bool_
	Whether focus should be restored to the last focused visible window when
	switching tags or outputs.
	(Default: *false*)

*wallpaper_image_path* _path_
	Path to image to use as wallpaper. The same image is displayed on all
	outputs, scaled separately. If not set, the background is a blank black
	screen.

*cursor_theme* _theme_ [_size_]
	XCursor theme to use. _theme_ must be the name of an installed XCursor
	theme (e.g. a directory under _/usr/share/icons/_). _size_ is the cursor
	size in pixels. (Default size: 24)

	If not set, the compositor's default cursor theme is used. Note that the
	theme cannot be reverted to the compositor default via config reload; set
	a theme explicitly if you want to control it.

	The configured theme and size are also exported as *XCURSOR_THEME* and
	*XCURSOR_SIZE* environment variables for child processes.

# BORDERS

Border settings are placed inside a *borders* block:

```
borders {
	width 2
	color_focused "0x89b4fa"
	color_unfocused "0x1e1e2e"
}
```

*width* _pixels_
	Border width in pixels. (Default: 2)

*color_focused* _color_
	Border color of the focused window in 0xRRGGBB or 0xRRGGBBAA hex
	format. (Default: 0x89b4fa)

*color_unfocused* _color_
	Border color of unfocused windows in 0xRRGGBB or 0xRRGGBBAA hex
	format. (Default: 0x1e1e2e)

# ENVIRONMENT

Environment variables that should be exported to each child process
can be set inside an *env* block:

```
env {
	set XDG_SESSION_DESKTOP "river"
	set INTERP_EXAMPLE "interpolated: ${WAYLAND_DISPLAY}"
}
```

*set* _name_ _value_
	Set the environment variable with the specified name to the 
	specified value, or create it if it does not exist.

*unset* _name_
	Remove the environment variable with the specified name.

## Interpolation

Both _name_ and _value_ strings can be interpolated with other 
environment variables by using the `${_NAME_}` syntax, but *only*
inside a quoted (`"..."`) string.

It is recommended to always enclose the value in double quotes.

To prevent interpolation or to insert a `$` char literal into a string, use `$$`.

# WINDOW RULES

Window rules let you set properties on windows when they first appear, based
on their app_id and/or title. Rules are placed inside a *window_rules* block:

```
window_rules {
	float app_id="firefox" title="Picture-in-Picture"
	float title="*Preferences*"
	no_float app_id="mpv"
	tags 0x0004 app_id="Slack"
	async app_id="steam_app_1422450"
}
```

## Rule Types

*float* [*app_id=*_pattern_] [*title=*_pattern_]
	Make matching windows float.

*no_float* [*app_id=*_pattern_] [*title=*_pattern_]
	Keep matching windows tiled.

*tags* _bitmask_ [*app_id=*_pattern_] [*title=*_pattern_]
	Assign matching windows to specific tags. The argument is a 32-bit
	integer representing the tag bitfield.

*vsync* [*app_id=*_pattern_] [*title=*_pattern_]
	Keep outputs with matching windows vsync.

*async* [*app_id=*_pattern_] [*title=*_pattern_]
	Make outputs with matching windows async (i.e. allow the output to tear).
	If *any* visible window on an output has this rule, the output will be async.

*output* _name_ [*app_id=*_pattern_] [*title=*_pattern_]
	Assign matching windows to a specific output. The argument is a string
	representing either the output's name or description.

## Matching

Each rule can have an *app_id=* and/or *title=* property. Both support glob
patterns using *\** as a wildcard. A rule with neither property matches all
windows. If both are specified, both must match.

Rules are evaluated top-to-bottom. Each matching rule applies only the
properties it specifies, so multiple rules can contribute different properties
to the same window. For the same property, later rules override earlier ones.

Rules are applied once during window initialization. Title changes after
initialization do not re-trigger rules.

# BAR

The bar is an optional widget that displays configurable components in three
slots: left, center, and right. It is only created when a *bar* block is present
in the config:

```
bar {
	position top
}
```

*fonts* _fontconfig_
	Comma-separated FontConfig font string. (Default: "monospace:size=14")

*text_color* _color_
	Text color. (Default: 0xcdd6f4)

*background_color* _color_
	Background color. (Default: 0x1e1e2e)

*position* *top*|*bottom*
	Bar position. (Default: *top*)

*left* *title*|*clock*|*wm_info*|*none*
	Component shown in the left slot. (Default: *title*)

*center* *title*|*clock*|*wm_info*|*none*
	Component shown in the center slot. (Default: *clock*)

*right* *title*|*clock*|*wm_info*|*none*
	Component shown in the right slot. (Default: *wm_info*)

*vertical_padding* _pixels_
	Vertical padding above and below text. (Default: 5)

*horizontal_padding* _pixels_
	Horizontal padding between bar edges and text. (Default: 5)

*time_format* _format_
	strftime format string for the clock display. Invalid format strings
	are ignored and the default is used instead. (Default: "%Y-%m-%d %H:%M, %A")

## Margins

The *margins* child block sets pixel offsets from the edges or to the layout
respectively. All default to 0.

	*top*, *right*, *bottom*, *left*

An empty block can be used to enable the widget with all defaults.

# TAG OVERLAY

The tag overlay is an optional widget that briefly shows tag state when
switching tags. It is only created when a *tag_overlay* block is present:

```
tag_overlay {
	tag_amount 10
}
```

*border_width* _pixels_
	Widget border width in pixels. (Default: 2)

*tag_amount* _count_
	Number of displayed tags, 1-32. (Default: 9)

*tags_per_row* _count_
	Tags per row, 1-32. (Default: 32)

*square_size* _pixels_
	Size of tag squares in pixels. (Default: 40)

*square_inner_padding* _pixels_
	Padding around occupied indicator. (Default: 10)

*square_padding* _pixels_
	Padding around tag squares. (Default: 15)

*square_border_width* _pixels_
	Border width of tag squares. (Default: 1)

*timeout* _milliseconds_
	Display duration in milliseconds. (Default: 500)

*background_color*, *border_color*, *square_active_background_color*,
*square_active_border_color*, *square_active_occupied_color*,
*square_inactive_background_color*, *square_inactive_border_color*,
*square_inactive_occupied_color*
	Color settings in 0xRRGGBB or 0xRRGGBBAA hex format. Defaults follow
	the Catppuccin Mocha theme.

# KEYBOARD LAYOUT

Keyboard layout settings are placed inside a *keyboard_layout* block. These
configure the XKB keymap applied to all keyboard devices via the
river-xkb-config protocol. All fields are optional and default to
system/xkbcommon defaults.

```
keyboard_layout {
	layout "us"
	variant "dvorak"
	options "compose:rctrl"
}
```

*rules* _rules_
	XKB rules file. Almost always "evdev". (Default: system default)

*model* _model_
	Keyboard model, e.g., "pc104", "pc105". (Default: system default)

*layout* _layout_
	Keyboard layout, e.g., "us", "de", "fr". (Default: system default)

*variant* _variant_
	Layout variant, e.g., "dvorak", "colemak", "intl".

*options* _options_
	XKB options, e.g., "compose:rctrl", "caps:escape". Multiple options
	can be separated by commas.

If the *keyboard_layout* block is removed from the config and reloaded,
beansprout will revert to the system/xkbcommon default keymap.

See *xkeyboard-config*(7) for a full list of available rules, models, layouts,
variants, and options.

# KEYBINDS

Keyboard bindings are placed inside a *keybinds* block. Each binding has the
form:

	_command_ _modifiers_ _keysym_ [_arguments..._]

Any node within a keybinds block can have an *allow_locked=<bool>* property to
mark whether it should be available while the session is locked. Nodes without
an *allow_locked=* property are disabled when the session is locked, i.e. the
default is *allow_locked=#false*.

## Modifiers

Modifiers are combined with *+*. They are case-insensitive.

- *Mod4* or *Super* - Super/Windows key
- *Shift* - Shift key
- *Ctrl* - Control key
- *Mod1* or *Alt* - Alt key
- *Mod3* - Mod3 key
- *Mod5* - Mod5 key
- *None* - No modifier (e.g., for media keys)

## Keysyms

Keysym names follow the XKB naming convention (case-insensitive). A full list
can typically be found at _/usr/include/xkbcommon/xkbcommon-keysyms.h_.

## Commands

*spawn* _modifiers_ _keysym_ _command_
	Launch a program.

*focus_next_window*, *focus_prev_window*
	Focus the next/previous window in the stack.

*focus_next_output*, *focus_prev_output*
	Focus the next/previous output.

*send_to_next_output*, *send_to_prev_output*
	Send the focused window to the next/previous output.

*zoom*
	Swap the focused window with the primary window.

*swap_next*, *swap_prev*
	Swap the focused window with the next/previous in stack.

*toggle_float*
	Float/unfloat the focused window.

*toggle_fullscreen*
	Toggle fullscreen on the focused window.

*close_window*
	Close the focused window.

*exit_river*
	Exit the river session.

*change_primary_ratio* _modifiers_ _keysym_ _float_
	Adjust the primary/stack ratio on the current output.

*change_single_window_ratio* _modifiers_ _keysym_ _float_
	Adjust the single-window ratio on the current output.

*increment_primary_count*, *decrement_primary_count*
	Add/remove a window from the primary side.

*move_up*, *move_down*, *move_left*, *move_right* _modifiers_ _keysym_ _pixels_
	Move a floating window by the given number of pixels.

*resize_width*, *resize_height* _modifiers_ _keysym_ _pixels_
	Resize a floating window (negative to shrink).

*center_float*
	Center the focused floating window on its output.

*set_output_tags* _modifiers_ _keysym_ _bitmask_
	Set the tags on the focused output.

*set_window_tags* _modifiers_ _keysym_ _bitmask_
	Set the tags on the focused window.

*toggle_output_tags* _modifiers_ _keysym_ _bitmask_
	Toggle a tag on the focused output.

*toggle_window_tags* _modifiers_ _keysym_ _bitmask_
	Toggle a tag on the focused window.

*reload_config*
	Reload the config file.

*toggle_passthrough*
	Toggle passthrough mode to disable keybinds.

## Tag Binds

The special *tag_bind* command generates bindings for keys 1-9 mapped to tags
1<<0 through 1<<8:

```
keybinds {
	tag_bind Mod4 set_output_tags
	tag_bind Mod4+Shift set_window_tags
	tag_bind Mod4+Ctrl toggle_output_tags
	tag_bind Mod4+Ctrl+Shift toggle_window_tags
}
```

# POINTER BINDS

Mouse button bindings are placed inside a *pointer_binds* block:

```
pointer_binds {
	move_window Mod4 BTN_LEFT
	resize_window Mod4 BTN_RIGHT
}
```

*move_window*
	Drag to move the window.

*resize_window*
	Drag to resize the window.

Button names: *BTN_LEFT* / *button1*, *BTN_RIGHT* / *button3*,
*BTN_MIDDLE* / *button2*. Numeric button codes are also accepted. Names are
case-insensitive.

# INPUT DEVICE CONFIGURATION

Input device settings are placed inside *input* blocks. A block without a
*name=* property applies to all devices. A block with *name=* applies only to
the matching device:

```
input {
	accel_profile "flat"
}

input name="PIXA3854:00 093A:0274 Touchpad" {
	accel_profile "adaptive"
	natural_scroll "enabled"
	tap "disabled"
}
```

All libinput configuration options supported by river are also supported by
*beansprout*. Available settings include:

- *accel_profile*
- *accel_speed*
- *click_method*
- *clickfinger_button_map*
- *drag*
- *drag_lock*
- *dwt*
- *dwtp*
- *left_handed*
- *middle_emulation*
- *natural_scroll*
- *rotation*
- *scroll_button*
- *scroll_button_lock*
- *scroll_method*
- *send_events*
- *tap*
- *tap_button_map*
- *three_finger_drag*

# SEE ALSO

*beansprout*(1), *river*(1), *strftime*(3), *xkeyboard-config*(7)
