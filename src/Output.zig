// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Output = @This();

context: *Context,

river_output_v1: *river.OutputV1,

width: i32 = 0,
height: i32 = 0,
x: i32 = 0,
y: i32 = 0,

/// Tags are 32-bit bitfield. A window can be active on one(?) or more tags.
tags: u32 = 0x0001,

pending_manage: PendingManage = .{},

link: wl.list.Link,

pub const PendingManage = struct {
    tags: ?u32 = null,
};

pub fn create(context: *Context, river_output_v1: *river.OutputV1) !*Output {
    var output = try utils.allocator.create(Output);
    errdefer output.destroy();

    output.* = .{
        .context = context,
        .river_output_v1 = river_output_v1,
        .link = undefined, // Handled by the wl.list
    };

    output.river_output_v1.setListener(*Output, outputListener, output);

    return output;
}

pub fn destroy(output: *Output) void {
    output.river_output_v1.destroy();
    utils.allocator.destroy(output);
}

fn outputListener(river_output_v1: *river.OutputV1, event: river.OutputV1.Event, output: *Output) void {
    assert(output.river_output_v1 == river_output_v1);
    switch (event) {
        .removed => output.destroy(),
        .wl_output => |ev| {
            log.debug("initializing new river_output_v1 corresponding to wl_output: {d}", .{ev.name});
        },
        .dimensions => |ev| {
            output.width = ev.width;
            output.height = ev.height;
        },
        .position => |ev| {
            output.x = ev.x;
            output.y = ev.y;
        },
    }
}

pub fn manage(output: *Output) void {
    defer output.pending_manage = .{};

    if (output.pending_manage.tags) |tags| {
        output.tags = tags;
    }
}

pub fn render(output: *Output) void {
    _ = output;
}

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("Context.zig");

const log = std.log.scoped(.Output);
