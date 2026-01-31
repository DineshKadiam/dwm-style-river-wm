// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
//

/// Context to pass Wayland info around.
const Context = @This();

initialized: bool,

// Wayland globals
wl_display: *wl.Display,
wl_registry: *wl.Registry,
wl_compositor: *wl.Compositor,

// Wayland globals that we have structs for
wm: *WindowManager,
xkb_bindings: *XkbBindings,

// WM Configuration
config: *Config,

pub fn create(
    wl_display: *wl.Display,
    wl_registry: *wl.Registry,
    wl_compositor: *wl.Compositor,
    river_window_manager_v1: *river.WindowManagerV1,
    river_xkb_bindings_v1: *river.XkbBindingsV1,
    config: *Config,
) !*Context {
    const context = try utils.allocator.create(Context);
    errdefer context.destroy();

    context.* = .{
        .initialized = false,
        .wl_display = wl_display,
        .wl_registry = wl_registry,
        .wl_compositor = wl_compositor,
        .wm = try WindowManager.create(context, river_window_manager_v1),
        .xkb_bindings = try XkbBindings.create(context, river_xkb_bindings_v1),
        .config = config,
    };

    return context;
}

pub fn destroy(context: *Context) void {
    context.xkb_bindings.destroy();
    context.wm.destroy();

    utils.allocator.destroy(context);
}

const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

const utils = @import("utils.zig");
const Config = @import("Config.zig");
const WindowManager = @import("WindowManager.zig");
const XkbBindings = @import("XkbBindings.zig");

const log = std.log.scoped(.Context);
