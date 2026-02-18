// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Window = @This();

context: *Context,

river_window_v1: *river.WindowV1,
river_node_v1: *river.NodeV1,

app_id: ?[]const u8 = null,
title: ?[]const u8 = null,
parent: ?*river.WindowV1 = null,

rect: utils.Rect = .{},

fullscreen: bool = false,
maximized: bool = false,

tags: u32 = 0x0001,
output: ?*Output,

floating: bool = false,
floating_rect: utils.Rect = .{},
dimensions_hint: DimensionsHint = .{},

initialized: bool = false,

/// State consumed in manage() phase, reset at end of manage().
pending_manage: PendingManage = .{},

/// State consumed in render() phase, reset at end of render().
pending_render: PendingRender = .{},

/// Used to put Windows into a list in calculatePrimaryStackLayout()
active_list_node: DoublyLinkedList.Node = .{},

link: wl.list.Link,

pub const PendingManage = struct {
    dimensions: ?struct { width: u31, height: u31 } = null,

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
    position: ?struct {
        x: i32,
        y: i32,
    } = null,

    focused: ?bool = null,

    show: ?bool = null,
};

pub const DimensionsHint = struct {
    min_width: u31 = 0,
    min_height: u31 = 0,
    max_width: u31 = 0,
    max_height: u31 = 0,

    fn preferredWidth(hint: DimensionsHint) ?u31 {
        if (hint.min_width != 0 and hint.max_width != 0)
            // Two separate divisions so we don't overflow the u31
            return hint.min_width / 2 + hint.max_width / 2
        else if (hint.min_width != 0)
            return hint.min_width
        else if (hint.max_width != 0)
            return hint.max_width
        else
            return null;
    }

    fn preferredHeight(hint: DimensionsHint) ?u31 {
        if (hint.min_height != 0 and hint.max_height != 0)
            // Two separate divisions so we don't overflow the u31
            return hint.min_height / 2 + hint.max_height / 2
        else if (hint.min_height != 0)
            return hint.min_height
        else if (hint.max_height != 0)
            return hint.max_height
        else
            return null;
    }
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
    if (window.app_id) |app_id| utils.gpa.free(app_id);
    if (window.title) |title| utils.gpa.free(title);

    window.river_node_v1.destroy();
    window.river_window_v1.destroy();

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
            window.pending_manage.dimensions = .{ .width = @intCast(ev.width), .height = @intCast(ev.height) };
        },
        .dimensions_hint => |ev| {
            window.dimensions_hint = .{
                .min_width = @intCast(ev.min_width),
                .min_height = @intCast(ev.min_height),
                .max_width = @intCast(ev.max_width),
                .max_height = @intCast(ev.max_height),
            };
        },
        .app_id => |ev| {
            if (window.app_id) |app_id| utils.gpa.free(app_id);
            window.app_id = if (ev.app_id) |aid|
                utils.gpa.dupe(u8, std.mem.span(aid)) catch @panic("Out of memory")
            else
                null;
        },
        .title => |ev| {
            if (window.title) |title| utils.gpa.free(title);
            window.title = if (ev.title) |t|
                utils.gpa.dupe(u8, std.mem.span(t)) catch @panic("Out of memory")
            else
                null;
        },
        .parent => |ev| {
            const parent = ev.parent orelse return;
            window.parent = parent;

            // Make window float on top of its parent
            window.pending_manage.floating = true;
            const parent_window: *Window = @ptrCast(@alignCast(parent.getUserData() orelse return));
            window.pending_render.position = .{
                .x = parent_window.rect.x + @divTrunc(parent_window.rect.width, 2),
                .y = parent_window.rect.y + @divTrunc(parent_window.rect.height, 2),
            };
        },
        else => |ev| {
            log.debug("unhandled event: {s}", .{@tagName(ev)});
        },
    }
}

