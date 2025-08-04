// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Seat = @This();

context: *Context,

seat_v1: *river.SeatV1,

hovered: ?*Window,

link: wl.list.Link,

pub fn init(seat: *Seat, context: *Context, river_seat_v1: *river.SeatV1) void {
    seat.* = .{
        .context = context,
        .seat_v1 = river_seat_v1,
        .hovered = null,
        .link = undefined, // Handled by the wl.list
    };

    seat.seat_v1.setListener(*Seat, seatListener, seat);
}

fn seatListener(river_seat_v1: *river.SeatV1, event: river.SeatV1.Event, seat: *Seat) void {
    assert(seat.seat_v1 == river_seat_v1);
    switch (event) {
        .removed => {
            river_seat_v1.destroy();
            seat.context.allocator.destroy(seat);
        },
        .wl_seat => {
            // log.debug("initializing new river_seat_v1 corresponding to wl_seat: {d}", .{ev.name});
        },
        .pointer_enter => |ev| {
            const window_v1 = ev.window orelse return;
            const window: *Window = @ptrCast(@alignCast(window_v1.getUserData()));
            seat.hovered = window;
        },
        else => |ev| {
            log.debug("unhandled event: {s}", .{@tagName(ev)});
        },
    }
}

pub fn manage(seat: *Seat) void {
    if (seat.hovered) |window| {
        seat.seat_v1.focusWindow(window.window_v1);
        seat.hovered = null;
    }
}

pub fn render(seat: *Seat) void {
    _ = seat;
}

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Context = @import("main.zig").Context;
const Window = @import("Window.zig");

const log = std.log.scoped(.Seat);
