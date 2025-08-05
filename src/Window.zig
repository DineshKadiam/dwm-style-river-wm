// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Window = @This();

context: *Context,

window_v1: *river.WindowV1,

width: u31 = 0,
height: u31 = 0,
x: i32 = 0,
y: i32 = 0,

new_width: u31 = 0,
new_height: u31 = 0,
new_x: i32 = 0,
new_y: i32 = 0,

link: wl.list.Link,

pub fn init(window: *Window, context: *Context, river_window_v1: *river.WindowV1) void {
    window.* = .{
        .context = context,
        .window_v1 = river_window_v1,
        .link = undefined, // Handled by the wl.list
    };

    window.window_v1.setListener(*Window, windowListener, window);
}

fn windowListener(river_window_v1: *river.WindowV1, event: river.WindowV1.Event, window: *Window) void {
    assert(window.window_v1 == river_window_v1);
    switch (event) {
        .closed => {
            river_window_v1.destroy();
            {
                var it = window.context.wm.seats.iterator(.forward);
                while (it.next()) |seat| {
                    if (seat.hovered == window) {
                        seat.hovered = null;
                    }
                }
            }
            window.link.remove();
            window.context.allocator.destroy(window);
        },
        .dimensions => |ev| {
            // Part of the protocol requires these are strictly greater-than zero
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
    if (window.context.wm.outputs.length() == 0) {
        window.new_width = 0;
        window.new_height = 0;
        window.new_x = 0;
        window.new_y = 0;
    }

    // TODO: Remove this -- just fullscreen for now
    if (window.width != window.context.wm.outputs.first().?.width or
        window.height != window.context.wm.outputs.first().?.height)
    {
        window.width = @intCast(window.context.wm.outputs.first().?.width);
        window.height = @intCast(window.context.wm.outputs.first().?.height);
        log.debug("setting window width={d} and height={d}", .{ window.width, window.height });
    }
    window.window_v1.proposeDimensions(window.width, window.height);
    // window.window_v1.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
    window.window_v1.informFullscreen();
    // window.window_v1.informMaximized();
}

pub fn render(window: *Window) void {
    _ = window; // TODO ???
}

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Context = @import("main.zig").Context;

const log = std.log.scoped(.Window);
