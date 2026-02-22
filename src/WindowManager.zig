// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const WindowManager = @This();

const MIN_RIVER_SEAT_V1_VERSION: u2 = 3;

context: *Context,

river_window_manager_v1: *river.WindowManagerV1,

seats: wl.list.Head(Seat, .link),
outputs: wl.list.Head(Output, .link),

/// Place to store windows if all Outputs have been disconnected
orphan_windows: wl.list.Head(Window, .link),

pub fn create(context: *Context, window_manager_v1: *river.WindowManagerV1) !*WindowManager {
    const wm = try utils.gpa.create(WindowManager);
    errdefer utils.gpa.destroy(wm);

    wm.* = .{
        .context = context,
        .river_window_manager_v1 = window_manager_v1,
        .seats = undefined, // we will initialize these shortly
        .outputs = undefined,
        .orphan_windows = undefined,
    };

    wm.seats.init();
    wm.outputs.init();
    wm.orphan_windows.init();

    wm.river_window_manager_v1.setListener(*WindowManager, windowManagerV1Listener, wm);

    return wm;
}

pub fn destroy(wm: *WindowManager) void {
    {
        var it = wm.outputs.safeIterator(.forward);
        while (it.next()) |output| {
            output.link.remove();
            output.destroy();
        }
    }
    {
        var it = wm.seats.safeIterator(.forward);
        while (it.next()) |seat| {
            seat.link.remove();
            seat.destroy();
        }
    }
    {
        var it = wm.orphan_windows.safeIterator(.forward);
        while (it.next()) |window| {
            window.link.remove();
            window.destroy();
        }
    }

    wm.river_window_manager_v1.destroy();
    utils.gpa.destroy(wm);
}

/// Get the next output in the list, wrapping to first if at end
pub fn nextOutput(wm: *WindowManager, current: *Output) ?*Output {
    const next_link = current.link.next orelse return wm.outputs.first();
    // If we've reached the sentinel (head's link), wrap to first
    if (next_link == &wm.outputs.link) return wm.outputs.first();
    return @fieldParentPtr("link", next_link);
}

/// Get the previous output in the list, wrapping to last if at beginning
pub fn prevOutput(wm: *WindowManager, current: *Output) ?*Output {
    const prev_link = current.link.prev orelse return wm.outputs.last();
    // If we've reached the sentinel (head's link), wrap to last
    if (prev_link == &wm.outputs.link) return wm.outputs.last();
    return @fieldParentPtr("link", prev_link);
}

fn initialize(wm: *WindowManager) void {
    if (wm.context.initialized) return;

    // We need a seat to intitialize this stuff, so let's just not do it right now.
    // The WM can run fine without it, though, it won't be fully usuable.
    const seat = wm.seats.first() orelse return;
    const river_seat_v1 = seat.river_seat_v1;

    const context = wm.context;
    context.initialized = true;

    // Tag bindings
    for (context.config.tag_binds.items) |tag_bind| {
        comptime var i: u8 = 1;
        comptime var buffer: [1]u8 = undefined;
        inline while (i <= 9) : (i += 1) {
            const tags: u32 = 1 << (i - 1);
            buffer[0] = i + '0';
            const command: XkbBindings.Command = switch (tag_bind.command) {
                .set_output_tags => .{ .set_output_tags = tags },
                .set_window_tags => .{ .set_window_tags = tags },
                .toggle_output_tags => .{ .toggle_output_tags = tags },
                .toggle_window_tags => .{ .toggle_window_tags = tags },
                else => unreachable,
            };
            context.xkb_bindings.addBinding(river_seat_v1, @field(xkbcommon.Keysym, &buffer), tag_bind.modifiers, command);
        }
    }
    // Rest of the keybinds
    for (context.config.keybinds.keys(), context.config.keybinds.values()) |key, command| {
        context.xkb_bindings.addBinding(river_seat_v1, key.keysym, key.modifiers, command);
    }

    // Pointer bindings
    for (context.config.pointer_binds.items) |pointer_bind| {
        const binding = river_seat_v1.getPointerBinding(pointer_bind.button, pointer_bind.modifiers) catch {
            log.err("Failed to create pointer binding", .{});
            continue;
        };

        switch (pointer_bind.action) {
            .move_window => {
                if (seat.move_pointer_binding) |old| old.destroy();
                binding.setListener(*Seat, Seat.movePointerBindingListener, seat);
                seat.move_pointer_binding = binding;
            },
            .resize_window => {
                if (seat.resize_pointer_binding) |old| old.destroy();
                binding.setListener(*Seat, Seat.resizePointerBindingListener, seat);
                seat.resize_pointer_binding = binding;
            },
        }
        binding.enable();
    }
}

