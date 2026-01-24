// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Window = @This();

context: *Context,

window_v1: *river.WindowV1,
node_v1: *river.NodeV1,

width: u31 = 0,
height: u31 = 0,
x: i32 = 0,
y: i32 = 0,

fullscreen: bool = false,
maximized: bool = false,

initialized: bool = false,

/// Used to manage updates to various aspect of Window's state
/// Gets reset at the end of every Window.manage() call.
///
/// It might be a good idea to have two separate versions of this so one
/// can be used in renders, but I think it's okay for now.
pending_state: PendingState = .{},

link: wl.list.Link,

/// Used to manage updates to various aspect of Window's state
pub const PendingState = struct {
    width: ?u31 = null,
    height: ?u31 = null,
    x: ?i32 = null,
    y: ?i32 = null,

    fullscreen: ?bool = null,
    maximized: ?bool = null,
};

pub fn init(window: *Window, context: *Context, river_window_v1: *river.WindowV1) void {
    window.* = .{
        .context = context,
        .window_v1 = river_window_v1,
        .node_v1 = river_window_v1.getNode() catch @panic("failed to get node"),
        .link = undefined, // Handled by the wl.list
    };

    window.window_v1.setListener(*Window, windowListener, window);
}

fn windowListener(river_window_v1: *river.WindowV1, event: river.WindowV1.Event, window: *Window) void {
    assert(window.window_v1 == river_window_v1);
    switch (event) {
        .closed => {
            river_window_v1.destroy();
            window.node_v1.destroy();
            window.context.wm.window_count -= 1;
            {
                var it = window.context.wm.seats.iterator(.forward);
                while (it.next()) |seat| {
                    if (seat.focused == window) {
                        seat.focused = null;
                    }
                }
            }
            window.link.remove();
            utils.allocator.destroy(window);
        },
        .dimensions => |ev| {
            // The protocol requires these are strictly greather than zero.
            assert(ev.width > 0 and ev.height > 0);
            window.width = @intCast(ev.width);
            window.height = @intCast(ev.height);
        },
        .dimensions_hint => {
            // TODO: Maybe could use this for floating windows
        },
        else => |ev| {
            log.debug("unhandled event: {s}", .{@tagName(ev)});
        },
    }
}

pub fn manage(window: *Window) void {
    // Use server-side decoration (no client-drawn title bars)
    // TODO: Probably shouldn't send this for every manage(?)
    if (!window.initialized) {
        @branchHint(.unlikely);
        window.initialized = true;

        window.window_v1.useSsd();

        window.window_v1.setCapabilities(.{ .fullscreen = true, .maximize = true });
        window.window_v1.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
    }

    // Any new state since the last manage event
    defer window.pending_state = .{};
    const pending_state = window.pending_state;
    // Layout (pre-computed by WindowManager.calculatePrimaryStackLayout())
    if (pending_state.width) |new_width| {
        if (pending_state.height) |new_height| {
            window.width = new_width;
            window.height = new_height;
            window.window_v1.proposeDimensions(new_width, new_height);
        }
    }
    if (pending_state.x) |new_x| {
        window.x = new_x;
    }
    if (pending_state.y) |new_y| {
        window.y = new_y;
    }

    // Fullscreen and maximize operations
    if (pending_state.fullscreen) |fullscreen| {
        window.fullscreen = fullscreen;
        if (fullscreen) {
            const output = window.context.wm.outputs.first() orelse @panic("failed to get output");
            window.window_v1.fullscreen(output.output_v1);
            window.window_v1.informFullscreen();
        } else {
            window.window_v1.exitFullscreen();
            window.window_v1.informNotFullscreen();
        }
    }
    if (pending_state.maximized) |maximized| {
        window.maximized = maximized;
        if (maximized) {
            window.window_v1.informMaximized();
        } else {
            window.window_v1.informUnmaximized();
        }
    }
}

pub fn render(window: *Window) void {
    // Set the window position using the pre-computed layout
    window.node_v1.setPosition(window.x, window.y);

    // Set borders
    if (!window.fullscreen) {
        const border_width = window.context.config.border_width;
        if (window.isFocused()) {
            const border_color_focused = window.context.config.border_color_focused;
            window.window_v1.setBorders(.{ .top = true, .bottom = true, .left = true, .right = true }, border_width, border_color_focused.red, border_color_focused.green, border_color_focused.blue, border_color_focused.alpha);
        } else {
            const border_color_unfocused = window.context.config.border_color_unfocused;
            window.window_v1.setBorders(.{ .top = true, .bottom = true, .left = true, .right = true }, border_width, border_color_unfocused.red, border_color_unfocused.green, border_color_unfocused.blue, border_color_unfocused.alpha);
        }
    }
}

// TODO: Should probably make this better. Shouldn't be too bad since we only have one seat
// but there's no reason to do it like this
fn isFocused(window: *Window) bool {
    var it = window.context.wm.seats.iterator(.forward);
    while (it.next()) |seat| {
        if (seat.focused == window) {
            return true;
        }
    }
    return false;
}

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("Context.zig");

const log = std.log.scoped(.Window);
