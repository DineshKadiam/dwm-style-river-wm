// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Seat = @This();

context: *Context,

seat_v1: *river.SeatV1,

focused: ?*Window,

/// State consumed in manage phase, reset at end of manage().
pending_manage: PendingManage = .{},

link: wl.list.Link,

pub const PendingManage = struct {
    pending_focus: ?PendingFocus = null,
    should_warp_pointer: bool = false,

    pub const PendingFocus = union(enum) {
        window: *Window,
        clear_focus,
    };
};

pub fn init(seat: *Seat, context: *Context, river_seat_v1: *river.SeatV1) void {
    seat.* = .{
        .context = context,
        .seat_v1 = river_seat_v1,
        .focused = null,
        .link = undefined, // Handled by the wl.list
    };

    seat.seat_v1.setListener(*Seat, seatListener, seat);
}

fn seatListener(river_seat_v1: *river.SeatV1, event: river.SeatV1.Event, seat: *Seat) void {
    assert(seat.seat_v1 == river_seat_v1);
    switch (event) {
        .removed => {
            river_seat_v1.destroy();
            utils.allocator.destroy(seat);
        },
        .wl_seat => {
            // log.debug("initializing new river_seat_v1 corresponding to wl_seat: {d}", .{ev.name});
        },
        .pointer_enter => |ev| {
            const window_v1 = ev.window orelse return;
            const window: *Window = @ptrCast(@alignCast(window_v1.getUserData()));
            seat.pending_manage.pending_focus = .{ .window = window };
        },
        .window_interaction => |ev| {
            const window_v1 = ev.window orelse return;
            const window: *Window = @ptrCast(@alignCast(window_v1.getUserData()));
            seat.pending_manage.pending_focus = .{ .window = window };
        },
        else => |ev| {
            log.debug("unhandled event: {s}", .{@tagName(ev)});
        },
    }
}

pub fn manage(seat: *Seat) void {
    defer seat.pending_manage = .{};

    if (seat.pending_manage.pending_focus) |pending_focus| {
        switch (pending_focus) {
            .window => |window| {
                if (seat.focused) |focused| {
                    // Tell the previously focused Window that it's no longer focused
                    if (focused != window) {
                        focused.pending_render.focused = false;
                    }
                }
                seat.focused = window;
                seat.seat_v1.focusWindow(window.window_v1);
                window.pending_render.focused = true;
            },
            .clear_focus => {
                if (seat.focused) |focused| {
                    // Tell the previously focused Window that it's no longer focused
                    focused.pending_render.focused = false;
                }
                seat.focused = null;
                seat.seat_v1.clearFocus();
            },
        }
    }

    if (seat.pending_manage.should_warp_pointer) {
        const window = seat.focused orelse {
            log.err("Trying to warp pointer without focused window.", .{});
            return;
        };
        // TODO - CONFIG: Allow disabling this behaviour
        // Warp pointer to center of focused window;
        // because the x and y coords are set later, we need to check them here.
        const pointer_x: i32 = (window.pending_render.x orelse window.x) + @divTrunc(window.width, 2);
        const pointer_y: i32 = (window.pending_render.y orelse window.y) + @divTrunc(window.height, 2);
        seat.seat_v1.pointerWarp(pointer_x, pointer_y);
        log.debug("warped pointer to {}, {}", .{ pointer_x, pointer_y });
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

const utils = @import("utils.zig");
const Context = @import("Context.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.Seat);
