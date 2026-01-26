// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Window = @This();

context: *Context,

window_v1: *river.WindowV1,
node_v1: *river.NodeV1,

width: u31 = 0,
height: u31 = 0,
x: i32 = 0,
y: i32 = 0,

fullscreen: bool = false,
maximized: bool = false,

initialized: bool = false,

/// State consumed in manage() phase, reset at end of manage().
pending_manage: PendingManage = .{},

/// State consumed in render() phase, reset at end of render().
pending_render: PendingRender = .{},

link: wl.list.Link,

pub const PendingManage = struct {
    width: ?u31 = null,
    height: ?u31 = null,

    fullscreen: ?bool = null,
    maximized: ?bool = null,
};

pub const PendingRender = struct {
    x: ?i32 = null,
    y: ?i32 = null,

    focused: ?bool = null,
};

pub fn init(window: *Window, context: *Context, river_window_v1: *river.WindowV1) void {
    window.* = .{
        .context = context,
        .window_v1 = river_window_v1,
        .node_v1 = river_window_v1.getNode() catch @panic("Failed to get node"),
        .link = undefined, // Handled by the wl.list
    };

    window.window_v1.setListener(*Window, windowListener, window);
}

fn windowListener(river_window_v1: *river.WindowV1, event: river.WindowV1.Event, window: *Window) void {
    assert(window.window_v1 == river_window_v1);
    switch (event) {
        .closed => {
            river_window_v1.destroy();
            window.node_v1.destroy();
            window.context.wm.window_count -= 1;
            {
                var it = window.context.wm.seats.iterator(.forward);
                while (it.next()) |seat| {
                    if (seat.focused == window) {
                        // Find another window to focus and warp pointer there
                        if (window.context.wm.getPrevWindow(window)) |next_focus| {
                            if (next_focus != window) {
                                seat.pending_manage.pending_focus = .{ .window = next_focus };
                                seat.pending_manage.should_warp_pointer = true;
                            } else {
                                // Only window in list - clear focus
                                seat.pending_manage.pending_focus = .clear_focus;
                            }
                        } else {
                            seat.pending_manage.pending_focus = .clear_focus;
                        }
                    }
                }
            }
            window.link.remove();
            utils.allocator.destroy(window);
        },
        .dimensions => |ev| {
            // The protocol requires these are strictly greather than zero.
            assert(ev.width > 0 and ev.height > 0);
            window.width = @intCast(ev.width);
            window.height = @intCast(ev.height);
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
    if (!window.initialized) {
        @branchHint(.unlikely);
        window.initialized = true;

        // TODO: We might want to think about paying attention to the decoration_hint event
        //       If we do, this would need to move, I think?
        window.window_v1.useSsd();

        window.window_v1.setCapabilities(.{ .fullscreen = true, .maximize = true });
        window.window_v1.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
    }

    // Any new state since the last manage event
    defer window.pending_manage = .{};
    const pending_manage = window.pending_manage;
    // Layout (pre-computed by WindowManager.calculatePrimaryStackLayout())
    if (pending_manage.width) |new_width| {
        if (pending_manage.height) |new_height| {
            window.width = new_width;
            window.height = new_height;
            window.window_v1.proposeDimensions(new_width, new_height);
        }
    }

    // Fullscreen and maximize operations
    if (pending_manage.fullscreen) |fullscreen| {
        window.fullscreen = fullscreen;
        if (fullscreen) {
            const output = window.context.wm.outputs.first() orelse @panic("Failed to get output");
            window.window_v1.fullscreen(output.output_v1);
            window.window_v1.informFullscreen();
        } else {
            window.window_v1.exitFullscreen();
            window.window_v1.informNotFullscreen();
        }
    }
    if (pending_manage.maximized) |maximized| {
        window.maximized = maximized;
        if (maximized) {
            window.window_v1.informMaximized();
        } else {
            window.window_v1.informUnmaximized();
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

            window.node_v1.setPosition(window.x, window.y);
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
}

fn applyBorders(window: *Window, color: utils.RiverColor) void {
    const border_width = window.context.config.border_width;
    const all_sides = river.WindowV1.Edges{ .top = true, .bottom = true, .left = true, .right = true };
    window.window_v1.setBorders(all_sides, border_width, color.red, color.green, color.blue, color.alpha);
}

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("Context.zig");

const log = std.log.scoped(.Window);
