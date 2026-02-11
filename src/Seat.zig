// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Seat = @This();

context: *Context,

river_seat_v1: *river.SeatV1,

focused_window: ?*Window,
focused_output: ?*Output,

pointer_op: PointerOp = .none,

/// State consumed in manage phase, reset at end of manage().
pending_manage: PendingManage = .{},

link: wl.list.Link,

// Pointer bindings for interactive move/resize
move_pointer_binding: ?*river.PointerBindingV1 = null,
resize_pointer_binding: ?*river.PointerBindingV1 = null,

pub const PendingManage = struct {
    window: ?PendingWindow = null,
    output: ?PendingOutput = null,
    should_warp_pointer: bool = false,

    op_delta: ?struct { dx: i32, dy: i32 } = null,
    op_released: bool = false,
    pointer_move_request: ?*Window = null,
    pointer_resize_request: ?struct { window: *Window, edges: river.WindowV1.Edges } = null,

    pub const PendingWindow = union(enum) {
        window: *Window,
        clear_focus,
    };

    pub const PendingOutput = union(enum) {
        output: *Output,
        clear_focus,
    };
};

pub const PointerOp = union(enum) {
    none,
    move: struct { window: *Window, start_x: i32, start_y: i32 },
    resize: struct {
        window: *Window,
        start_width: u31,
        start_height: u31,
        start_x: i32,
        start_y: i32,
        edges: river.WindowV1.Edges,
    },
};

pub fn create(context: *Context, river_seat_v1: *river.SeatV1) !*Seat {
    var seat = try utils.allocator.create(Seat);
    errdefer seat.destroy();

    seat.* = .{
        .context = context,
        .river_seat_v1 = river_seat_v1,
        .focused_window = null,
        .focused_output = null,
        .link = undefined, // Handled by the wl.list
    };

    seat.river_seat_v1.setListener(*Seat, seatListener, seat);

    return seat;
}

pub fn destroy(seat: *Seat) void {
    if (seat.move_pointer_binding) |binding| binding.destroy();
    if (seat.resize_pointer_binding) |binding| binding.destroy();
    seat.river_seat_v1.destroy();
    utils.allocator.destroy(seat);
}

fn seatListener(river_seat_v1: *river.SeatV1, event: river.SeatV1.Event, seat: *Seat) void {
    assert(seat.river_seat_v1 == river_seat_v1);
    switch (event) {
        .removed => seat.destroy(),
        .wl_seat => |ev| {
            log.debug("initializing new river_seat_v1 corresponding to wl_seat: {d}", .{ev.name});
        },
        .pointer_enter => |ev| if (seat.context.config.focus_follows_pointer) {
            seat.setWindowFocus(ev.window);
        },
        .window_interaction => |ev| seat.setWindowFocus(ev.window),
        .op_delta => |ev| {
            seat.pending_manage.op_delta = .{ .dx = ev.dx, .dy = ev.dy };
        },
        .op_release => {
            seat.pending_manage.op_released = true;
        },
        else => |ev| {
            log.debug("unhandled event: {s}", .{@tagName(ev)});
        },
    }
}

// river_window_v1 needs to be optional because ev.window is optional
fn setWindowFocus(seat: *Seat, river_window_v1: ?*river.WindowV1) void {
    const wv1 = river_window_v1 orelse return;
    const window: *Window = @ptrCast(@alignCast(wv1.getUserData() orelse {
        log.err("river_window_v1 has no user data", .{});
        return;
    }));
    seat.pending_manage.window = .{ .window = window };
}

