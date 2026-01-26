// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const XkbBindings = @This();

pub const Command = union(enum) {
    spawn: []const []const u8,
    focus_next,
    focus_prev,
    fullscreen,
    close_window,
    exit,
};

const XkbBinding = struct {
    xkb_binding_v1: *river.XkbBindingV1,
    command: Command,
    context: *Context,
    link: wl.list.Link,

    fn init(xkb_binding: *XkbBinding, xkb_binding_v1: *river.XkbBindingV1, command: Command, context: *Context) void {
        xkb_binding.* = .{
            .xkb_binding_v1 = xkb_binding_v1,
            .command = command,
            .context = context,
            .link = undefined, // Handled by the wl.list
        };

        xkb_binding.xkb_binding_v1.setListener(*XkbBinding, xkbBindingListener, xkb_binding);
    }

    fn xkbBindingListener(xkb_binding_v1: *river.XkbBindingV1, event: river.XkbBindingV1.Event, xkb_binding: *XkbBinding) void {
        assert(xkb_binding.xkb_binding_v1 == xkb_binding_v1);
        switch (event) {
            .pressed => {
                xkb_binding.executeCommand();
            },
            .released => {},
            else => |ev| {
                log.debug("unhandled event: {s}", .{@tagName(ev)});
            },
        }
    }

    fn executeCommand(xkb_binding: *XkbBinding) void {
        const context = xkb_binding.context;
        switch (xkb_binding.command) {
            .spawn => |cmd| {
                var child = std.process.Child.init(cmd, std.heap.c_allocator);
                _ = child.spawn() catch |err| {
                    log.err("Failed to spawn \"{s}\": {}", .{ cmd[0], err });
                };
            },
            .focus_next => {
                const seat = context.wm.seats.first() orelse return;
                const pending_focus = if (seat.focused) |current|
                    context.wm.getNextWindow(current)
                else
                    // No window focused, focus the first one
                    context.wm.windows.first();

                if (pending_focus) |window| {
                    seat.pending_manage.pending_focus = .{ .window = window };
                    seat.pending_manage.should_warp_pointer = true;
                } else {
                    seat.pending_manage.pending_focus = .clear_focus;
                }
                // context.wm.window_manager_v1.manageDirty();
            },
            .focus_prev => {
                const seat = context.wm.seats.first() orelse return;
                const pending_focus = if (seat.focused) |current|
                    context.wm.getPrevWindow(current)
                else
                    // No window focused, focus the last one
                    context.wm.windows.last();

                if (pending_focus) |window| {
                    seat.pending_manage.pending_focus = .{ .window = window };
                    seat.pending_manage.should_warp_pointer = true;
                } else {
                    seat.pending_manage.pending_focus = .clear_focus;
                }
                // context.wm.window_manager_v1.manageDirty();
            },
            .fullscreen => {
                const seat = context.wm.seats.first() orelse return;
                const window = seat.focused orelse return;
                window.pending_manage.fullscreen = !window.fullscreen;
                // context.wm.window_manager_v1.manageDirty();
            },
            .close_window => {
                const seat = context.wm.seats.first() orelse return;
                if (seat.focused) |window| {
                    window.window_v1.close();
                }
            },
            .exit => {
                // TODO: Disabled while I'm working with river within river :P
                // _ = std.process.Child.init(&.{"killall river"}, std.heap.c_allocator);
            },
        }
    }
};

context: *Context,

xkb_bindings_v1: *river.XkbBindingsV1,

bindings: wl.list.Head(XkbBinding, .link),

pub fn create(context: *Context, xkb_bindings_v1: *river.XkbBindingsV1) !*XkbBindings {
    const xkb_bindings = try utils.allocator.create(XkbBindings);
    errdefer xkb_bindings.destroy();

    xkb_bindings.* = .{
        .context = context,
        .xkb_bindings_v1 = xkb_bindings_v1,
        .bindings = undefined, // we will initialize this shortly
    };

    xkb_bindings.bindings.init();

    return xkb_bindings;
}

pub fn destroy(xkb_bindings: *XkbBindings) void {
    var it = xkb_bindings.bindings.iterator(.forward);
    while (it.next()) |binding| {
        binding.link.remove();
        binding.xkb_binding_v1.destroy();
        utils.allocator.destroy(binding);
    }
    utils.allocator.destroy(xkb_bindings);
}

pub fn addBinding(xkb_bindings: *XkbBindings, river_seat_v1: *river.SeatV1, keysym: u32, modifiers: river.SeatV1.Modifiers, command: Command) void {
    const xkb_binding_v1 = xkb_bindings.xkb_bindings_v1.getXkbBinding(river_seat_v1, keysym, modifiers) catch |err| {
        log.err("Failed to get river xkb binding: {}", .{err});
        return;
    };

    const xkb_binding = utils.allocator.create(XkbBinding) catch @panic("Out of memory");
    xkb_binding.init(xkb_binding_v1, command, xkb_bindings.context);
    xkb_bindings.bindings.append(xkb_binding);

    xkb_binding_v1.enable();
}

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const xkbcommon = @import("xkbcommon");

const utils = @import("utils.zig");
const Context = @import("Context.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.XkbBindings);
