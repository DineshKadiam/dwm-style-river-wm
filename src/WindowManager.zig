// SPDX-FileCopyrightText: 2025-2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const WindowManager = @This();

context: *Context,

window_manager_v1: *river.WindowManagerV1,

seats: wl.list.Head(Seat, .link),
outputs: wl.list.Head(Output, .link),
windows: wl.list.Head(Window, .link),

window_count: u8 = 0,

pub fn init(wm: *WindowManager, context: *Context, window_manager_v1: *river.WindowManagerV1) void {
    assert(wm == &context.wm);
    wm.* = .{
        .context = context,
        .window_manager_v1 = window_manager_v1,
        .seats = undefined, // we will initialize this shortly
        .outputs = undefined,
        .windows = undefined,
    };

    wm.seats.init();
    wm.outputs.init();
    wm.windows.init();

    wm.window_manager_v1.setListener(*WindowManager, windowManagerV1Listener, wm);
}

fn windowManagerV1Listener(window_manager_v1: *river.WindowManagerV1, event: river.WindowManagerV1.Event, wm: *WindowManager) void {
    assert(wm.window_manager_v1 == window_manager_v1);
    const context = wm.context;
    switch (event) {
        .unavailable => {
            log.err("Window manager unavailable (some other wm instance is running). Exiting", .{});
            std.posix.exit(1);
        },
        .manage_start => {
            if (!context.initialized) {
                context.initialized = true;
                context.xkb_bindings.addBinding(xkbcommon.Keysym.t, .{ .mod1 = true });
            }
            {
                var it = wm.seats.iterator(.forward);
                while (it.next()) |seat| {
                    seat.manage();
                }
            }
            {
                var it = wm.outputs.iterator(.forward);
                while (it.next()) |output| {
                    output.manage();
                }
            }
            {
                var it = wm.windows.iterator(.forward);
                while (it.next()) |window| {
                    window.manage();
                }
            }
            window_manager_v1.manageFinish();
        },
        .render_start => {
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
            {
                var it = wm.windows.iterator(.forward);
                while (it.next()) |window| {
                    window.render();
                }
            }
            window_manager_v1.renderFinish();
        },
        .output => |ev| {
            log.debug("3", .{});
            var output = context.allocator.create(Output) catch @panic("out-of-memory; exiting.");
            output.init(context, ev.id);
            wm.outputs.append(output);
        },
        .seat => |ev| {
            log.debug("4", .{});
            var seat = context.allocator.create(Seat) catch @panic("out-of-memory; exiting.");
            seat.init(context, ev.id);
            wm.seats.append(seat);
        },
        .window => |ev| {
            log.debug("5", .{});
            var window = context.allocator.create(Window) catch @panic("out-of-memory; exiting.");
            window.init(context, ev.id);
            wm.windows.append(window);
            wm.window_count += 1;
            if (wm.window_count == 1) {
                window.is_head = true;
            }
            log.debug("window_count = {d}", .{wm.window_count});
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

const xkbcommon = @import("xkbcommon");

const Context = @import("main.zig").Context;
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.WindowManager);
