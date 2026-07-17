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

/// Preferred presentation mode for this window
///
/// If any visible Window on an output has `presentation_mode == .async`, that Output will be async.
presentation_mode: PresentationMode = .vsync,

floating: bool = false,
floating_rect: utils.Rect = .{},
dimensions_hint: DimensionsHint = .{},

/// Whether or not the window needs its position set
///
/// Right now, this is only used when windows are made floating by a rule but don't have their
/// dimensions set yet. We need their dimensions to be able to center them properly, so we have
/// to wait for that event.
///
/// This can't be part of PendingManage because it lasts between manage cycles.
needs_position: bool = false,

initialized: bool = false,

/// State consumed in manage() phase, reset at end of manage().
pending_manage: PendingManage = .{},

/// State consumed in render() phase, reset at end of render().
pending_render: PendingRender = .{},

/// Used to put Windows into a list when calculating the layout
active_list_node: DoublyLinkedList.Node = .{},

link: wl.list.Link,
focus_link: wl.list.Link,

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

const PendingRender = struct {
    position: ?struct { x: i32, y: i32 } = null,

    focused: ?bool = null,

    show: ?bool = null,

    // This could probably be a tagged union and just take *where* to place it (for above/below)
    place_top: bool = false,
};

const DimensionsHint = struct {
    min_width: u31 = 0,
    min_height: u31 = 0,
    max_width: u31 = 0,
    max_height: u31 = 0,

    fn clampWidth(hint: DimensionsHint, width: u31) u31 {
        return math.clamp(
            width,
            if (hint.min_width != 0) hint.min_width else 1,
            if (hint.max_width != 0) hint.max_width else math.maxInt(u31),
        );
    }

    fn clampHeight(hint: DimensionsHint, height: u31) u31 {
        return math.clamp(
            height,
            if (hint.min_height != 0) hint.min_height else 1,
            if (hint.max_height != 0) hint.max_height else math.maxInt(u31),
        );
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
        .focus_link = undefined, // Handled by the wl.list
        // Ensure borders are applied on the first render cycle, even for windows that
        // are never explicitly told they are unfocused (e.g. on WM restart).
        .pending_render = .{ .focused = false },
    };

    // focus_link must be initialized explicitly, because a window may exist
    // without being in focus_history list
    window.focus_link.init();

    window.river_window_v1.setListener(*Window, windowListener, window);

    return window;
}

pub fn destroy(window: *Window) void {
    if (window.app_id) |app_id| utils.gpa.free(app_id);
    if (window.title) |title| utils.gpa.free(title);

    window.river_node_v1.destroy();
    window.river_window_v1.destroy();

    window.link.remove();
    window.focus_link.remove();
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
            window.removeFocus();

            window.destroy();
        },
        .dimensions => |ev| {
            window.pending_manage.dimensions = .{ .width = @intCast(ev.width), .height = @intCast(ev.height) };

            if (!window.needs_position) return;

            if (window.output) |output| {
                window.needs_position = false;

                var x_offset: i32 = (output.geometry.x + output.geometry.width / 2);
                var y_offset: i32 = (output.geometry.y + output.geometry.height / 2);
                if (window.parent) |parent| {
                    const parent_window: *Window = @ptrCast(@alignCast(parent.getUserData() orelse return));
                    x_offset = parent_window.rect.x + (parent_window.rect.width / 2);
                    y_offset = parent_window.rect.y + (parent_window.rect.height / 2);
                }

                window.floating_rect.x = x_offset - @divFloor(ev.width, 2);
                window.floating_rect.y = y_offset - @divFloor(ev.height, 2);
                window.floating_rect.width = @intCast(ev.width);
                window.floating_rect.height = @intCast(ev.height);
                window.pending_render.position = .{
                    .x = window.floating_rect.x,
                    .y = window.floating_rect.y,
                };
            }
        },
        .dimensions_hint => |ev| {
            window.dimensions_hint = .{
                .min_width = @intCast(ev.min_width),
                .min_height = @intCast(ev.min_height),
                .max_width = @intCast(ev.max_width),
                .max_height = @intCast(ev.max_height),
            };
            const dims = &window.dimensions_hint;
            if (dims.max_width > 0 and
                dims.max_height > 0 and
                dims.min_width == dims.max_width and
                dims.min_height == dims.max_height)
            {
                // auto-float a window with static size
                window.pending_manage.floating = true;
            }
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

            // Need to update the bar if this window is focused
            if (window.context.wm.seats.first()) |seat| {
                if (seat.focused) |focused| if (focused.window == window) {
                    if (window.output) |output| {
                        if (output.bar) |*bar| {
                            bar.pending_render.draw = true;
                        }
                    }
                };
            }
        },
        .parent => |ev| {
            // Nothing to do if ev.parent is null
            const parent = ev.parent orelse return;
            window.parent = parent;
        },
        .fullscreen_requested => |ev| {
            window.pending_manage.fullscreen = true;

            // This event allows the window to provide an output preference,
            // so we should move the window if it wants
            if (ev.output) |river_output_v1| {
                if (river_output_v1.getUserData()) |user_data| {
                    const output: *Output = @ptrCast(@alignCast(user_data));
                    // We have to remove window from current output's windows list first
                    window.link.remove();
                    output.windows.append(window);

                    window.pending_manage.pending_output = .{ .output = output };
                }
            }
        },
        .exit_fullscreen_requested => window.pending_manage.fullscreen = false,
        else => |ev| {
            log.debug("unhandled event: {s}", .{@tagName(ev)});
        },
    }
}

