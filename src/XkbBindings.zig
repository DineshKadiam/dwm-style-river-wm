// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const XkbBindings = @This();

pub const Command = union(enum) {
    spawn: []const []const u8,
    focus_next_window,
    focus_prev_window,
    focus_next_output,
    focus_prev_output,
    send_to_next_output,
    send_to_prev_output,
    zoom,
    toggle_float,
    // Changes the ratio on the focused output only
    change_ratio: f32,
    // Changes the primary count on the focus output only
    increment_primary_count,
    decrement_primary_count,
    reload_config,
    toggle_fullscreen,
    close_window,
    // Tag management
    set_output_tags: u32,
    set_window_tags: u32,
    toggle_output_tags: u32,
    toggle_window_tags: u32,
    // Move floating window by pixels
    move_up: i32,
    move_down: i32,
    move_left: i32,
    move_right: i32,

    // Resize floating window by pixels
    resize_width: i32,
    resize_height: i32,

    // Center floating window on its output
    center_float,

    // Swap window position in stack
    swap_next,
    swap_prev,

    // When passthrough is enabled, only keybinds set to toggle_passthrough are active
    toggle_passthrough,

    /// Explicitly list each variant so that, if we add a new one,
    /// we'll get a reminder to free it here (instead of it being
    /// swallowed by an `else =>`)
    pub fn deinit(self: Command) void {
        switch (self) {
            .spawn => |argv| {
                for (argv) |arg| utils.gpa.free(arg);
                utils.gpa.free(argv);
            },
            .focus_next_window,
            .focus_prev_window,
            .focus_next_output,
            .focus_prev_output,
            .send_to_next_output,
            .send_to_prev_output,
            .zoom,
            .toggle_float,
            .change_ratio,
            .increment_primary_count,
            .decrement_primary_count,
            .reload_config,
            .toggle_fullscreen,
            .close_window,
            .set_output_tags,
            .set_window_tags,
            .toggle_output_tags,
            .toggle_window_tags,
            .move_up,
            .move_down,
            .move_left,
            .move_right,
            .resize_width,
            .resize_height,
            .center_float,
            .swap_next,
            .swap_prev,
            .toggle_passthrough,
            => {},
        }
    }
};