pub fn manage(seat: *Seat) void {
    defer seat.pending_manage = .{};

    if (seat.pending_manage.window) |pending_window| {
        switch (pending_window) {
            .window => |window| {
                if (seat.focused_window) |focused| {
                    // Tell the previously focused Window that it's no longer focused
                    if (focused != window) {
                        focused.pending_render.focused = false;
                    }
                }
                seat.focused_window = window;
                seat.river_seat_v1.focusWindow(window.river_window_v1);
                window.pending_render.focused = true;
            },
            .clear_focus => {
                if (seat.focused_window) |focused| {
                    // Tell the previously focused Window that it's no longer focused
                    focused.pending_render.focused = false;
                }
                seat.focused_window = null;
                seat.river_seat_v1.clearFocus();
            },
        }
    }
    if (seat.pending_manage.output) |pending_output| {
        switch (pending_output) {
            .output => |output| {
                seat.focused_output = output;
            },
            .clear_focus => {
                seat.focused_output = null;
            },
        }
    }

    if (seat.pending_manage.should_warp_pointer) blk: {
        if (seat.context.config.pointer_warp_on_focus_change) {
            const window = seat.focused_window orelse {
                log.warn("Trying to warp-on-focus-change without a focused window.", .{});
                break :blk;
            };
            // Warp pointer to center of focused window;
            // because the x and y coords are set during render, we need to check if
            // there are new coordinates in window.pending_render.
            const pointer_x: i32 = (window.pending_render.x orelse window.x) + @divTrunc(window.width, 2);
            const pointer_y: i32 = (window.pending_render.y orelse window.y) + @divTrunc(window.height, 2);
            seat.river_seat_v1.pointerWarp(pointer_x, pointer_y);
        }
    }

    // Interactive move/resize operations

    // Start move operation
    if (seat.pending_manage.pointer_move_request) |window| {
        if (window.floating) {
            seat.pointer_op = .{
                .move = .{
                    .window = window,
                    .start_x = window.float_x,
                    .start_y = window.float_y,
                },
            };
            seat.river_seat_v1.opStartPointer();
        }
    }

    // Start resize operation
    if (seat.pending_manage.pointer_resize_request) |req| {
        if (req.window.floating) {
            seat.pointer_op = .{
                .resize = .{
                    .window = req.window,
                    .start_width = req.window.float_width,
                    .start_height = req.window.float_height,
                    .start_x = req.window.float_x,
                    .start_y = req.window.float_y,
                    .edges = req.edges,
                },
            };
            seat.river_seat_v1.opStartPointer();
            req.window.river_window_v1.informResizeStart();
        }
    }

    // Process pointer delta (mouse movement during operation)
    if (seat.pending_manage.op_delta) |delta| {
        switch (seat.pointer_op) {
            .none => {},
            .move => |op| {
                const output = op.window.output orelse {
                    log.err("window has no output during move operation", .{});
                    return;
                };
                const min_x = output.x;
                const max_x = output.x + output.width - @as(i32, op.window.float_width);
                const min_y = output.y;
                const max_y = output.y + output.height - @as(i32, op.window.float_height);

                op.window.float_x = std.math.clamp(op.start_x + delta.dx, min_x, @max(min_x, max_x));
                op.window.float_y = std.math.clamp(op.start_y + delta.dy, min_y, @max(min_y, max_y));
                op.window.pending_render.x = op.window.float_x;
                op.window.pending_render.y = op.window.float_y;
            },
            .resize => |op| {
                var new_width: i32 = op.start_width;
                var new_height: i32 = op.start_height;
                var new_x: i32 = op.start_x;
                var new_y: i32 = op.start_y;

                // Adjust based on which edges are being dragged
                if (op.edges.right) new_width += delta.dx;
                if (op.edges.left) {
                    new_width -= delta.dx;
                    new_x += delta.dx;
                }
                if (op.edges.bottom) new_height += delta.dy;
                if (op.edges.top) {
                    new_height -= delta.dy;
                    new_y += delta.dy;
                }

                // Clamp to minimum size
                const min_size: i32 = 50;
                if (new_width < min_size) {
                    if (op.edges.left) new_x -= min_size - new_width;
                    new_width = min_size;
                }
                if (new_height < min_size) {
                    if (op.edges.top) new_y -= min_size - new_height;
                    new_height = min_size;
                }

                // Clamp position to output bounds
                const output = op.window.output orelse {
                    log.err("window has no output during resize operation", .{});
                    return;
                };
                new_x = std.math.clamp(new_x, output.x, @max(output.x, output.x + output.width - new_width));
                new_y = std.math.clamp(new_y, output.y, @max(output.y, output.y + output.height - new_height));

                op.window.float_width = @intCast(new_width);
                op.window.float_height = @intCast(new_height);
                op.window.float_x = new_x;
                op.window.float_y = new_y;

                op.window.river_window_v1.proposeDimensions(
                    op.window.float_width,
                    op.window.float_height,
                );
                op.window.pending_render.x = op.window.float_x;
                op.window.pending_render.y = op.window.float_y;
            },
        }
    }

    // Process pointer release (end of operation)
    if (seat.pending_manage.op_released) {
        switch (seat.pointer_op) {
            .none => {},
            .move => {
                seat.river_seat_v1.opEnd();
                seat.pointer_op = .none;
            },
            .resize => |op| {
                op.window.river_window_v1.informResizeEnd();
                seat.river_seat_v1.opEnd();
                seat.pointer_op = .none;
            },
        }
    }
}

pub fn render(seat: *Seat) void {
    _ = seat;
}

pub fn movePointerBindingListener(_: *river.PointerBindingV1, event: river.PointerBindingV1.Event, seat: *Seat) void {
    switch (event) {
        .pressed => {
            const window = seat.focused_window orelse return;
            if (!window.floating) {
                // Auto-float on drag
                window.pending_manage.floating = true;
            }
            seat.pending_manage.pointer_move_request = window;
            seat.context.wm.river_window_manager_v1.manageDirty();
        },
        .released => {},
    }
}

pub fn resizePointerBindingListener(_: *river.PointerBindingV1, event: river.PointerBindingV1.Event, seat: *Seat) void {
    switch (event) {
        .pressed => {
            const window = seat.focused_window orelse return;
            if (!window.floating) {
                // Auto-float on drag
                window.pending_manage.floating = true;
            }
            seat.pending_manage.pointer_resize_request = .{
                .window = window,
                .edges = .{ .bottom = true, .right = true },
            };
            seat.context.wm.river_window_manager_v1.manageDirty();
        },
        .released => {},
    }
}

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("Context.zig");
const Output = @import("Output.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.Seat);
