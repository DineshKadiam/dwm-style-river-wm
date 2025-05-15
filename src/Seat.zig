// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Seat = @This();

context: *Context,

seat_v1: *river.SeatV1,

link: wl.list.Link,

pub fn init(seat: *Seat, context: *Context, river_seat_v1: *river.SeatV1) void {
    seat.* = .{
        .context = context,
        .seat_v1 = river_seat_v1,
        .link = undefined, // Handled by the wl.list
    };

    seat.seat_v1.setListener(*Seat, seatListener, seat);
}

fn seatListener(river_seat_v1: *river.SeatV1, event: river.SeatV1.Event, seat: *Seat) void {
    assert(seat.seat_v1 == river_seat_v1);
    switch (event) {
        .wl_seat => |ev| {
            log.debug("initializing new river_ouput_v1 corresponding to wl_seat: {d}", .{ev.name});
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

const log = std.log.scoped(.Seat);
