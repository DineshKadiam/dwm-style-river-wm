// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const XkbBindings = @This();

pub const Command = union(enum) {
    spawn: []const []const u8,
    focus_next,
    focus_prev,
    zoom,
    // ratio_up, // TODO
    // ratio_down, // TODO
    // reload_config, // TODO
    toggle_fullscreen,
    close_window,
    // exit, // TODO: Delete?
    // Tag management
    set_output_tags: u32,
    set_window_tags: u32,
    toggle_output_tags: u32,
    toggle_window_tags: u32,
    // spawn_tagmask: u32, // TODO
    // focus_previous_tags, // TODO
    // send_to_previous_tags, // TODO
};

const XkbBinding = struct {
    xkb_binding_v1: *river.XkbBindingV1,
    command: Command,
    context: *Context,
    link: wl.list.Link,

    fn create(xkb_binding_v1: *river.XkbBindingV1, command: Command, context: *Context) !*XkbBinding {
        var xkb_binding = try utils.allocator.create(XkbBinding);
        errdefer xkb_binding.destroy();

        xkb_binding.* = .{
            .xkb_binding_v1 = xkb_binding_v1,
            .command = command,
            .context = context,
            .link = undefined, // Handled by the wl.list
        };

        xkb_binding.xkb_binding_v1.setListener(*XkbBinding, xkbBindingListener, xkb_binding);

        return xkb_binding;
    }

    fn destroy(xkb_binding: *XkbBinding) void {
        xkb_binding.xkb_binding_v1.destroy();
        utils.allocator.destroy(xkb_binding);
    }

    fn xkbBindingListener(river_xkb_binding_v1: *river.XkbBindingV1, event: river.XkbBindingV1.Event, xkb_binding: *XkbBinding) void {
        assert(xkb_binding.xkb_binding_v1 == river_xkb_binding_v1);
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
            },
            .zoom => {
                const wm = context.wm;
                const seat = wm.seats.first() orelse return;
                const current_focus = if (seat.pending_manage.pending_focus) |pending_focus| blk: {
                    switch (pending_focus) {
                        .clear_focus => return,
                        .window => |window| break :blk window,
                    }
                } else seat.focused orelse return;
                const first_window: *Window = if (wm.windows.first()) |first| blk: {
                    if (current_focus == first) {
                        // Try get the second window instead
                        break :blk @fieldParentPtr("link", first.link.next orelse return);
                    } else {
                        seat.pending_manage.should_warp_pointer = true;
                        break :blk first;
                    }
                } else {
                    // If current_focus is not null, we know that first_window *must not* be null.
                    unreachable;
                };
                current_focus.link.swapWith(&first_window.link);
            },
            .toggle_fullscreen => {
                const seat = context.wm.seats.first() orelse return;
                const window = seat.focused orelse return;
                window.pending_manage.fullscreen = !window.fullscreen;
                // context.wm.window_manager_v1.manageDirty();
            },
            .close_window => {
                const seat = context.wm.seats.first() orelse return;
                if (seat.focused) |window| {
                    window.river_window_v1.close();
                }
            },
            .set_output_tags => |tags| {
                // TODO: Support multiple outputs
                const output = context.wm.outputs.first() orelse return;
                output.pending_manage.tags = tags;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .set_window_tags => |tags| {
                const seat = context.wm.seats.first() orelse return;
                // TODO: I don't think pending_focus should ever be set at this point?
                // const window = seat.pending_manage.pending_focus orelse seat.focused;
                const window = seat.focused orelse return;
                window.pending_manage.tags = tags;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .toggle_output_tags => |tags| {
                const output = context.wm.outputs.first() orelse return;
                const old_tags = output.pending_manage.tags orelse output.tags;
                const new_tags = old_tags ^ tags;
                if (new_tags != 0) {
                    output.pending_manage.tags = new_tags;
                    context.wm.river_window_manager_v1.manageDirty();
                }
            },
            .toggle_window_tags => |tags| {
                const seat = context.wm.seats.first() orelse return;
                // TODO: I don't think pending_focus should ever be set at this point?
                // const window = seat.pending_manage.pending_focus orelse seat.focused;
                const window = seat.focused orelse return;
                const old_tags = window.pending_manage.tags orelse window.tags;
                const new_tags = old_tags ^ tags;
                if (new_tags != 0) {
                    window.pending_manage.tags = new_tags;
                    context.wm.river_window_manager_v1.manageDirty();
                }
            },
            // .spawn_tagmask, .focus_previous_tags, .send_to_previous_tags => {
            //     @panic("Unimplemented");
            // },
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
    var it = xkb_bindings.bindings.safeIterator(.forward);
    while (it.next()) |binding| {
        binding.link.remove();
        binding.xkb_binding_v1.destroy();
        utils.allocator.destroy(binding);
    }
    utils.allocator.destroy(xkb_bindings);
}

pub fn addBinding(xkb_bindings: *XkbBindings, river_seat_v1: *river.SeatV1, keysym: xkbcommon.Keysym, modifiers: river.SeatV1.Modifiers, command: Command) void {
    const xkb_binding_v1 = xkb_bindings.xkb_bindings_v1.getXkbBinding(river_seat_v1, @intFromEnum(keysym), modifiers) catch |err| {
        log.err("Failed to get river xkb binding: {}", .{err});
        return;
    };

    const xkb_binding = XkbBinding.create(xkb_binding_v1, command, xkb_bindings.context) catch @panic("Out of memory");
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
const Window = @import("Window.zig");

const log = std.log.scoped(.XkbBindings);
