// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Window = @This();

context: *Context,

window_v1: *river.WindowV1,

width: i32 = 0,
height: i32 = 0,
x: i32 = 0,
y: i32 = 0,

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
        else => |ev| {
            log.debug("unhandled event: {s}", .{@tagName(ev)});
        },
    }
}

pub fn manage(window: *Window) void {
    if (window.width != window.context.wm.outputs.first().?.width or
        window.height != window.context.wm.outputs.first().?.height)
    {
        window.width = window.context.wm.outputs.first().?.width;
        window.height = window.context.wm.outputs.first().?.height;
        log.debug("setting window width={d} and height={d}", .{ window.width, window.height });
    }
    window.window_v1.proposeDimensions(window.width, window.height);
}

pub fn render(window: *Window) void {
    _ = window;
}

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Context = @import("main.zig").Context;

const log = std.log.scoped(.Window);
