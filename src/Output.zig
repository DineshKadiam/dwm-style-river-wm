// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Output = @This();

context: *Context,

output_v1: *river.OutputV1,

width: i32 = 0,
height: i32 = 0,
x: i32 = 0,
y: i32 = 0,

link: wl.list.Link,

pub fn init(output: *Output, context: *Context, river_output_v1: *river.OutputV1) void {
    output.* = .{
        .context = context,
        .output_v1 = river_output_v1,
        .link = undefined, // Handled by the wl.list
    };

    output.output_v1.setListener(*Output, outputListener, output);
}

fn outputListener(river_output_v1: *river.OutputV1, event: river.OutputV1.Event, output: *Output) void {
    assert(output.output_v1 == river_output_v1);
    switch (event) {
        .wl_output => |ev| {
            log.debug("initializing new river_ouput_v1 corresponding to wl_output: {d}", .{ev.name});
        },
        .dimensions => |ev| {
            output.width = ev.width;
            output.height = ev.height;
        },
        .position => |ev| {
            output.x = ev.x;
            output.y = ev.y;
        },
        else => |ev| {
            log.debug("unhandled event: {s}", .{@tagName(ev)});
        },
    }
}

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Context = @import("main.zig").Context;

const log = std.log.scoped(.Output);