/// Apply one-time initialization for newly created windows.
/// Called before calculatePrimaryStackLayout() so that tag and float
/// rules are reflected in the first frame's layout.
///
/// Must only be called once per Window.
pub fn initialize(window: *Window) void {
    assert(!window.initialized);
    window.initialized = true;

    const river_window_v1 = window.river_window_v1;

    // TODO: We might want to think about paying attention to the decoration_hint event
    //       If we do, this would need to move, I think?
    river_window_v1.useSsd();

    river_window_v1.setCapabilities(.{ .fullscreen = true, .maximize = true });
    river_window_v1.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });

    if (window.parent != null) {
        window.pending_manage.floating = true;
    }

    const res = window.applyRules();
    if (res.tags) |tags| {
        window.pending_manage.tags = tags;
    }
    if (res.float) |should_float| {
        window.pending_manage.floating = should_float;
    }
    if (res.presentation_mode) |presentation_mode| {
        window.presentation_mode = presentation_mode;
    }
    if (res.output) |output| {
        window.sendToOutput(output);
    }
}

pub fn manage(window: *Window) void {
    // Updating state since the last manage event
    defer window.pending_manage = .{};
    const pending_manage = window.pending_manage;
    const river_window_v1 = window.river_window_v1;
    // Floating status
    var became_floating = false;
    if (pending_manage.floating) |floating| blk: {
        // This needs to be before proposing the new dimensions since we want to save the current ones!
        // Skip the rest of the block if floating matches what is already set
        if (floating == window.floating) break :blk;

        window.floating = floating;
        if (floating) {
            became_floating = true;
            // Let the window know it isn't tiled
            river_window_v1.setTiled(.{});

            if (window.floating_rect.width == 0) {
                // This window has never floated before, let's give it floating dimensions.
                // Use 75% of the output's usable size, clamped to the window's dimension hints.
                if (window.output) |output| {
                    if (window.rect.width == 0) {
                        if (window.pending_manage.dimensions) |dimensions| {
                            // TODO: Is it even possible to make it in here?
                            // We want to center the output; this works even if the proposed dimensions
                            // are 0 since the dimensions are the numerator, the window just wouldn't
                            // be centered.
                            window.pending_render.position = .{
                                .x = (output.geometry.width / 2) - (dimensions.width / 2),
                                .y = (output.geometry.height / 2) - (dimensions.height / 2),
                            };
                        } else {
                            // The window didn't even *exist* before, i.e. we only got here via a floating window rule,
                            // so just let it choose its own dimensions.
                            river_window_v1.proposeDimensions(0, 0);
                            window.needs_position = true;
                        }
                        break :blk;
                    }
                    window.floating_rect.width = window.dimensions_hint.clampWidth(@divFloor(output.usable_geometry.width * 3, 4));
                    window.floating_rect.height = window.dimensions_hint.clampHeight(@divFloor(output.usable_geometry.height * 3, 4));
                    window.floating_rect.x = output.usable_geometry.x + @divFloor(output.usable_geometry.width, 2) - @divFloor(window.floating_rect.width, 2);
                    window.floating_rect.y = output.usable_geometry.y + @divFloor(output.usable_geometry.height, 2) - @divFloor(window.floating_rect.height, 2);
                } else {
                    // This should not be reachable because focus is unset if there are no outputs
                    unreachable;
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
    if (pending_manage.dimensions) |dimensions| {
        window.rect.width = dimensions.width;
        window.rect.height = dimensions.height;
        if (!became_floating) {
            // We want to skip this if the floating block above already proposed dimensions
            window.river_window_v1.proposeDimensions(dimensions.width, dimensions.height);
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
            // We need to do this so the window appears on top of the bar
            window.pending_render.place_top = true;
            window.pending_render.position = .{
                .x = output.usable_geometry.x,
                .y = output.usable_geometry.y,
            };
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
    if (pending_manage.tags) |tags| {
        window.tags = tags;
        if (window.output) |o| {
            if (o.tags & window.tags == 0) {
                // This window isn't visible anymore, we need to move focus off it
                window.removeFocus();
            }
        }
    }
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

    if (window.pending_render.place_top) {
        window.river_node_v1.placeTop();
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
    float: ?bool,
    tags: ?u32,
    presentation_mode: ?PresentationMode,
    output: ?*Output,
} {
    var float: ?bool = null;
    var tags: ?u32 = null;
    var presentation_mode: ?PresentationMode = null;
    var output: ?*Output = null;
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
                .presentation_mode => |mode| presentation_mode = mode,
                .output => |new_output| output = window.context.wm.outputFromName(new_output),
            }
        }
    }

    return .{
        .float = float,
        .tags = tags,
        .presentation_mode = presentation_mode,
        .output = output,
    };
}

/// Send window to a new output. Requires that the window is currently on an
/// output AND that the output is currently focused on the first seat.
pub fn sendToOutput(window: *Window, output: *Output) void {
    const context = window.context;
    const wm = context.wm;
    const seat = wm.seats.first() orelse return;

    const current_output = if (seat.focused) |focused| focused.output else return;

    window.link.remove();
    // Remove from the source output's focus history and reset to sentinel state.
    // Without the re-init, focusWindow and destroy would panic calling remove() on
    // the now-null link before the window is re-added to the destination's history.
    {
        window.focus_link.remove();
        window.focus_link.init();
    }
    output.windows.append(window);

    window.pending_manage.pending_output = .{ .output = output };

    const follow_window = switch (context.config.focus_on_send) {
        .always, .always_or => true,
        .if_visible => output.tags & window.tags != 0,
        .never => false,
    };

    if (window.floating) {
        // Make sure floating windows have their position properly set to be on
        // the new output to prevent focus desync.
        window.pending_render.position = .{
            .x = output.geometry.x + window.floating_rect.x,
            .y = output.geometry.y + window.floating_rect.y,
        };
    }

    if (follow_window) {
        seat.pending_manage.focus = .{ .focus = .{ .output = output, .window = window } };
        seat.pending_manage.should_warp_pointer = true;
        switch (context.config.focus_on_send) {
            .always => if (output.tags & window.tags == 0) {
                // Focus is following the window, but it wouldn't be visible, so we're
                // going to OR the window's tags onto the output
                output.pending_manage.tags = output.tags | window.tags;
            },
            .always_or => {
                const new_tags = output.tags | window.tags;
                if (new_tags != output.tags) {
                    // Focus is following the window and the window has tags that aren't
                    // active on the new output so let's OR them in
                    output.pending_manage.tags = new_tags;
                }
            },
            else => {},
        }
    } else {
        // Focus isn't following, so we need to find a fallback on the current output
        if (current_output.findFocusCandidate()) |w| {
            seat.pending_manage.focus = .{ .focus = .{ .output = current_output, .window = w } };
            seat.pending_manage.should_warp_pointer = true;
        } else {
            seat.pending_manage.focus = .{ .focus = .{ .output = current_output, .window = null } };
        }
    }
}

/// Removes this window from all seat focus state. If a seat had this window focused
/// or queued as pending focus, redirects it to the next window instead.
fn removeFocus(window: *Window) void {
    var it = window.context.wm.seats.iterator(.forward);
    while (it.next()) |seat| {
        const is_focused = if (seat.focused) |focused| focused.window == window else false;
        if (is_focused) {
            // Need to clear focused.window to prevent the use-after-free seen in #20
            seat.focused.?.window = null;
            window.assignNextFocus(seat);
            seat.pending_manage.should_warp_pointer = true;
        } else if (seat.pending_manage.focus) |pending_focus| {
            // This window isn't focused yet, but a previous window was closed in the same
            // dispatch cycle and set this one as the pending focus. We need to skip to the next.
            switch (pending_focus) {
                .focus => |focused| if (focused.window == window) {
                    window.assignNextFocus(seat);
                },
                .clear => {},
            }
        }
    }
}

/// Sets seat.pending_manage.focus.window to the next visible window on this window's output,
/// or clears window focus if there are no windows.
fn assignNextFocus(window: *Window, seat: *Seat) void {
    const output = window.output orelse {
        seat.pending_manage.focus = .clear;
        return;
    };
    const next = if (window.context.config.focus_next_direction == .prev)
        output.prevWindow(window)
    else
        output.nextWindow(window);
    // next == window means this was the only visible window, so clear window focus but keep output focus
    const next_window: ?*Window = blk: {
        const w = next orelse break :blk null;
        break :blk if (w != window) w else null;
    };
    seat.pending_manage.focus = .{ .focus = .{ .output = output, .window = next_window } };
}

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const DoublyLinkedList = std.DoublyLinkedList;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const PresentationMode = river.OutputV1.PresentationMode;

const globber = @import("globber.zig");
const utils = @import("utils.zig");
const Context = @import("Context.zig");
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const WindowRule = @import("Config.zig").WindowRule;

const log = std.log.scoped(.Window);
