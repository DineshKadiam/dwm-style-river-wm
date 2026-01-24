// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const WindowManager = @This();

const PRIMARY_RATIO: f32 = 0.55;

context: *Context,

window_manager_v1: *river.WindowManagerV1,

seats: wl.list.Head(Seat, .link),
outputs: wl.list.Head(Output, .link),
windows: wl.list.Head(Window, .link),

window_count: u8 = 0,

/// Get the next window in the list, wrapping to first if at end
pub fn getNextWindow(wm: *WindowManager, current: *Window) ?*Window {
    var it = wm.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window == current) {
            return it.next() orelse wm.windows.first();
        }
    }
    return wm.windows.first();
}

/// Get the previous window in the list, wrapping to last if at beginning
pub fn getPrevWindow(wm: *WindowManager, current: *Window) ?*Window {
    var prev: ?*Window = null;
    var it = wm.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window == current) {
            return prev orelse wm.windows.last();
        }
        prev = window;
    }
    return wm.windows.last();
}

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

/// Calculate primary/stack layout positions for all windows.
/// - Single window: fullscreen
/// - Multiple windows: stack (45% left, vertically tiled), primary (55% right)
fn calculatePrimaryStackLayout(wm: *WindowManager) void {
    const count = wm.window_count;
    if (count == 0) return;

    const output = wm.outputs.first() orelse return;
    // Output dimensions come as i32 from the protocol, convert to u31 for window dimensions
    const output_width: u31 = @intCast(output.width);
    const output_height: u31 = @intCast(output.height);
    const output_x = output.x;
    const output_y = output.y;

    var index: u8 = 0;
    var it = wm.windows.iterator(.forward);
    while (it.next()) |window| {
        if (count == 1) {
            // Single window: maximize
            window.pending_state.x = output_x;
            window.pending_state.y = output_y;
            window.pending_state.width = output_width;
            window.pending_state.height = output_height;
            window.pending_state.maximized = true;
        } else {
            // Multiple windows: primary/stack layout
            // TODO: Support multiple windows in primary stack
            const primary_width: u31 = @intFromFloat(@as(f32, @floatFromInt(output_width)) * PRIMARY_RATIO);
            const stack_width: u31 = output_width - primary_width;
            const stack_count = count - 1;
            const stack_height: u31 = @divFloor(output_height, stack_count);
            window.pending_state.maximized = false;

            if (index == 0) {
                // Primary window (first window) - right side
                window.pending_state.x = output_x + @as(i32, stack_width);
                window.pending_state.y = output_y;
                window.pending_state.width = primary_width;
                window.pending_state.height = output_height;
            } else {
                // Stack window(s) - left side
                const stack_index = index - 1;
                window.pending_state.x = output_x;
                window.pending_state.y = output_y + @as(i32, stack_index) * @as(i32, stack_height);
                window.pending_state.width = stack_width;
                // Last stack window gets remaining height to avoid gaps from integer division
                if (index == count - 1) {
                    window.pending_state.height = output_height - stack_index * stack_height;
                } else {
                    window.pending_state.height = stack_height;
                }
            }
        }
        // Make space for borders; this is the same for all windows.
        // Borders are automatically disabled when a window is fullscreened so we don't
        // have to worry about that.
        const border_width = wm.context.config.border_width;
        window.pending_state.height.? -= 2 * border_width;
        window.pending_state.width.? -= 2 * border_width;
        window.pending_state.x.? += border_width;
        window.pending_state.y.? += border_width;

        index += 1;
    }
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
                // This code (should) only be run once while initializing the WM, so let's
                // mark it as cold.
                @branchHint(.cold);
                context.initialized = true;
                context.xkb_bindings.addBinding(xkbcommon.Keysym.t, .{ .mod4 = true }, .{ .spawn = &.{"foot"} });
                context.xkb_bindings.addBinding(xkbcommon.Keysym.j, .{ .mod4 = true }, .focus_next);
                context.xkb_bindings.addBinding(xkbcommon.Keysym.k, .{ .mod4 = true }, .focus_prev);
                context.xkb_bindings.addBinding(xkbcommon.Keysym.f, .{ .mod4 = true }, .fullscreen);
                context.xkb_bindings.addBinding(xkbcommon.Keysym.q, .{ .mod4 = true, .shift = true }, .close_window);
                context.xkb_bindings.addBinding(xkbcommon.Keysym.e, .{ .mod4 = true, .shift = true }, .exit);
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
            // Calculate layout before managing windows
            wm.calculatePrimaryStackLayout();
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
const XkbBindings = @import("XkbBindings.zig");

const log = std.log.scoped(.WindowManager);