fn manage(wm: *WindowManager) void {
    const river_window_manager_v1 = wm.river_window_manager_v1;
    const context = wm.context;

    // This gets used shortly, so it goes at the beginning
    context.manage();

    if (!context.initialized) {
        // This code runs during initial startup and after config reloads.
        @branchHint(.cold);
        wm.initialize();
    }

    wm.context.xkb_bindings.manage();

    // Adopt orphan windows before outputs manage so they're included
    // in calculateLayout() and window.manage() this cycle.
    if (wm.orphan_windows.first() != null) {
        const seat = wm.seats.first();
        // We want the seat's focused output if one exists, but otherwise just
        // whatever output is hanging around is fine.
        const output = if (seat) |s|
            s.focused_output orelse if (s.pending_manage.output) |pending_output|
                switch (pending_output) {
                    .output => |output| output,
                    .clear_focus => null,
                }
            else
                null
        else
            wm.outputs.first();

        if (output) |o| {
            var it = wm.orphan_windows.iterator(.forward);
            while (it.next()) |window| {
                window.pending_manage.pending_output = .{ .output = o };
            }
            if (seat) |s| {
                if (s.focused_window == null) {
                    if (wm.orphan_windows.first()) |first| {
                        s.pending_manage.window = .{ .window = first };
                        s.pending_manage.should_warp_pointer = true;
                    } else unreachable;
                }
            }
            o.windows.appendList(&wm.orphan_windows);
        }
    }

    {
        var it = wm.outputs.iterator(.forward);
        while (it.next()) |output| {
            output.manage();
        }
    }
    {
        var it = wm.seats.iterator(.forward);
        while (it.next()) |seat| {
            seat.manage();
        }
    }
    river_window_manager_v1.manageFinish();
}

fn render(wm: *WindowManager) void {
    const river_window_manager_v1 = wm.river_window_manager_v1;
    {
        var it = wm.seats.iterator(.forward);
        while (it.next()) |seat| {
            seat.render();
        }
    }
    {
        var it = wm.outputs.iterator(.forward);
        while (it.next()) |output| {
            output.render();
        }
    }
    river_window_manager_v1.renderFinish();
}

fn windowManagerV1Listener(window_manager_v1: *river.WindowManagerV1, event: river.WindowManagerV1.Event, wm: *WindowManager) void {
    assert(wm.river_window_manager_v1 == window_manager_v1);
    const context = wm.context;
    switch (event) {
        .unavailable => {
            fatal("Window manager unavailable (some other wm instance is running). Exiting", .{});
        },
        .manage_start => wm.manage(),
        .render_start => wm.render(),
        .output => |ev| {
            const output = Output.create(context, ev.id) catch @panic("Out of memory");
            wm.outputs.append(output);
            // If there was already a seat, but no outputs, set this new output as focused
            if (wm.seats.first()) |seat| {
                if (seat.focused_output == null and seat.pending_manage.output == null) {
                    seat.pending_manage.output = .{ .output = output };
                }
            }
        },
        .seat => |ev| {
            // TODO: Support multi-seat (maybe ?)
            const river_seat_v1 = ev.id;
            const river_seat_v1_version = river_seat_v1.getVersion();
            if (river_seat_v1_version < MIN_RIVER_SEAT_V1_VERSION) {
                @branchHint(.cold); // If we're in here, the program is exiting anyways
                utils.versionNotSupported(river.SeatV1, river_seat_v1_version, MIN_RIVER_SEAT_V1_VERSION);
            }

            const seat = Seat.create(context, river_seat_v1) catch @panic("Out of memory");
            wm.seats.append(seat);

            // If there was already an output, but no seats, set the first output as focused
            if (wm.outputs.first()) |output| {
                seat.pending_manage.output = .{ .output = output };
            }
        },
        .window => |ev| {
            const seat = wm.seats.first();
            const focused_output = if (seat) |s|
                s.focused_output orelse if (s.pending_manage.output) |pending_output|
                    switch (pending_output) {
                        .output => |output| output,
                        .clear_focus => null,
                    }
                else
                    wm.outputs.first()
            else
                wm.outputs.first();
            const window_list = if (focused_output) |output|
                &output.windows
            else
                &wm.orphan_windows;
            const window = Window.create(context, ev.id, focused_output) catch @panic("Out of memory");

            switch (context.config.attach_mode) {
                .top => window_list.prepend(window),
                .bottom => window_list.append(window),
            }
            if (seat) |s| {
                s.pending_manage.window = .{ .window = window };
                s.pending_manage.should_warp_pointer = true;
            }
        },
        else => |ev| {
            log.debug("unhandled event: {s}", .{@tagName(ev)});
        },
    }
}

const std = @import("std");
const assert = std.debug.assert;
const fatal = std.process.fatal;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const xkbcommon = @import("xkbcommon");

const utils = @import("utils.zig");
const Context = @import("Context.zig");
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Window = @import("Window.zig");
const XkbBindings = @import("XkbBindings.zig");

const log = std.log.scoped(.WindowManager);
