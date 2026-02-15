// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Window = @This();

context: *Context,

river_window_v1: *river.WindowV1,
river_node_v1: *river.NodeV1,

// TODO: Could switch this to a Rect { x, y, width, height }
width: u31 = 0,
height: u31 = 0,
x: i32 = 0,
y: i32 = 0,

fullscreen: bool = false,
maximized: bool = false,

tags: u32 = 0x0001,
output: ?*Output,

floating: bool = false,
float_width: u31 = 0,
float_height: u31 = 0,
float_x: i32 = 0,
float_y: i32 = 0,

initialized: bool = false,

/// State consumed in manage() phase, reset at end of manage().
pending_manage: PendingManage = .{},

/// State consumed in render() phase, reset at end of render().
pending_render: PendingRender = .{},

/// Used to put Windows into a list in calculatePrimaryStackLayout()
active_list_node: DoublyLinkedList.Node = .{},

link: wl.list.Link,

pub const PendingManage = struct {
    width: ?u31 = null,
    height: ?u31 = null,

    fullscreen: ?bool = null,
    maximized: ?bool = null,

    tags: ?u32 = null,
    pending_output: ?PendingOutput = null,

    floating: ?bool = null,

    pub const PendingOutput = union(enum) {
        output: *Output,
        clear_output,
    };
};

pub const PendingRender = struct {
    x: ?i32 = null,
    y: ?i32 = null,

    focused: ?bool = null,

    show: ?bool = null,
};

pub fn create(context: *Context, river_window_v1: *river.WindowV1, output: ?*Output) !*Window {
    var window = try utils.gpa.create(Window);
    errdefer utils.gpa.destroy(window);

    window.* = .{
        .context = context,
        .river_window_v1 = river_window_v1,
        .river_node_v1 = river_window_v1.getNode() catch @panic("Failed to get node"),
        .output = output,
        .tags = if (output) |o| o.tags else 0x0001,
        .link = undefined, // Handled by the wl.list
    };

    window.river_window_v1.setListener(*Window, windowListener, window);

    return window;
}

pub fn destroy(window: *Window) void {
    window.river_window_v1.destroy();
    window.river_node_v1.destroy();

    utils.gpa.destroy(window);
}

fn windowListener(river_window_v1: *river.WindowV1, event: river.WindowV1.Event, window: *Window) void {
    assert(window.river_window_v1 == river_window_v1);
    switch (event) {
        .closed => {
            // Clear any pointer operations referencing this window
            var seat_it = window.context.wm.seats.iterator(.forward);
            while (seat_it.next()) |seat| {
                switch (seat.pointer_op) {
                    .move => |op| if (op.window == window) {
                        seat.river_seat_v1.opEnd();
                        seat.pointer_op = .none;
                    },
                    .resize => |op| if (op.window == window) {
                        seat.river_seat_v1.opEnd();
                        seat.pointer_op = .none;
                    },
                    .none => {},
                }
                if (seat.pending_manage.pointer_move_request == window)
                    seat.pending_manage.pointer_move_request = null;
                if (seat.pending_manage.pointer_resize_request) |req| {
                    if (req.window == window)
                        seat.pending_manage.pointer_resize_request = null;
                }
            }
            // If there's no output, we don't really care about focus and can skip this event
            const output = if (window.output) |output| output else return;
            var it = window.context.wm.seats.iterator(.forward);
            while (it.next()) |seat| {
                if (seat.focused_window == window) {
                    // Find another window to focus and warp pointer there
                    if (output.prevWindow(window)) |next_focus| {
                        if (next_focus != window) {
                            seat.pending_manage.window = .{ .window = next_focus };
                            seat.pending_manage.should_warp_pointer = true;
                        } else {
                            // Only window in list - clear focus
                            seat.pending_manage.window = .clear_focus;
                        }
                    } else {
                        seat.pending_manage.window = .clear_focus;
                    }
                }
            }
            window.link.remove();
            window.destroy();
        },
        .dimensions => |ev| {
            // Protocol guarantees that width and height are strictly greater than zero
            assert(ev.width > 0 and ev.height > 0);
            window.pending_manage.width = @intCast(ev.width);
            window.pending_manage.height = @intCast(ev.height);
        },
        .dimensions_hint => {
            // TODO: Maybe could use this for floating windows
        },
        else => |ev| {
            log.debug("unhandled event: {s}", .{@tagName(ev)});
        },
    }
}

