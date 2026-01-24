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

new_width: u31 = 0,
new_height: u31 = 0,
new_x: i32 = 0,
new_y: i32 = 0,

initialized: bool = false,

is_fullscreen: bool = false,
is_maximized: bool = false,

// Maybe this should be separate for each type of action so it can't be overwritten ?
pending_action: ?PendingAction = null,

link: wl.list.Link,

pub const PendingAction = enum {
    enter_fullscreen,
    exit_fullscreen,
    maximize,
    unmaximize,
};

pub fn init(window: *Window, context: *Context, river_window_v1: *river.WindowV1) void {
    window.* = .{
        .context = context,
        .window_v1 = river_window_v1,
        .node_v1 = river_window_v1.getNode() catch @panic("failed to get node"),
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
                        seat.focused = null;
                    }
                }
            }
            window.link.remove();
            window.context.allocator.destroy(window);
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
    defer window.pending_action = null;
    defer window.new_width = 0;
    defer window.new_height = 0;

    if (!window.initialized) {
        @branchHint(.unlikely);
        window.initialized = true;

        // Use server-side decoration (no client-drawn title bars)
        // TODO: We might want a way to handle clients requesting CSD (or switching between
        // CSD and SSD)
        window.window_v1.useSsd();

        window.window_v1.setCapabilities(.{ .fullscreen = true });
    }

    // Layout has been pre-computed by WindowManager.calculatePrimaryStackLayout()
    // Apply the computed dimensions
    if (window.new_width > 0 and window.new_height > 0) {
        window.window_v1.proposeDimensions(window.new_width, window.new_height);
    }

    if (window.pending_action) |pending_action| {
        switch (pending_action) {
            .enter_fullscreen => {
                window.window_v1.setTiled(.{});
                // TODO: Figure out what output this Window is on?
                const output = window.context.wm.outputs.first() orelse return;
                window.window_v1.fullscreen(output.output_v1);
                window.window_v1.informFullscreen();

                window.is_fullscreen = true;
            },
            .exit_fullscreen => {
                window.window_v1.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
                window.window_v1.exitFullscreen();
                window.window_v1.informNotFullscreen();

                window.is_fullscreen = false;
            },
            .maximize => {
                window.window_v1.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
                window.window_v1.informMaximized();

                window.is_maximized = true;
            },
            .unmaximize => {
                window.window_v1.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
                window.window_v1.informUnmaximized();

                window.is_maximized = false;
            },
        }
    }
    // }
}

pub fn render(window: *Window) void {
    // Set the window position using the pre-computed layout
    window.node_v1.setPosition(window.new_x, window.new_y);

    // Set borders
    if (!window.is_fullscreen) {
        const border_width = window.context.config.border_width;
        if (window.isFocused()) {
            const border_color_focused = window.context.config.border_color_focused;
            window.window_v1.setBorders(.{ .top = true, .bottom = true, .left = true, .right = true }, border_width, border_color_focused.red, border_color_focused.green, border_color_focused.blue, border_color_focused.alpha);
        } else {
            const border_color_unfocused = window.context.config.border_color_unfocused;
            window.window_v1.setBorders(.{ .top = true, .bottom = true, .left = true, .right = true }, border_width, border_color_unfocused.red, border_color_unfocused.green, border_color_unfocused.blue, border_color_unfocused.alpha);
        }
    }
}

fn isFocused(window: *Window) bool {
    // Probably a better way to do this... keep currently focused window directly in context?
    // Regardless, we only have one Seat so this shouldn't be awful performance-wise
    var it = window.context.wm.seats.iterator(.forward);
    while (it.next()) |seat| {
        if (seat.focused == window) {
            return true;
        }
    }
    return false;
}

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Context = @import("main.zig").Context;

const log = std.log.scoped(.Window);
