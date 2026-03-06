BEANSPROUT(1)

# NAME

beansprout - tiling window manager for river

# SYNOPSIS

*beansprout* [_options_]

# DESCRIPTION

*beansprout* is a tiling window manager for the *river*(1) Wayland compositor.
It communicates with river using the river-window-management-v1 protocol and
other River-specific Wayland protocols.

*beansprout* uses a primary/stack tiling layout inspired by dwm with a
customizable ratio and primary count. It uses a 32-bit tag system rather than
workspaces. Each output has its own tags, primary count, and ratio.

# OPTIONS

*-h*
	Print a help message and exit.

*-version*
	Print the version number and exit.

*-log-level* [*error*|*warning*|*info*|*debug*]
	Set the log level. (Default: *warning*)

# USAGE

You can either add *beansprout* to the river init file or directly run:

	river -c beansprout

If no keybinds are configured (e.g. missing or broken config), *beansprout*
provides fallback keybinds: *Ctrl+Alt+Delete* to exit the River session,
*Super+Shift+R* to reload config, and *Super+T* to spawn a terminal.

If *beansprout* crashes, you can use River's hardcoded *Ctrl+Alt F1*–*F12*
bindings to switch to another TTY. From there, you can kill River or restart
*beansprout* (you will need to set *WAYLAND_DISPLAY* yourself, e.g.
_WAYLAND_DISPLAY=wayland-1 beansprout_).

# CONFIGURATION

*beansprout* is configured with a KDL file located at
_$XDG_CONFIG_HOME/beansprout/config.kdl_. If _$XDG_CONFIG_HOME_ is not set,
this defaults to _~/.config/beansprout/config.kdl_.

See *beansprout*(5) for a full configuration reference.

If the config file is missing or fails to load, *beansprout* falls back to
built-in defaults. If an individual node or block is invalid, *beansprout*
will try to ignore the error and continue.

# AUTHORS

Maintained by Ben Buhse <me@benbuhse.email>. For more information about
beansprout's development, see <https://codeberg.org/beansprout/beansprout>.

# SEE ALSO

*beansprout*(5), *river*(1)
