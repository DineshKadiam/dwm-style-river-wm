// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Seat = @This();

context: *Context,

river_seat_v1: *river.SeatV1,
river_layer_shell_seat_v1: *river.LayerShellSeatV1,

focused: ?Focused = null,
layer_focus: LayerFocus = .focus_none,

pointer_op: PointerOp = .none,

pointer_pos: utils.Pos = .{},
/// State consumed in manage phase, reset at end of manage().
pending_manage: PendingManage = .{},

link: wl.list.Link,

// Pointer bindings for interactive move/resize
move_pointer_binding: ?*river.PointerBindingV1 = null,
resize_pointer_binding: ?*river.PointerBindingV1 = null,

pub const Focused = struct {
    /// We do not allow focus without an output
    /// If there is no output to focus, then Seat.focused itself should be null.
    output: *Output,

    /// We *do* allow focusing an output without a window
    window: ?*Window,
};

// We just steal the Event's tag type to use as our enum. If another event is added
// that's *not* for focus, we'll have to create our own enum and just keep it in sync.
pub const LayerFocus = @typeInfo(river.LayerShellSeatV1.Event).@"union".tag_type.?;

const PendingManage = struct {
    focus: ?PendingFocus = null,
    layer_focus: ?LayerFocus = null,
    should_warp_pointer: bool = false,

    op_delta: ?struct { dx: i32, dy: i32 } = null,
    op_released: bool = false,
    pointer_move_request: ?*Window = null,
    pointer_resize_request: ?struct { window: *Window, edges: river.WindowV1.Edges } = null,

    const PendingFocus = union(enum) {
        clear,
        focus: Focused,
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
    var seat = try utils.gpa.create(Seat);
    errdefer utils.gpa.destroy(seat);

    seat.* = .{
        .context = context,
        .river_seat_v1 = river_seat_v1,
        .river_layer_shell_seat_v1 = try context.river_layer_shell_v1.getSeat(river_seat_v1),
        .link = undefined, // Handled by the wl.list
    };

    seat.river_seat_v1.setListener(*Seat, seatListener, seat);
    seat.river_layer_shell_seat_v1.setListener(*Seat, riverLayerShellSeatListener, seat);

    seat.setXcursorTheme();

    return seat;
}

pub fn destroy(seat: *Seat) void {
    if (seat.move_pointer_binding) |binding| binding.destroy();
    if (seat.resize_pointer_binding) |binding| binding.destroy();
    seat.river_seat_v1.destroy();
    seat.river_layer_shell_seat_v1.destroy();
    seat.link.remove();
    utils.gpa.destroy(seat);
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
        // We reverted clearing focus on .pointer_leave (introduced in ed72d8a). Clearing focus here
        // causes popups to dismiss themselves when the parent window loses focus as the pointer
        // moves toward them. Reverting ed72d8a actually makes this behavior match river-classic's
        // focus_follows_cursor
        .pointer_leave => {},
        .window_interaction => |ev| seat.setWindowFocus(ev.window),
        .op_delta => |ev| {
            seat.pending_manage.op_delta = .{ .dx = ev.dx, .dy = ev.dy };
        },
        .op_release => {
            seat.pending_manage.op_released = true;
        },
        .pointer_position => |ev| {
            seat.pointer_pos.x = ev.x;
            seat.pointer_pos.y = ev.y;

            // We use this to track if the cursor is moving to a new output
            if (seat.context.config.output_focus_follows_pointer) blk: {
                const focused = seat.focused orelse break :blk;
                if (utils.isPosInRect(seat.pointer_pos, focused.output.geometry)) {
                    // Same output, skip
                    break :blk;
                }

                // Check if we already have a focus update pending for this output
                if (seat.pending_manage.focus) |pending_focus| {
                    if (utils.isPosInRect(seat.pointer_pos, pending_focus.focus.output.geometry)) {
                        // We do, skip
                        break :blk;
                    }
                }

                // New output, find which one the pointer is in
                var it = seat.context.wm.outputs.iterator(.forward);
                while (it.next()) |output| {
                    if (output != focused.output and
                        utils.isPosInRect(seat.pointer_pos, output.geometry))
                    {
                        if (output.findFocusCandidate()) |w| {
                            seat.pending_manage.focus = .{ .focus = .{ .output = output, .window = w } };
                            break;
                        }
                        seat.pending_manage.focus = .{ .focus = .{ .output = output, .window = null } };
                        break;
                    }
                }
            }
        },
        else => {},
    }
}

fn riverLayerShellSeatListener(river_layer_shell_seat_v1: *river.LayerShellSeatV1, event: river.LayerShellSeatV1.Event, seat: *Seat) void {
    assert(seat.river_layer_shell_seat_v1 == river_layer_shell_seat_v1);
    seat.pending_manage.layer_focus = std.meta.activeTag(event);
}

// river_window_v1 needs to be optional because ev.window is optional
fn setWindowFocus(seat: *Seat, river_window_v1: ?*river.WindowV1) void {
    const wv1 = river_window_v1 orelse return;
    const window: *Window = @ptrCast(@alignCast(wv1.getUserData() orelse {
        log.err("river_window_v1 has no user data", .{});
        return;
    }));
    const output = window.output orelse return;
    seat.pending_manage.focus = .{ .focus = .{ .output = output, .window = window } };
}

