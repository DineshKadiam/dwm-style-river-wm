// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Output = @This();

context: *Context,

river_output_v1: *river.OutputV1,

width: i32 = 0,
height: i32 = 0,
x: i32 = 0,
y: i32 = 0,

/// Proportion of output width taken by the primary stack
primary_ratio: f32 = 0.55,

/// Tags are 32-bit bitfield. A window can be active on one(?) or more tags.
tags: u32 = 0x0001,

/// State consumed in manage() phase, reset at end of manage().
pending_manage: PendingManage = .{},

windows: wl.list.Head(Window, .link),

link: wl.list.Link,

pub const PendingManage = struct {
    width: ?i32 = null,
    height: ?i32 = null,
    x: ?i32 = null,
    y: ?i32 = null,

    tags: ?u32 = null,
    primary_ratio: ?f32 = null,
};

pub fn create(context: *Context, river_output_v1: *river.OutputV1) !*Output {
    var output = try utils.allocator.create(Output);
    errdefer output.destroy();

    output.* = .{
        .context = context,
        .river_output_v1 = river_output_v1,
        .windows = undefined, // we will initialize this shortly
        .link = undefined, // Handled by the wl.list
    };

    output.windows.init();

    output.river_output_v1.setListener(*Output, outputListener, output);

    return output;
}

pub fn destroy(output: *Output) void {
    var it = output.windows.safeIterator(.forward);
    while (it.next()) |window| {
        window.link.remove();
        window.destroy();
    }

    output.river_output_v1.destroy();
    utils.allocator.destroy(output);
}

/// Get the next window in the list, wrapping to first if at end
pub fn nextWindow(output: *Output, current: *Window) ?*Window {
    const next_link = current.link.next orelse return output.windows.first();
    // If we've reached the sentinel (head's link), wrap to first
    if (next_link == &output.windows.link) return output.windows.first();
    return @fieldParentPtr("link", next_link);
}

/// Get the previous window in the list, wrapping to last if at beginning
pub fn prevWindow(output: *Output, current: *Window) ?*Window {
    const prev_link = current.link.prev orelse return output.windows.last();
    // If we've reached the sentinel (head's link), wrap to last
    if (prev_link == &output.windows.link) return output.windows.last();
    return @fieldParentPtr("link", prev_link);
}

fn outputListener(river_output_v1: *river.OutputV1, event: river.OutputV1.Event, output: *Output) void {
    assert(output.river_output_v1 == river_output_v1);
    switch (event) {
        .removed => {
            const context = output.context;
            const wm = context.wm;

            // Move windows to the previous output in the list.
            // If this was the only output, windows become orphans.
            const prev_output: ?*Output = if (wm.prevOutput(output)) |prev| blk: {
                if (prev == output) break :blk null; // Only output; wrapped to itself
                break :blk prev; // We got the previous list
            } else unreachable;

            const window_pending_output: Window.PendingManage.PendingOutput =
                if (prev_output) |prev|
                    .{ .output = prev }
                else
                    .clear_output;

            // Update each window's output before moving the list
            var it = output.windows.iterator(.forward);
            while (it.next()) |window| {
                window.pending_manage.pending_output = window_pending_output;
            }

            // Move windows to new destination
            const dest_list = if (prev_output) |prev| &prev.windows else &wm.orphan_windows;
            dest_list.appendList(&output.windows);

            blk: {
                // If the removed output was focused, move focus to the next
                // available output (and its first window, if any).
                // TODO: Support multiple seats
                const seat = wm.seats.first() orelse break :blk;
                if (seat.focused_output != output) break :blk;

                const next_output = wm.nextOutput(output);
                if (next_output == output) break :blk;
                const o = next_output orelse break :blk;

                seat.pending_manage.output = .{ .output = o };
                if (o.windows.first()) |window| {
                    seat.pending_manage.window = .{ .window = window };
                }
            }

            output.link.remove();
            output.destroy();
        },
        .wl_output => |ev| {
            log.debug("initializing new river_output_v1 corresponding to wl_output: {d}", .{ev.name});
        },
        .dimensions => |ev| {
            output.pending_manage.width = ev.width;
            output.pending_manage.height = ev.height;
            output.context.wm.river_window_manager_v1.manageDirty();
        },
        .position => |ev| {
            output.pending_manage.x = ev.x;
            output.pending_manage.y = ev.y;
            output.context.wm.river_window_manager_v1.manageDirty();
        },
    }
}

pub fn manage(output: *Output) void {
    defer output.pending_manage = .{};

    if (output.pending_manage.width) |width| {
        output.width = width;
    }
    if (output.pending_manage.height) |height| {
        output.height = height;
    }
    if (output.pending_manage.x) |x| {
        output.x = x;
    }
    if (output.pending_manage.y) |y| {
        output.y = y;
    }

    if (output.pending_manage.tags) |tags| {
        output.tags = tags;
    }
    if (output.pending_manage.primary_ratio) |primary_ratio| {
        // Ratios outside of this range could cause crashes (when doing the layout calculation)
        output.primary_ratio = std.math.clamp(primary_ratio, 0.10, 0.90);
    }

    // Calculate layout before managing windows
    output.calculatePrimaryStackLayout();
    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        window.manage();
    }
}

pub fn render(output: *Output) void {
    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        window.render();
    }
}

// TODO - CONFIG: Allow primary on the left
// TODO - CONFIG: Allow setting a ratio for single-window width (useful for ultrawides)
/// Calculate primary/stack layout positions for all windows.
/// - Single window: maximized
/// - Multiple windows: stack (45% left, vertically tiled), primary (55% right)
fn calculatePrimaryStackLayout(output: *Output) void {
    // Get a list of active windows
    var active_list: DoublyLinkedList = .{};
    var active_count: u31 = 0;
    var it = output.windows.iterator(.forward);
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
            const primary_width: u31 = @intFromFloat(@as(f32, @floatFromInt(output_width)) * output.primary_ratio);
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
        const border_width = output.context.config.border_width;
        // We use .? because we know we set the windows height, width, x, and y above
        window.pending_manage.height.? -= 2 * border_width;
        window.pending_manage.width.? -= 2 * border_width;
        window.pending_render.x.? += border_width;
        window.pending_render.y.? += border_width;
    }

    // Make sure we went through the whole list
    assert(active_list.first == null);
}

const std = @import("std");
const assert = std.debug.assert;
const DoublyLinkedList = std.DoublyLinkedList;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("Context.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.Output);
