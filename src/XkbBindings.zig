// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const XkbBindings = @This();

pub const Command = union(enum) {
    spawn: [:0]const u8,
    focus_next_window,
    focus_prev_window,
    focus_next_output,
    focus_prev_output,
    send_to_next_output,
    send_to_prev_output,
    zoom,
    toggle_float,
    // Changes the ratio on the focused output only
    change_primary_ratio: f32,
    // Changes the ratio on the focused output only
    change_single_window_ratio: f32,
    // Changes the primary count on the focus output only
    increment_primary_count,
    decrement_primary_count,
    reload_config,
    toggle_fullscreen,
    close_window,
    exit_river,
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
            .spawn => |cmd| utils.gpa.free(cmd),
            .focus_next_window,
            .focus_prev_window,
            .focus_next_output,
            .focus_prev_output,
            .send_to_next_output,
            .send_to_prev_output,
            .zoom,
            .toggle_float,
            .change_primary_ratio,
            .change_single_window_ratio,
            .increment_primary_count,
            .decrement_primary_count,
            .reload_config,
            .toggle_fullscreen,
            .close_window,
            .exit_river,
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
    allow_locked: bool,
    link: wl.list.Link,

    const FocusDirection = enum { next, prev };

    fn create(xkb_binding_v1: *river.XkbBindingV1, command: Command, context: *Context, allow_locked: bool) !*XkbBinding {
        var xkb_binding = try utils.gpa.create(XkbBinding);
        errdefer utils.gpa.destroy(xkb_binding);

        xkb_binding.* = .{
            .xkb_binding_v1 = xkb_binding_v1,
            .command = command,
            .context = context,
            .allow_locked = allow_locked,
            .link = undefined, // Handled by the wl.list
        };

        xkb_binding.xkb_binding_v1.setListener(*XkbBinding, xkbBindingListener, xkb_binding);

        return xkb_binding;
    }

    pub fn destroy(xkb_binding: *XkbBinding) void {
        xkb_binding.xkb_binding_v1.destroy();
        xkb_binding.link.remove();
        utils.gpa.destroy(xkb_binding);
    }

    fn xkbBindingListener(river_xkb_binding_v1: *river.XkbBindingV1, event: river.XkbBindingV1.Event, xkb_binding: *XkbBinding) void {
        assert(xkb_binding.xkb_binding_v1 == river_xkb_binding_v1);
        switch (event) {
            .pressed => xkb_binding.executeCommand(),
            else => {},
        }
    }

    fn executeCommand(xkb_binding: *XkbBinding) void {
        const context = xkb_binding.context;

        const first_seat = context.wm.seats.first() orelse null;

        // TODO: Should I log.warn when commands return early?
        switch (xkb_binding.command) {
            .spawn => |cmd| spawnProcess(context.environ, cmd),
            .focus_next_window => focusWindow(context, .next),
            .focus_prev_window => focusWindow(context, .prev),
            .focus_next_output => focusOutput(context, .next),
            .focus_prev_output => focusOutput(context, .prev),
            .send_to_next_output => sendWindowToOutput(context, .next),
            .send_to_prev_output => sendWindowToOutput(context, .prev),
            .zoom => {
                const seat = first_seat orelse return;
                const current_focus: *Window = blk: {
                    if (seat.pending_manage.focus) |pending_focus| {
                        switch (pending_focus) {
                            .clear => return,
                            .focus => |focused| break :blk focused.window orelse return,
                        }
                    }
                    const focused = seat.focused orelse return;
                    break :blk focused.window orelse return;
                };

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
                seat.pending_manage.focus = .{ .focus = .{ .output = output, .window = current_focus } };
                // Warp pointer when the focused window is promoted to primary
                if (!focus_is_first_tiled) {
                    seat.pending_manage.should_warp_pointer = true;
                }
            },
            .toggle_float => {
                const seat = first_seat orelse return;
                const focused = seat.focused orelse return;
                const window = focused.window orelse return;
                // Noop if the window is fullscreened
                if (window.fullscreen) return;
                window.pending_manage.floating = !window.floating;
                context.wm.river_window_manager_v1.manageDirty();
            },
            inline .change_primary_ratio, .change_single_window_ratio => |diff, cmd| {
                const seat = first_seat orelse return;
                const focused = seat.focused orelse return;
                const output = focused.output;
                // Get rid of the "change_" from the start of the command name
                const field_name = @tagName(cmd)[7..];
                @field(output.pending_manage, field_name) = @field(output, field_name) + diff;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .increment_primary_count => {
                const seat = first_seat orelse return;
                const focused = seat.focused orelse return;
                focused.output.pending_manage.primary_count = focused.output.primary_count + 1;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .decrement_primary_count => {
                const seat = first_seat orelse return;
                const focused = seat.focused orelse return;
                focused.output.pending_manage.primary_count = focused.output.primary_count - 1;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .reload_config => {
                // Try create new config
                const new_config = Config.init(xkb_binding.context.environ.*) catch |e| {
                    // We do this so that, if the Config fails to reload, the
                    // user still has *some* config.
                    log.err("Failed to reload Config: {}. Not deleting old one", .{e});
                    return;
                };
                if (context.pending_manage.config) |*old_pending| {
                    // Need to prevent memory leaks in case multiple reloads are sent before a manage
                    old_pending.deinit();
                }
                // Send the config to the WM to handle during next manage
                context.pending_manage.config = new_config;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .toggle_fullscreen => {
                const seat = first_seat orelse return;
                const focused = seat.focused orelse return;
                const window = focused.window orelse return;
                window.pending_manage.fullscreen = !window.fullscreen;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .close_window => {
                const seat = first_seat orelse return;
                if (seat.focused) |focused| if (focused.window) |window| {
                    window.river_window_v1.close();
                };
            },
            .exit_river => context.wm.river_window_manager_v1.exitSession(),
            .set_output_tags => |tags| {
                const seat = first_seat orelse return;
                const focused = seat.focused orelse return;
                focused.output.pending_manage.tags = tags;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .set_window_tags => |tags| {
                const seat = first_seat orelse return;
                const focused = seat.focused orelse return;
                const window = focused.window orelse return;
                window.pending_manage.tags = tags;
                context.wm.river_window_manager_v1.manageDirty();
            },
            .toggle_output_tags => |tags| {
                const seat = first_seat orelse return;
                const focused = seat.focused orelse return;
                const old_tags = focused.output.pending_manage.tags orelse focused.output.tags;
                const new_tags = old_tags ^ tags;
                if (new_tags != 0) {
                    focused.output.pending_manage.tags = new_tags;
                    context.wm.river_window_manager_v1.manageDirty();
                }
            },
            .toggle_window_tags => |tags| {
                const seat = first_seat orelse return;
                const focused = seat.focused orelse return;
                const window = focused.window orelse return;
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
        const focused = seat.focused orelse return;
        const output = focused.output;
        const next_window = if (focused.window) |current| blk: {
            assert(current.output == output);
            break :blk switch (direction) {
                .next => output.nextWindow(current),
                .prev => output.prevWindow(current),
            };
        } else switch (direction) {
            .next => output.windows.first(),
            .prev => output.windows.last(),
        };
        seat.pending_manage.focus = .{ .focus = .{ .output = output, .window = next_window } };
        if (next_window != null) seat.pending_manage.should_warp_pointer = true;
    }

    fn focusOutput(context: *Context, direction: FocusDirection) void {
        const wm = context.wm;
        const seat = wm.seats.first() orelse return;
        const current_output = if (seat.focused) |focused| focused.output else null;
        if (seat.focused) |focused| if (focused.window) |window| {
            assert(window.output == focused.output);
        };
        const next_output = if (current_output) |current|
            switch (direction) {
                .next => wm.nextOutput(current),
                .prev => wm.prevOutput(current),
            }
        else switch (direction) {
            .next => wm.outputs.first(),
            .prev => wm.outputs.last(),
        };

        if (next_output) |output| {
            // This should be a noop if there's only one output
            if (output == current_output) {
                log.debug("focusOutput(): trying to focus current output", .{});
                return;
            }
            if (output.findFocusCandidate()) |window| {
                seat.pending_manage.focus = .{ .focus = .{ .output = output, .window = window } };
                seat.pending_manage.should_warp_pointer = true;
                return;
            }
            seat.pending_manage.focus = .{ .focus = .{ .output = output, .window = null } };
        } else {
            log.warn("focusOutput(): no outputs", .{});
            // This should only ever be reached if there were no outputs and then the user
            // tries to change the focused output again.
            seat.pending_manage.focus = .clear;
        }
    }

    /// This function requires that the window is currently on an output
    /// AND that the output is the currently focused output on the first seat.
    fn sendWindowToOutput(context: *Context, direction: FocusDirection) void {
        const wm = context.wm;
        const seat = wm.seats.first() orelse return;
        const focused = seat.focused orelse return;
        const window = focused.window orelse return;
        assert(window.output == focused.output);
        const current_output = focused.output;
        const next_output = switch (direction) {
            .next => wm.nextOutput(current_output),
            .prev => wm.prevOutput(current_output),
        };
        if (next_output) |output| {
            // This should be a noop if there's only one output
            if (output != window.output) window.sendToOutput(output);
        }
    }

    // Borrowed and modified from river-classic
    // https://codeberg.org/river/river-classic/src/commit/273f31016a8d212ea320568dbcc7eaebb1d5588e/river/process.zig
    fn spawnProcess(env: *process.Environ.Map, cmd: [:0]const u8) void {
        const env_block = env.createPosixBlock(utils.gpa, .{}) catch @panic("Out of memory");
        defer env_block.deinit(utils.gpa);

        const child_args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd.ptr, null };

        const pid = c.fork();
        if (pid < 0) {
            log.err("Failed to fork \"{s}\"", .{cmd});
            return;
        }
        if (pid == 0) {
            cleanupChild();
            const pid2 = c.fork();
            if (pid2 != 0) {
                // Exit child 1
                c._exit(0);
            }
            // Exec in child 2
            _ = c.execve("/bin/sh", &child_args, env_block.slice.ptr);
            c._exit(1);
        }
        while (true) {
            var status: c_int = 0;
            switch (posix.errno(c.waitpid(pid, &status, 0))) {
                .SUCCESS => break,
                .INTR => continue,
                else => break,
            }
        }
    }

    fn cleanupChild() void {
        _ = c.setsid();
        posix.sigprocmask(posix.SIG.SETMASK, &posix.sigemptyset(), null);
        posix.sigaction(.PIPE, &.{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);
    }

    fn moveFloatingWindow(context: *Context, dx: i32, dy: i32) void {
        const seat = context.wm.seats.first() orelse return;
        const focused = seat.focused orelse return;
        const window = focused.window orelse return;
        if (!window.floating) return;

        window.floating_rect.x += dx;
        window.floating_rect.y += dy;
        window.pending_render.position = .{ .x = window.floating_rect.x, .y = window.floating_rect.y };
        context.wm.river_window_manager_v1.manageDirty();
    }

    fn resizeFloatingWindow(context: *Context, dw: i32, dh: i32) void {
        const seat = context.wm.seats.first() orelse return;
        const focused = seat.focused orelse return;
        const window = focused.window orelse return;
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
        const focused = seat.focused orelse return;
        const window = focused.window orelse return;
        if (!window.floating) return;
        const output = window.output orelse return;

        window.floating_rect.x = output.usable_geometry.x + @divFloor(output.usable_geometry.width, 2) - @divFloor(window.floating_rect.width, 2);
        window.floating_rect.y = output.usable_geometry.y + @divFloor(output.usable_geometry.height, 2) - @divFloor(window.floating_rect.height, 2);
        window.pending_render.position = .{ .x = window.floating_rect.x, .y = window.floating_rect.y };
        context.wm.river_window_manager_v1.manageDirty();
    }

    fn swapWindow(context: *Context, comptime direction: enum { next, prev }) void {
        const seat = context.wm.seats.first() orelse return;
        const focused = seat.focused orelse return;
        const window = focused.window orelse return;
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

/// When the session is locked, keybinds where allow_locked is false are disabled
session_locked: bool = false,

bindings: wl.list.Head(XkbBinding, .link),

pending_manage: PendingManage = .{},

const PendingManage = struct {
    toggle_passthrough: bool = false,

    session_locked: ?bool = null,
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

pub fn addBinding(xkb_bindings: *XkbBindings, river_seat_v1: *river.SeatV1, keysym: xkbcommon.Keysym, modifiers: river.SeatV1.Modifiers, command: Command, allow_locked: bool) void {
    const xkb_binding_v1 = xkb_bindings.xkb_bindings_v1.getXkbBinding(river_seat_v1, @intFromEnum(keysym), modifiers) catch |err| {
        log.err("Failed to get river xkb binding: {}", .{err});
        return;
    };

    const xkb_binding = XkbBinding.create(xkb_binding_v1, command, xkb_bindings.context, allow_locked) catch @panic("Out of memory");
    xkb_bindings.bindings.append(xkb_binding);

    if ((xkb_bindings.session_locked and !allow_locked) or
        (xkb_bindings.passthrough_active and command != .toggle_passthrough))
    {
        xkb_binding_v1.disable();
    } else {
        xkb_binding_v1.enable();
    }
}

pub fn manage(xkb_bindings: *XkbBindings) void {
    defer xkb_bindings.pending_manage = .{};
    const pending_manage = xkb_bindings.pending_manage;

    // TODO: Use keybind modes or whatever they were called in river-classic instead of having a specific "passthrough"
    const will_be_locked = pending_manage.session_locked orelse xkb_bindings.session_locked;
    const will_have_passthrough = if (pending_manage.toggle_passthrough)
        !xkb_bindings.passthrough_active
    else
        xkb_bindings.passthrough_active;

    const locked_changed = will_be_locked != xkb_bindings.session_locked;
    const passthrough_changed = will_have_passthrough != xkb_bindings.passthrough_active;

    xkb_bindings.session_locked = will_be_locked;
    xkb_bindings.passthrough_active = will_have_passthrough;

    if (locked_changed or passthrough_changed) {
        var it = xkb_bindings.bindings.iterator(.forward);
        while (it.next()) |binding| {
            if (will_be_locked and !binding.allow_locked) {
                binding.xkb_binding_v1.disable();
            } else if (will_have_passthrough and binding.command != .toggle_passthrough) {
                binding.xkb_binding_v1.disable();
            } else {
                binding.xkb_binding_v1.enable();
            }
        }
    }
}

const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const process = std.process;

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