const XkbBinding = struct {
    xkb_binding_v1: *river.XkbBindingV1,
    command: Command,
    context: *Context,
    link: wl.list.Link,

    const FocusDirection = enum { next, prev };

    fn create(xkb_binding_v1: *river.XkbBindingV1, command: Command, context: *Context) !*XkbBinding {
        var xkb_binding = try utils.gpa.create(XkbBinding);
        errdefer utils.gpa.destroy(xkb_binding);

        xkb_binding.* = .{
            .xkb_binding_v1 = xkb_binding_v1,
            .command = command,
            .context = context,
            .link = undefined, // Handled by the wl.list
        };

        xkb_binding.xkb_binding_v1.setListener(*XkbBinding, xkbBindingListener, xkb_binding);

        return xkb_binding;
    }

    pub fn destroy(xkb_binding: *XkbBinding) void {
        xkb_binding.xkb_binding_v1.destroy();
        utils.gpa.destroy(xkb_binding);
    }

    fn xkbBindingListener(river_xkb_binding_v1: *river.XkbBindingV1, event: river.XkbBindingV1.Event, xkb_binding: *XkbBinding) void {
        assert(xkb_binding.xkb_binding_v1 == river_xkb_binding_v1);
        switch (event) {
            .pressed => {
                xkb_binding.executeCommand();
            },
            .released => {},
            else => |ev| {
                log.debug("unhandled event: {s}", .{@tagName(ev)});
            },
        }
    }

    fn executeCommand(xkb_binding: *XkbBinding) void {
        const context = xkb_binding.context;

        const first_seat = context.wm.seats.first() orelse null;

        // TODO: Should I log.warn when commands return early?
        switch (xkb_binding.command) {
            .spawn => |cmd| {
                var child = std.process.Child.init(cmd, utils.gpa);
                _ = child.spawn() catch |err| {
                    log.err("Failed to spawn \"{s}\": {}", .{ cmd[0], err });
                };
            },
            .focus_next_window => focusWindow(context, .next),
            .focus_prev_window => focusWindow(context, .prev),
            .focus_next_output => focusOutput(context, .next),
            .focus_prev_output => focusOutput(context, .prev),
            .send_to_next_output => sendWindowToOutput(context, .next),
            .send_to_prev_output => sendWindowToOutput(context, .prev),
            .zoom => {
                const seat = first_seat orelse return;
                const current_focus = if (seat.pending_manage.window) |pending_focus| blk: {
                    switch (pending_focus) {
                        .clear_focus => return,
                        .window => |window| break :blk window,
                    }
                } else seat.focused_window orelse return;

                // Noop if the focused window is floating
                if (current_focus.floating) return;

                // Get the first tiled window to try zoom with
                // If the first window is focused, we instead try to get the second tiled window
                const output = current_focus.output orelse {
                    log.warn("Focused window has no output during zoom", .{});
                    return;
                };
                var focus_is_first_tiled = false;
                const first_tiled: *Window = blk: {
                    var it = output.windows.iterator(.forward);
                    while (it.next()) |window| {
                        if (window.floating or output.tags & window.tags == 0) continue;
                        if (window == current_focus) {
                            focus_is_first_tiled = true;
                            continue;
                        }
                        break :blk window;
                    }
                    // No (or only one) visible tiled windows, nothing to do
                    return;
                };

                current_focus.link.swapWith(&first_tiled.link);
                // Update focus
                seat.pending_manage.window = .{ .window = current_focus };
                // Warp pointer when the focused window is promoted to primary
                if (!focus_is_first_tiled) {
                    seat.pending_manage.should_warp_pointer = true;
                }
            },
            .toggle_float => {
                const seat = first_seat orelse return;
                const window = seat.focused_window orelse return;
                // Noop if the window is fullscreened
                if (window.fullscreen) return;
                window.pending_manage.floating = !window.floating;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .change_ratio => |diff| {
                const seat = first_seat orelse return;
                const output = seat.focused_output orelse return;
                output.pending_manage.primary_ratio = output.primary_ratio + diff;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .increment_primary_count => {
                const seat = first_seat orelse return;
                const output = seat.focused_output orelse return;
                output.pending_manage.primary_count = output.primary_count + 1;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .decrement_primary_count => {
                const seat = first_seat orelse return;
                const output = seat.focused_output orelse return;
                output.pending_manage.primary_count = output.primary_count - 1;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .reload_config => {
                // Try create new config
                const new_config = Config.create() catch {
                    // We do this so that, if the Config fails to reload, the
                    // user still has *some* config.
                    log.err("Failed to reload Config. Not deleting old one", .{});
                    return;
                };
                if (context.pending_manage.config) |old_pending| {
                    // Need to prevent memory leaks in case multiple reloads are sent before a manage
                    old_pending.destroy();
                }
                // Send the config to the WM to handle during next manage
                context.pending_manage.config = new_config;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .toggle_fullscreen => {
                const seat = first_seat orelse return;
                const window = seat.focused_window orelse return;
                window.pending_manage.fullscreen = !window.fullscreen;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .close_window => {
                const seat = first_seat orelse return;
                if (seat.focused_window) |window| {
                    window.river_window_v1.close();
                }
            },
            .set_output_tags => |tags| {
                const seat = first_seat orelse return;
                const output = seat.focused_output orelse return;
                output.pending_manage.tags = tags;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .set_window_tags => |tags| {
                const seat = first_seat orelse return;
                // TODO: I don't think pending_focus should ever be set at this point?
                // const window = seat.pending_manage.pending_focus orelse seat.focused;
                const window = seat.focused_window orelse return;
                window.pending_manage.tags = tags;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .toggle_output_tags => |tags| {
                const seat = first_seat orelse return;
                const output = seat.focused_output orelse return;
                const old_tags = output.pending_manage.tags orelse output.tags;
                const new_tags = old_tags ^ tags;
                if (new_tags != 0) {
                    output.pending_manage.tags = new_tags;
                    context.wm.river_window_manager_v1.manageDirty();
                }
            },
            .toggle_window_tags => |tags| {
                const seat = first_seat orelse return;
                // TODO: I don't think pending_focus should ever be set at this point?
                // const window = seat.pending_manage.pending_focus orelse seat.focused;
                const window = seat.focused_window orelse return;
                const old_tags = window.pending_manage.tags orelse window.tags;
                const new_tags = old_tags ^ tags;
                if (new_tags != 0) {
                    window.pending_manage.tags = new_tags;
                    context.wm.river_window_manager_v1.manageDirty();
                }
            },
            .move_up => |pixels| moveFloatingWindow(context, 0, -pixels),
            .move_down => |pixels| moveFloatingWindow(context, 0, pixels),
            .move_left => |pixels| moveFloatingWindow(context, -pixels, 0),
            .move_right => |pixels| moveFloatingWindow(context, pixels, 0),
            .resize_width => |delta| resizeFloatingWindow(context, delta, 0),
            .resize_height => |delta| resizeFloatingWindow(context, 0, delta),
            .center_float => centerFloatingWindow(context),
            .swap_next => swapWindow(context, .next),
            .swap_prev => swapWindow(context, .prev),
            .toggle_passthrough => {
                context.xkb_bindings.pending_manage.toggle_passthrough = true;
                context.wm.river_window_manager_v1.manageDirty();
            },
        }
    }

    fn focusWindow(context: *Context, direction: FocusDirection) void {
        const seat = context.wm.seats.first() orelse return;
        const output = seat.focused_output orelse return;
        const pending_focus = if (seat.focused_window) |current| blk: {
            assert(current.output == output);
            break :blk switch (direction) {
                .next => output.nextWindow(current),
                .prev => output.prevWindow(current),
            };
        } else switch (direction) {
            .next => output.windows.first(),
            .prev => output.windows.last(),
        };

        if (pending_focus) |window| {
            seat.pending_manage.window = .{ .window = window };
            seat.pending_manage.should_warp_pointer = true;
        } else {
            seat.pending_manage.window = .clear_focus;
        }
    }

    fn focusOutput(context: *Context, direction: FocusDirection) void {
        const wm = context.wm;
        const seat = wm.seats.first() orelse return;
        if (seat.focused_window) |window| {
            assert(window.output == seat.focused_output);
        }
        const pending_focus = if (seat.focused_output) |current|
            switch (direction) {
                .next => wm.nextOutput(current),
                .prev => wm.prevOutput(current),
            }
        else switch (direction) {
            .next => wm.outputs.first(),
            .prev => wm.outputs.last(),
        };

        if (pending_focus) |output| {
            seat.pending_manage.output = .{ .output = output };

            // We got the new output, but we need to switch window focus, too
            // First tell the old one
            if (seat.focused_window) |current_focus| {
                current_focus.pending_render.focused = false;
            }
            // Then set the new one
            if (output.windows.first()) |window| {
                seat.pending_manage.window = .{ .window = window };
                // Pointer won't warp if window is empty
                seat.pending_manage.should_warp_pointer = true;
            } else {
                // Clear old focus
                seat.pending_manage.window = .clear_focus;
            }
        } else {
            seat.pending_manage.output = .clear_focus;
        }
    }

    fn sendWindowToOutput(context: *Context, direction: FocusDirection) void {
        const wm = context.wm;
        const seat = wm.seats.first() orelse return;
        const window = seat.focused_window orelse return;
        assert(window.output == seat.focused_output);

        const pending_output = if (seat.focused_output) |current|
            switch (direction) {
                .next => wm.nextOutput(current),
                .prev => wm.prevOutput(current),
            }
        else switch (direction) {
            .next => wm.outputs.first(),
            .prev => wm.outputs.last(),
        };

        if (pending_output) |output| {
            // This should be a noop if there's only one output
            if (output != window.output) {
                // We have to remove window from current output's windows list first
                window.link.remove();
                output.windows.append(window);

                seat.pending_manage.output = .{ .output = output };
                seat.pending_manage.should_warp_pointer = true;
                window.pending_manage.pending_output = .{ .output = output };
            }
        }
    }

    fn moveFloatingWindow(context: *Context, dx: i32, dy: i32) void {
        const seat = context.wm.seats.first() orelse return;
        const window = seat.focused_window orelse return;
        if (!window.floating) return;

        window.floating_rect.x += dx;
        window.floating_rect.y += dy;
        window.pending_render.position = .{ .x = window.floating_rect.x, .y = window.floating_rect.y };
        context.wm.river_window_manager_v1.manageDirty();
    }

    fn resizeFloatingWindow(context: *Context, dw: i32, dh: i32) void {
        const seat = context.wm.seats.first() orelse return;
        const window = seat.focused_window orelse return;
        if (!window.floating) return;

        const new_width: i32 = @as(i32, window.floating_rect.width) + dw;
        const new_height: i32 = @as(i32, window.floating_rect.height) + dh;
        window.floating_rect.width = @intCast(@max(50, new_width));
        window.floating_rect.height = @intCast(@max(50, new_height));

        window.pending_manage.dimensions = .{ .width = window.floating_rect.width, .height = window.floating_rect.height };
        context.wm.river_window_manager_v1.manageDirty();
    }

    fn centerFloatingWindow(context: *Context) void {
        const seat = context.wm.seats.first() orelse return;
        const window = seat.focused_window orelse return;
        if (!window.floating) return;
        const output = window.output orelse return;

        window.floating_rect.x = output.usable_geometry.x + @divFloor(output.usable_geometry.width, 2) - @divFloor(window.floating_rect.width, 2);
        window.floating_rect.y = output.usable_geometry.y + @divFloor(output.usable_geometry.height, 2) - @divFloor(window.floating_rect.height, 2);
        window.pending_render.position = .{ .x = window.floating_rect.x, .y = window.floating_rect.y };
        context.wm.river_window_manager_v1.manageDirty();
    }

    fn swapWindow(context: *Context, comptime direction: enum { next, prev }) void {
        const seat = context.wm.seats.first() orelse return;
        const window = seat.focused_window orelse return;
        const output = window.output orelse {
            log.err("focused window has no output during swap", .{});
            return;
        };
        const target = switch (direction) {
            .next => output.nextWindow(window),
            .prev => output.prevWindow(window),
        } orelse return;
        if (target != window) {
            window.link.swapWith(&target.link);
            seat.pending_manage.should_warp_pointer = true;
            context.wm.river_window_manager_v1.manageDirty();
        }
    }
};

context: *Context,

xkb_bindings_v1: *river.XkbBindingsV1,

/// When passthrough_active is true, keybinds (except for passthrough_toggle) are disabled.
passthrough_active: bool = false,

bindings: wl.list.Head(XkbBinding, .link),

pending_manage: PendingManage = .{},

const PendingManage = struct {
    toggle_passthrough: bool = false,
};

pub fn create(context: *Context, xkb_bindings_v1: *river.XkbBindingsV1) !*XkbBindings {
    const xkb_bindings = try utils.gpa.create(XkbBindings);
    errdefer utils.gpa.destroy(xkb_bindings);

    xkb_bindings.* = .{
        .context = context,
        .xkb_bindings_v1 = xkb_bindings_v1,
        .bindings = undefined, // we will initialize this shortly
    };

    xkb_bindings.bindings.init();

    return xkb_bindings;
}

pub fn destroy(xkb_bindings: *XkbBindings) void {
    var it = xkb_bindings.bindings.safeIterator(.forward);
    while (it.next()) |binding| {
        binding.link.remove();
        binding.xkb_binding_v1.destroy();
        utils.gpa.destroy(binding);
    }
    xkb_bindings.xkb_bindings_v1.destroy();
    utils.gpa.destroy(xkb_bindings);
}

pub fn addBinding(xkb_bindings: *XkbBindings, river_seat_v1: *river.SeatV1, keysym: xkbcommon.Keysym, modifiers: river.SeatV1.Modifiers, command: Command) void {
    const xkb_binding_v1 = xkb_bindings.xkb_bindings_v1.getXkbBinding(river_seat_v1, @intFromEnum(keysym), modifiers) catch |err| {
        log.err("Failed to get river xkb binding: {}", .{err});
        return;
    };

    const xkb_binding = XkbBinding.create(xkb_binding_v1, command, xkb_bindings.context) catch @panic("Out of memory");
    xkb_bindings.bindings.append(xkb_binding);

    xkb_binding_v1.enable();
}

pub fn manage(xkb_bindings: *XkbBindings) void {
    defer xkb_bindings.pending_manage = .{};

    if (xkb_bindings.pending_manage.toggle_passthrough) {
        xkb_bindings.passthrough_active = !xkb_bindings.passthrough_active;
        var it = xkb_bindings.bindings.iterator(.forward);
        while (it.next()) |binding| {
            if (xkb_bindings.passthrough_active) {
                binding.xkb_binding_v1.disable();
            } else {
                binding.xkb_binding_v1.enable();
            }
        }
    }
}

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const xkbcommon = @import("xkbcommon");

const utils = @import("utils.zig");
const Context = @import("Context.zig");
const Config = @import("Config.zig");
const Seat = @import("Seat.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.XkbBindings);
