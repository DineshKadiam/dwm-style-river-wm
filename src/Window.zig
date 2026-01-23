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

new_width: u31 = 0,
new_height: u31 = 0,
new_x: i32 = 0,
new_y: i32 = 0,

is_maximized: bool = false,

link: wl.list.Link,

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
            window.context.allocator.destroy(window);
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
    window.window_v1.useSsd();

    // Layout has been pre-computed by WindowManager.calculatePrimaryStackLayout()
    // Apply the computed dimensions
    if (window.new_width > 0 and window.new_height > 0) {
        window.window_v1.proposeDimensions(window.new_width, window.new_height);

        // Inform the window about its tiled/fullscreen state
        if (window.context.wm.window_count == 1) {
            // Single window is fullscreen
            window.window_v1.setTiled(.{ .top = false, .bottom = false, .left = false, .right = false });
            window.window_v1.informFullscreen();
        } else {
            // Tiled windows - set tiled edges
            window.window_v1.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
            window.window_v1.informNotFullscreen();
        }
    }
}

pub fn render(window: *Window) void {
    // Set the window position using the pre-computed layout
    window.node_v1.setPosition(window.new_x, window.new_y);

    // Set borders
    if (!window.is_maximized) {
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

const Context = @import("main.zig").Context;

const log = std.log.scoped(.Window);