pub fn manage(window: *Window) void {
    const river_window_v1 = window.river_window_v1;
    if (!window.initialized) {
        // Only happens once per Window
        @branchHint(.unlikely);
        window.initialized = true;

        // TODO: We might want to think about paying attention to the decoration_hint event
        //       If we do, this would need to move, I think?
        river_window_v1.useSsd();

        river_window_v1.setCapabilities(.{ .fullscreen = true, .maximize = true });
        river_window_v1.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
    }

    // Updating state since the last manage event
    defer window.pending_manage = .{};
    const pending_manage = window.pending_manage;
    // Floating status
    if (pending_manage.floating) |floating| blk: {
        // This needs to be before proposing the new dimensions since we want to save the current ones!
        // Skip the rest of the block if floating matches what is already set
        if (floating == window.floating) break :blk;

        window.floating = floating;
        if (floating) {
            // Let the window know it isn't tiled
            river_window_v1.setTiled(.{});

            if (window.float_width == 0) {
                // Never floated before; use 75% of usable area, centered on output
                if (window.output) |output| {
                    window.float_width = @divFloor(output.usable_width * 3, 4);
                    window.float_height = @divFloor(output.usable_height * 3, 4);
                    window.float_x = output.usable_x + @divFloor(output.usable_width, 2) - @divFloor(window.float_width, 2);
                    window.float_y = output.usable_y + @divFloor(output.usable_height, 2) - @divFloor(window.float_height, 2);
                } else {
                    window.float_width = window.width;
                    window.float_height = window.height;
                }
                river_window_v1.proposeDimensions(window.float_width, window.float_height);
            } else {
                // Window has floated before; re-use its old dimensions
                river_window_v1.proposeDimensions(window.float_width, window.float_height);
            }
            window.pending_render.x = window.float_x;
            window.pending_render.y = window.float_y;
        } else {
            river_window_v1.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
            // Save floating dimensions in case the window gets floated again
            window.float_width = window.width;
            window.float_height = window.height;
            window.float_x = window.x;
            window.float_y = window.y;
        }
    }
    // Layout (pre-computed by WindowManager.calculatePrimaryStackLayout())
    if (pending_manage.width) |new_width| {
        if (pending_manage.height) |new_height| {
            window.width = new_width;
            window.height = new_height;
            window.river_window_v1.proposeDimensions(new_width, new_height);
        }
    }
    // Fullscreen and maximize operations
    if (pending_manage.fullscreen) |fullscreen| blk: {
        window.fullscreen = fullscreen;
        if (fullscreen) {
            // If the window isn't on an output, just skip fullscreening
            const output = window.output orelse break :blk;
            window.river_window_v1.fullscreen(output.river_output_v1);
            window.river_window_v1.informFullscreen();
        } else {
            window.river_window_v1.exitFullscreen();
            window.river_window_v1.informNotFullscreen();
        }
    }
    if (pending_manage.maximized) |maximized| {
        window.maximized = maximized;
        if (maximized) {
            window.river_window_v1.informMaximized();
        } else {
            window.river_window_v1.informUnmaximized();
        }
    }
    // New tags
    if (pending_manage.tags) |tags| {
        window.tags = tags;
    }
    // New output
    if (pending_manage.pending_output) |pending_output| {
        switch (pending_output) {
            .output => |output| {
                window.output = output;
            },
            .clear_output => window.output = null,
        }
    }
}

pub fn render(window: *Window) void {
    defer window.pending_render = .{};

    // TODO: We probably could just move these back to pending_manage and have PendingRiver.new_coords: bool
    //       This would also simplify the pointer warp behaviour in Seat.manage()
    if (window.pending_render.x) |new_x| {
        if (window.pending_render.y) |new_y| {
            window.x = new_x;
            window.y = new_y;

            window.river_node_v1.setPosition(window.x, window.y);
        } else {
            log.err("Window.pending_render with only x set", .{});
        }
    } else if (window.pending_render.y) |_| {
        log.err("Window.pending_render with only y set", .{});
    }

    // Set borders
    if (!window.fullscreen) {
        if (window.pending_render.focused) |focused| {
            if (focused) {
                window.applyBorders(window.context.config.border_color_focused);
            } else {
                window.applyBorders(window.context.config.border_color_unfocused);
            }
        }
    }

    // Show or hide the Window
    if (window.pending_render.show) |show| {
        if (show) {
            window.river_window_v1.show();
        } else {
            window.river_window_v1.hide();
        }
    }
}

fn applyBorders(window: *Window, color: utils.RiverColor) void {
    const border_width = window.context.config.border_width;
    const all_sides = river.WindowV1.Edges{ .top = true, .bottom = true, .left = true, .right = true };
    window.river_window_v1.setBorders(all_sides, border_width, color.red, color.green, color.blue, color.alpha);
}

const std = @import("std");
const assert = std.debug.assert;
const DoublyLinkedList = std.DoublyLinkedList;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("Context.zig");
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.Window);
