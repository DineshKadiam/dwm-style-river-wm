// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const WindowManager = @This();

const MIN_RIVER_SEAT_V1_VERSION: u2 = 3;

context: *Context,

river_window_manager_v1: *river.WindowManagerV1,

seats: wl.list.Head(Seat, .link),
outputs: wl.list.Head(Output, .link),
windows: wl.list.Head(Window, .link),

window_count: u8 = 0,

primary_ratio: f32 = 0.55,

/// State consumed in manage phase, reset at end of manage_start().
pending_manage: PendingManage = .{},

pub const PendingManage = struct {
    primary_ratio: ?f32 = null,
};

pub fn create(context: *Context, window_manager_v1: *river.WindowManagerV1) !*WindowManager {
    const wm = try utils.allocator.create(WindowManager);
    errdefer wm.destroy();

    wm.* = .{
        .context = context,
        .river_window_manager_v1 = window_manager_v1,
        .seats = undefined, // we will initialize these shortly
        .outputs = undefined,
        .windows = undefined,
    };

    wm.seats.init();
    wm.outputs.init();
    wm.windows.init();

    wm.river_window_manager_v1.setListener(*WindowManager, windowManagerV1Listener, wm);

    return wm;
}

pub fn destroy(wm: *WindowManager) void {
    {
        var it = wm.windows.safeIterator(.forward);
        while (it.next()) |window| {
            window.link.remove();
            window.destroy();
        }
    }
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

    utils.allocator.destroy(wm);
}

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

/// Calculate primary/stack layout positions for all windows.
/// - Single window: maximized
/// - Multiple windows: stack (45% left, vertically tiled), primary (55% right)
fn calculatePrimaryStackLayout(wm: *WindowManager) void {
    // TODO: Support multiple outputs
    const output = wm.outputs.first() orelse return;

    // Get a list of active windows
    var active_list: DoublyLinkedList = .{};
    var active_count: u31 = 0;
    var it = wm.windows.iterator(.forward);
    while (it.next()) |window| {
        if (output.tags & window.tags != 0x0000) {
            active_list.append(&window.active_list_node);
            active_count += 1;
            window.pending_render.show = true;
        } else {
            window.pending_render.show = false;
        }
    }

    if (active_count == 0) return;

    // Output dimensions come as i32 from the protocol, convert to u31 for window dimensions
    // since they can't be negative.
    const output_width: u31 = @intCast(output.width);
    const output_height: u31 = @intCast(output.height);
    const output_x = output.x;
    const output_y = output.y;

    // Iterate through the active windows and apply the tags
    var i: u31 = 0;
    while (active_list.popFirst()) |node| : (i += 1) {
        const window: *Window = @fieldParentPtr("active_list_node", node);
        if (active_count == 1) {
            // Single window: maximize
            window.pending_render.x = output_x;
            window.pending_render.y = output_y;
            window.pending_manage.width = output_width;
            window.pending_manage.height = output_height;
            window.pending_manage.maximized = true;
        } else {
            // Multiple windows: primary/stack layout
            // TODO: Support multiple windows in primary stack
            const primary_width: u31 = @intFromFloat(@as(f32, @floatFromInt(output_width)) * wm.primary_ratio);
            const stack_width: u31 = output_width - primary_width;
            const stack_count = active_count - 1;
            const stack_height: u31 = @divFloor(output_height, stack_count);
            window.pending_manage.maximized = false;

            if (i == 0) {
                // Primary window (first window) - right side
                window.pending_render.x = output_x + @as(i32, stack_width);
                window.pending_render.y = output_y;
                window.pending_manage.width = primary_width;
                window.pending_manage.height = output_height;
            } else {
                // Stack window(s) - left side
                const stack_index = i - 1;
                window.pending_render.x = output_x;
                window.pending_render.y = output_y + @as(i32, stack_index) * @as(i32, stack_height);
                window.pending_manage.width = stack_width;
                // Last stack window gets remaining height to avoid gaps from integer division
                if (i == active_count - 1) {
                    window.pending_manage.height = output_height - stack_index * stack_height;
                } else {
                    window.pending_manage.height = stack_height;
                }
            }
        }
        // Make space for borders; this is the same for all windows.
        // Borders are automatically disabled when a window is fullscreened so we don't
        // have to worry about that.
        const border_width = wm.context.config.border_width;
        // We use .? because we know we set the windows height, width, x, and y above
        window.pending_manage.height.? -= 2 * border_width;
        window.pending_manage.width.? -= 2 * border_width;
        window.pending_render.x.? += border_width;
        window.pending_render.y.? += border_width;
    }

    // Make sure we went through the whole list
    assert(active_list.first == null);
}

fn manage_start(wm: *WindowManager) void {
    defer wm.pending_manage = .{};

    const river_window_manager_v1 = wm.river_window_manager_v1;
    const context = wm.context;
    if (!context.initialized) {
        // This code (should) only be run once while initializing the WM, so let's
        // mark it as cold.
        @branchHint(.cold);
        context.initialized = true;

        const seat = wm.seats.first() orelse @panic("Failed to get seat");
        const river_seat_v1 = seat.river_seat_v1;

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
        for (context.config.keybinds.items) |keybind| {
            // Keysyms should only be null in tag_binds (above)
            std.debug.assert(keybind.keysym != null);
            context.xkb_bindings.addBinding(river_seat_v1, keybind.keysym.?, keybind.modifiers, keybind.command);
        }
    }

    // Manage the WM itself first
    if (wm.pending_manage.primary_ratio) |primary_ratio| {
        // Ratios outside of this range can cause crashes anyways (when doing the layout calulcation)
        std.debug.assert(primary_ratio >= 0.10 and primary_ratio <= 0.90);
        wm.primary_ratio = primary_ratio;
    }

    {
        var it = wm.outputs.iterator(.forward);
        while (it.next()) |output| {
            output.manage();
        }
    }
    {
        // Calculate layout before managing windows
        wm.calculatePrimaryStackLayout();
        var it = wm.windows.iterator(.forward);
        while (it.next()) |window| {
            window.manage();
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

fn render_start(wm: *WindowManager) void {
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
    {
        var it = wm.windows.iterator(.forward);
        while (it.next()) |window| {
            window.render();
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
        .manage_start => wm.manage_start(),
        .render_start => wm.render_start(),
        .output => |ev| {
            log.debug("initializing new wl_output: {d}", .{ev.id.getId()});
            // TODO: Support multi-output
            const output = Output.create(context, ev.id) catch @panic("Out of memory");
            wm.outputs.append(output);
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
        },
        .window => |ev| {
            // TODO: Support multiple seats
            const seat = wm.seats.first() orelse @panic("Failed to get seat");
            // TODO: Support multiple outputs
            const output = wm.outputs.first() orelse @panic("Failed to get output");
            const window = Window.create(context, ev.id, output) catch @panic("Out of memory");

            switch (context.config.attach_mode) {
                .top => wm.windows.prepend(window),
                .bottom => wm.windows.append(window),
            }
            seat.pending_manage.pending_focus = .{ .window = window };
            seat.pending_manage.should_warp_pointer = true;

            wm.window_count += 1;
        },
        else => |ev| {
            log.debug("unhandled event: {s}", .{@tagName(ev)});
        },
    }
}

const std = @import("std");
const assert = std.debug.assert;
const fatal = std.process.fatal;
const DoublyLinkedList = std.DoublyLinkedList;

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
