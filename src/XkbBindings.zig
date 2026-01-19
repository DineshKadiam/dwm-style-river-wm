// SPDX-FileCopyrightText: 2025-2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const XkbBindings = @This();

const XkbBinding = struct {
    xkb_binding_v1: *river.XkbBindingV1,
    link: wl.list.Link,

    fn init(xkb_binding: *XkbBinding, xkb_binding_v1: *river.XkbBindingV1) void {
        xkb_binding.* = .{
            .xkb_binding_v1 = xkb_binding_v1,
            .link = undefined, // Handled by the wl.list
        };

        xkb_binding.xkb_binding_v1.setListener(*XkbBinding, xkbBindingListener, xkb_binding);
    }

    fn xkbBindingListener(xkb_binding_v1: *river.XkbBindingV1, event: river.XkbBindingV1.Event, xkb_binding: *XkbBinding) void {
        assert(xkb_binding.xkb_binding_v1 == xkb_binding_v1);
        switch (event) {
            .pressed => {
                var child = std.process.Child.init(&.{"foot"}, std.heap.c_allocator);
                _ = child.spawn() catch |err| {
                    log.err("Failed to spawn foot: {}", .{err});
                };
            },
            .released => {},
            else => |ev| {
                log.debug("unhandled event: {s}", .{@tagName(ev)});
            },
        }
    }
};

context: *Context,

xkb_bindings_v1: *river.XkbBindingsV1,

bindings: wl.list.Head(XkbBinding, .link),

xkb_bindings_seat_v1: ?*river.XkbBindingsSeatV1 = null,

pub fn init(xkb_bindings: *XkbBindings, context: *Context, xkb_bindings_v1: *river.XkbBindingsV1) void {
    assert(xkb_bindings == &context.xkb_bindings);
    xkb_bindings.* = .{
        .context = context,
        .xkb_bindings_v1 = xkb_bindings_v1,
        .bindings = undefined, // we will initialize this shortly
    };

    xkb_bindings.bindings.init();
}

pub fn getSeat(xkb_bindings: *XkbBindings) *river.SeatV1 {
    const seat = xkb_bindings.context.wm.seats.first() orelse @panic("No seat available");
    return seat.seat_v1;
}

pub fn addBinding(xkb_bindings: *XkbBindings, keysym: u32, modifiers: river.SeatV1.Modifiers) void {
    const seat_v1 = xkb_bindings.getSeat();
    const xkb_binding_v1 = xkb_bindings.xkb_bindings_v1.getXkbBinding(seat_v1, keysym, modifiers) catch |err| {
        log.err("Failed to get xkb binding: {}", .{err});
        return;
    };

    const xkb_binding = xkb_bindings.context.allocator.create(XkbBinding) catch @panic("out-of-memory");
    xkb_binding.init(xkb_binding_v1);
    xkb_bindings.bindings.append(xkb_binding);

    xkb_binding_v1.enable();
}

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const xkbcommon = @import("xkbcommon");

const Context = @import("main.zig").Context;
const Seat = @import("Seat.zig");

const log = std.log.scoped(.XkbBindings);