pub fn manage(seat: *Seat) void {
    defer seat.pending_manage = .{};

    // Focus events are ignored by the compositor when a layer shell has exclusive focus.
    if (seat.layer_focus != .focus_exclusive) {
        if (seat.pending_manage.focus) |pending_focus| {
            if (seat.focused) |focused| if (focused.window) |window| {
                window.pending_render.focused = false;
            };
            switch (pending_focus) {
                .focus => |focused| {
                    const output_changed = if (seat.focused) |prev| prev.output != focused.output else true;
                    seat.focused = focused;
                    if (output_changed) {
                        focused.output.river_layer_shell_output_v1.setDefault();
                    }
                },
                .clear => seat.focused = null,
            }
            const new_window: ?*Window = if (seat.focused) |focused| focused.window else null;
            if (new_window) |window| {
                seat.focusWindow(window);
            } else {
                seat.river_seat_v1.clearFocus();
            }
            // Bars should redraw because the title (may) have changed
            var it = seat.context.wm.outputs.iterator(.forward);
            while (it.next()) |output| {
                if (output.bar) |*bar| {
                    bar.pending_render.draw = true;
                }
            }
        }
    }

    // Handle layer focus changes after window focus so focused is up to date.
    // This overrides whatever pending_render.focused the window focus block just set.
    if (seat.pending_manage.layer_focus) |layer_focus| {
        seat.layer_focus = layer_focus;
        switch (layer_focus) {
            .focus_exclusive,
            .focus_non_exclusive,
            => {
                if (seat.focused) |focused| if (focused.window) |window| {
                    window.pending_render.focused = false;
                };
            },
            .focus_none => {
                if (seat.focused) |focused| if (focused.window) |window| {
                    seat.focusWindow(window);
                };
            },
        }
    }

    // Focus doesn't change during .focus_exclusive, so pointer shouldn't get warped, either
    if (seat.layer_focus != .focus_exclusive) {
        if (seat.pending_manage.should_warp_pointer) blk: {
            if (seat.context.config.pointer_warp_on_focus_change) {
                const focused = seat.focused orelse break :blk;
                const window = focused.window orelse {
                    log.warn("Trying to warp-on-focus-change without a focused window.", .{});
                    break :blk;
                };
                if (window.needs_position) {
                    // Window is floating and still needs its position set, don't warp.
                    break :blk;
                }
                // Warp pointer to center of focused window;
                // because the x and y coords are set during render, we need to check if
                // there are new coordinates in window.pending_render.
                const pos = window.pending_render.position;
                const pointer_x: i32 = (if (pos) |p| p.x else window.rect.x) + @divFloor(window.rect.width, 2);
                const pointer_y: i32 = (if (pos) |p| p.y else window.rect.y) + @divFloor(window.rect.height, 2);
                seat.river_seat_v1.pointerWarp(pointer_x, pointer_y);
            }
        }
    }

    // Interactive move/resize operations

    // Start move operation
    if (seat.pending_manage.pointer_move_request) |window| {
        if (window.floating) {
            seat.pointer_op = .{
                .move = .{
                    .window = window,
                    .start_x = window.rect.x,
                    .start_y = window.rect.y,
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
                    .start_width = req.window.rect.width,
                    .start_height = req.window.rect.height,
                    .start_x = req.window.rect.x,
                    .start_y = req.window.rect.y,
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
                op.window.pending_render.position = .{
                    .x = op.start_x + delta.dx,
                    .y = op.start_y + delta.dy,
                };
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
                if (op.edges.left) new_x = @min(new_x, op.start_x + @as(i32, op.start_width) - min_size);
                if (op.edges.top) new_y = @min(new_y, op.start_y + @as(i32, op.start_height) - min_size);
                new_width = @max(new_width, min_size);
                new_height = @max(new_height, min_size);

                op.window.river_window_v1.proposeDimensions(
                    @intCast(new_width),
                    @intCast(new_height),
                );
                op.window.pending_render.position = .{
                    .x = new_x,
                    .y = new_y,
                };
            },
        }
    }

    // Process pointer release (end of operation)
    if (seat.pending_manage.op_released) {
        switch (seat.pointer_op) {
            .none => {},
            .move => |op| {
                seat.river_seat_v1.opEnd();
                seat.pointer_op = .none;
                // Iterate over every display and check if the curser is inside it
                var it = seat.context.wm.outputs.iterator(.forward);
                while (it.next()) |output| {
                    if (utils.isPosInRect(seat.pointer_pos, output.geometry)) {
                        // We have to remove window from current output's windows list first
                        op.window.link.remove();
                        output.windows.append(op.window);

                        seat.pending_manage.focus = .{ .focus = .{ .output = output, .window = op.window } };
                        op.window.pending_manage.pending_output = .{ .output = output };
                        break;
                    }
                }
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

pub fn setXcursorTheme(seat: *Seat) void {
    const cursor = seat.context.config.cursor orelse return;
    seat.river_seat_v1.setXcursorTheme(cursor.theme, cursor.size);
}

pub fn movePointerBindingListener(_: *river.PointerBindingV1, event: river.PointerBindingV1.Event, seat: *Seat) void {
    switch (event) {
        .pressed => {
            const focused = seat.focused orelse return;
            const window = focused.window orelse return;
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
            const focused = seat.focused orelse return;
            const window = focused.window orelse return;
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

fn focusWindow(seat: *Seat, window: *Window) void {
    seat.river_seat_v1.focusWindow(window.river_window_v1);
    window.pending_render.focused = true;
    if (window.output) |output| {
        // Push the window to focus history
        window.focus_link.remove();
        output.focus_history.prepend(window);
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