/// Apply one-time initialization for newly created windows.
/// Called before calculatePrimaryStackLayout() so that tag and float
/// rules are reflected in the first frame's layout.
pub fn initialize(window: *Window) void {
    if (window.initialized) {
        @branchHint(.unlikely);
        return;
    }
    window.initialized = true;

    const river_window_v1 = window.river_window_v1;

    // TODO: We might want to think about paying attention to the decoration_hint event
    //       If we do, this would need to move, I think?
    river_window_v1.useSsd();

    river_window_v1.setCapabilities(.{ .fullscreen = true, .maximize = true });
    river_window_v1.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });

    const res = window.applyRules();
    if (res.tags) |tags| window.tags = tags;
    if (res.float) |should_float|
        window.pending_manage.floating = should_float;
}

pub fn manage(window: *Window) void {
    // Updating state since the last manage event
    defer window.pending_manage = .{};
    const pending_manage = window.pending_manage;
    const river_window_v1 = window.river_window_v1;
    // Floating status
    if (pending_manage.floating) |floating| blk: {
        // This needs to be before proposing the new dimensions since we want to save the current ones!
        // Skip the rest of the block if floating matches what is already set
        if (floating == window.floating) break :blk;

        window.floating = floating;
        if (floating) {
            // Let the window know it isn't tiled
            river_window_v1.setTiled(.{});

            if (window.floating_rect.width == 0) {
                // This window has never floated before, let's give it floating dimensions
                // Go with the mid-point of the preferred width/height if the window has one
                // If not, go with 75% of the output's usable size in the same dimension
                if (window.output) |output| {
                    window.floating_rect.width = if (window.dimensions_hint.preferredWidth()) |w| w else @divFloor(output.usable_geometry.width * 3, 4);
                    window.floating_rect.height = if (window.dimensions_hint.preferredHeight()) |h| h else @divFloor(output.usable_geometry.height * 3, 4);
                    window.floating_rect.x = output.usable_geometry.x + @divFloor(output.usable_geometry.width, 2) - @divFloor(window.floating_rect.width, 2);
                    window.floating_rect.y = output.usable_geometry.y + @divFloor(output.usable_geometry.height, 2) - @divFloor(window.floating_rect.height, 2);
                } else {
                    window.floating_rect.width = window.rect.width;
                    window.floating_rect.height = window.rect.height;
                }
            }
            river_window_v1.proposeDimensions(window.floating_rect.width, window.floating_rect.height);
            window.pending_render.position = .{
                .x = window.floating_rect.x,
                .y = window.floating_rect.y,
            };
        } else {
            river_window_v1.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
            // Save floating dimensions in case the window gets floated again
            window.floating_rect.width = window.rect.width;
            window.floating_rect.height = window.rect.height;
            window.floating_rect.x = window.rect.x;
            window.floating_rect.y = window.rect.y;
        }
    }
    // Layout (pre-computed by WindowManager.caluclateLayout())
    if (pending_manage.dimensions) |dimensions| {
        window.rect.width = dimensions.width;
        window.rect.height = dimensions.height;
        window.river_window_v1.proposeDimensions(dimensions.width, dimensions.height);
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

    if (window.pending_render.position) |position| {
        window.rect.x = position.x;
        window.rect.y = position.y;
        window.river_node_v1.setPosition(window.rect.x, window.rect.y);
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

// Iterate over all window rules and apply any that match.
// Later rules in the list overwrite earlier ones.
fn applyRules(window: *Window) struct {
    float: ?bool = null,
    tags: ?u32 = null,
} {
    var float: ?bool = null;
    var tags: ?u32 = null;
    for (window.context.config.window_rules.items) |rule| {
        const app_id_matches = if (rule.app_id_glob) |glob|
            if (window.app_id) |app_id| globber.match(app_id, glob) else false
        else
            true;
        const title_matches = if (rule.title_glob) |glob|
            if (window.title) |title| globber.match(title, glob) else false
        else
            true;
        if (app_id_matches and title_matches) {
            switch (rule.action) {
                .float => |should_float| float = should_float,
                .tags => |tagmask| tags = tagmask,
            }
        }
    }

    return .{
        .float = float,
        .tags = tags,
    };
}

const std = @import("std");
const assert = std.debug.assert;
const DoublyLinkedList = std.DoublyLinkedList;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const globber = @import("globber.zig");
const utils = @import("utils.zig");
const Context = @import("Context.zig");
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const WindowRule = @import("Config.zig").WindowRule;

const log = std.log.scoped(.Window);
