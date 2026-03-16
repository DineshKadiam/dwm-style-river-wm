// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

/// Wayland globals that we need to bind listen in alphabetical order
const Globals = struct {
    river_input_manager_v1: ?*river.InputManagerV1 = null,
    river_libinput_config_v1: ?*river.LibinputConfigV1 = null,
    river_layer_shell_v1: ?*river.LayerShellV1 = null,
    river_window_manager_v1: ?*river.WindowManagerV1 = null,
    river_xkb_bindings_v1: ?*river.XkbBindingsV1 = null,
    river_xkb_config_v1: ?*river.XkbConfigV1 = null,

    wl_compositor: ?*wl.Compositor = null,
    wl_shm: ?*wl.Shm = null,
};

const usage: []const u8 =
    \\usage: beansprout [options]
    \\
    \\  -h                 Print this help message and exit.
    \\  -version           Print the version number and exit.
    \\  -log-level <level> Set the log level to error, warning, info, or debug.
    \\
    \\ Config belongs under $XDG_CONFIG_DIR or $HOME/.config at beansprout/config.kdl
    \\
;

pub fn main() !void {
    parseArgs();

    // Initialize fcft
    const fcft_log_level: fcft.LogClass = switch (runtime_log_level) {
        .err => .err,
        .warn => .warning,
        .info => .info,
        .debug => .debug,
    };
    _ = fcft.init(.auto, false, fcft_log_level);
    defer fcft.fini();

    const wayland_display_var = posix.getenvZ("WAYLAND_DISPLAY") orelse {
        fatal("WAYLAND_DISPLAY environment variable not set. Exiting", .{});
    };

    const wl_display = wl.Display.connect(wayland_display_var) catch {
        fatal("Error connecting to Wayland server. Exiting", .{});
    };
    defer wl_display.disconnect();

    const wl_registry = try wl_display.getRegistry();

    var globals: Globals = .{};
    wl_registry.setListener(*Globals, registryListener, &globals);

    const errno = wl_display.roundtrip();
    if (errno != .SUCCESS) {
        fatal("Initial roundtrip failed: E{s}", .{@tagName(errno)});
    }

    const wl_compositor = globals.wl_compositor orelse utils.interfaceNotAdvertised(wl.Compositor);
    const wl_shm = globals.wl_shm orelse utils.interfaceNotAdvertised(wl.Shm);

    const river_input_manager_v1 = globals.river_input_manager_v1 orelse utils.interfaceNotAdvertised(river.InputManagerV1);
    const river_libinput_config_v1 = globals.river_libinput_config_v1 orelse utils.interfaceNotAdvertised(river.LibinputConfigV1);
    const river_layer_shell_v1 = globals.river_layer_shell_v1 orelse utils.interfaceNotAdvertised(river.LayerShellV1);
    const river_window_manager_v1 = globals.river_window_manager_v1 orelse utils.interfaceNotAdvertised(river.WindowManagerV1);
    const river_xkb_bindings_v1 = globals.river_xkb_bindings_v1 orelse utils.interfaceNotAdvertised(river.XkbBindingsV1);
    const river_xkb_config_v1 = globals.river_xkb_config_v1 orelse utils.interfaceNotAdvertised(river.XkbConfigV1);

    const config = try Config.create();
    defer config.destroy();
    const context = try Context.create(.{
        .wl_compositor = wl_compositor,
        .wl_display = wl_display,
        .wl_registry = wl_registry,
        .wl_shm = wl_shm,
        .river_input_manager_v1 = river_input_manager_v1,
        .river_libinput_config_v1 = river_libinput_config_v1,
        .river_layer_shell_v1 = river_layer_shell_v1,
        .river_window_manager_v1 = river_window_manager_v1,
        .river_xkb_bindings_v1 = river_xkb_bindings_v1,
        .river_xkb_config_v1 = river_xkb_config_v1,
        .config = config,
    });
    defer context.destroy();

    try run(wl_display, context);
}

fn run(wl_display: *wl.Display, context: *Context) !void {
    var mask = posix.sigemptyset();

    posix.sigaddset(&mask, posix.SIG.INT);
    posix.sigaddset(&mask, posix.SIG.QUIT);

    posix.sigprocmask(posix.SIG.BLOCK, &mask, null);

    const sig_fd = try posix.signalfd(-1, &mask, @as(u32, @bitCast(posix.O{ .CLOEXEC = true })));

    const poll_wayland = 0;
    const poll_sig = 1;

    var pollfds: [2]posix.pollfd = undefined;

    pollfds[poll_wayland] = .{
        .fd = wl_display.getFd(),
        .events = posix.POLL.IN,
        .revents = 0,
    };
    pollfds[poll_sig] = .{
        .fd = sig_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    };

    while (true) {
        const flush_errno = wl_display.flush();
        if (flush_errno == .AGAIN) {
            // Send buffer is full; ask poll to wake us when the socket is writable
            // again so we can retry the flush at the top of the next iteration.
            pollfds[poll_wayland].events = posix.POLL.IN | posix.POLL.OUT;
        } else if (flush_errno != .SUCCESS) {
            fatal("wl_display flush failed: E{s}", .{@tagName(flush_errno)});
        } else {
            // Flush succeeded; stop polling for writability.
            pollfds[poll_wayland].events = posix.POLL.IN;
        }

        // Compute poll timeout: minimum of clock update and tag overlay expiry
        var timeout: i32 = blk: {
            // Milliseconds until the top of the next second (for clock updates)
            const time_ns = time.nanoTimestamp();
            const remainder_ns = @mod(time_ns, time.ns_per_s);
            break :blk @intCast(@divFloor(time.ns_per_s - remainder_ns, time.ns_per_ms));
        };

        // Check for expired tag overlays and find the soonest expiry
        const now = time.Instant.now() catch
            fatal("System does not support a monotonic or steady clock", .{});
        {
            var it = context.wm.outputs.iterator(.forward);
            while (it.next()) |output| {
                const tag_overlay = output.tag_overlay orelse continue;
                const last_shown = tag_overlay.last_shown orelse continue;
                const elapsed_ns = now.since(last_shown);
                const timeout_ns: u64 = @as(u64, tag_overlay.options.timeout) * time.ns_per_ms;
                if (elapsed_ns >= timeout_ns) {
                    output.tag_overlay.?.deinitSurfaces();
                } else {
                    const remaining_ms: i32 = @intCast((timeout_ns - elapsed_ns) / time.ns_per_ms);
                    timeout = @min(timeout, remaining_ms);
                }
            }
        }

        const poll_rc = posix.poll(&pollfds, timeout) catch |err| {
            fatal("Failed to poll {s}", .{@errorName(err)});
        };
        if (poll_rc == 0) {
            // Update the clock
            var it = context.wm.outputs.iterator(.forward);
            while (it.next()) |output| {
                if (output.bar) |*bar| {
                    bar.pending_render.draw = true;
                    context.wm.river_window_manager_v1.manageDirty();
                }
            }
        }

        // Handle fds that became ready
        if (pollfds[poll_wayland].revents & posix.POLL.HUP != 0) {
            @branchHint(.cold);
            log.info("Disconnected by compositor", .{});
            break;
        }
        if (pollfds[poll_wayland].revents & posix.POLL.IN != 0) {
            if (wl_display.dispatch() != .SUCCESS) {
                @branchHint(.cold);
                fatal("Wayland display dispatch failed", .{});
            }
        }

        if (pollfds[poll_sig].revents & posix.POLL.HUP != 0) {
            @branchHint(.cold);
            fatal("Signal fd hung up", .{});
        }
        if (pollfds[poll_sig].revents & posix.POLL.IN != 0) {
            @branchHint(.cold);
            log.info("Exiting beansprout", .{});
            break;
        }
    }
}

fn parseArgs() void {
    const result = flags.Parser([*:0]const u8, &.{
        .{ .name = "h", .kind = .boolean },
        .{ .name = "version", .kind = .boolean },
        .{ .name = "log-level", .kind = .arg },
    }).parse(os.argv[1..]) catch {
        stderr.writeAll(usage) catch {};
        stderr.flush() catch {};
        posix.exit(1);
    };
    if (result.flags.h) {
        stdout.writeAll(usage) catch {};
        stdout.flush() catch {};
        posix.exit(0);
    }
    if (result.args.len != 0) {
        log.err("unknown option '{s}'", .{result.args[0]});
        stderr.writeAll(usage) catch {};
        stderr.flush() catch {};
        posix.exit(1);
    }

    if (result.flags.version) {
        stdout.writeAll(build_options.version ++ "\n") catch {};
        stdout.flush() catch {};
        posix.exit(0);
    }
    if (result.flags.@"log-level") |level| {
        if (mem.eql(u8, level, "error")) {
            runtime_log_level = .err;
        } else if (mem.eql(u8, level, "warning")) {
            runtime_log_level = .warn;
        } else if (mem.eql(u8, level, "info")) {
            runtime_log_level = .info;
        } else if (mem.eql(u8, level, "debug")) {
            runtime_log_level = .debug;
        } else {
            log.err("invalid log level '{s}'", .{level});
            posix.exit(1);
        }
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |ev| {
            if (mem.orderZ(u8, ev.interface, wl.Compositor.interface.name) == .eq) {
                if (ev.version < 4) utils.versionNotSupported(wl.Compositor, ev.version, 4);
                globals.wl_compositor = registry.bind(ev.name, wl.Compositor, 4) catch |e| {
                    fatal("Failed to bind to wl_compositor: {any}", .{@errorName(e)});
                };
            } else if (mem.orderZ(u8, ev.interface, wl.Output.interface.name) == .eq) {
                if (ev.version < 4) utils.versionNotSupported(wl.Output, ev.version, 4);
                // We don't bind wl_output until the river_output sends its .wl_output event
                // This way, we don't miss the initial configuration events
            } else if (mem.orderZ(u8, ev.interface, wl.Shm.interface.name) == .eq) {
                globals.wl_shm = registry.bind(ev.name, wl.Shm, 1) catch |e| {
                    fatal("Failed to bind to wl_shm: {any}", .{@errorName(e)});
                };
            } else if (mem.orderZ(u8, ev.interface, river.InputManagerV1.interface.name) == .eq) {
                globals.river_input_manager_v1 = registry.bind(ev.name, river.InputManagerV1, 1) catch |e| {
                    fatal("Failed to bind to river_input_manager_v1: {any}", .{@errorName(e)});
                };
            } else if (mem.orderZ(u8, ev.interface, river.LibinputConfigV1.interface.name) == .eq) {
                globals.river_libinput_config_v1 = registry.bind(ev.name, river.LibinputConfigV1, 1) catch |e| {
                    fatal("Failed to bind to river_libinput_config_v1: {any}", .{@errorName(e)});
                };
            } else if (mem.orderZ(u8, ev.interface, river.LayerShellV1.interface.name) == .eq) {
                globals.river_layer_shell_v1 = registry.bind(ev.name, river.LayerShellV1, 1) catch |e| {
                    fatal("Failed to bind to river_layer_shell_v1: {any}", .{@errorName(e)});
                };
            } else if (mem.orderZ(u8, ev.interface, river.WindowManagerV1.interface.name) == .eq) {
                if (ev.version < 4) utils.versionNotSupported(river.WindowManagerV1, ev.version, 4);
                globals.river_window_manager_v1 = registry.bind(ev.name, river.WindowManagerV1, 4) catch |e| {
                    fatal("Failed to bind to river_window_manager_v1: {any}", .{@errorName(e)});
                };
            } else if (mem.orderZ(u8, ev.interface, river.XkbBindingsV1.interface.name) == .eq) {
                globals.river_xkb_bindings_v1 = registry.bind(ev.name, river.XkbBindingsV1, 2) catch |e| {
                    fatal("Failed to bind to river_xkb_bindings_v1: {any}", .{@errorName(e)});
                };
            } else if (mem.orderZ(u8, ev.interface, river.XkbConfigV1.interface.name) == .eq) {
                globals.river_xkb_config_v1 = registry.bind(ev.name, river.XkbConfigV1, 1) catch |e| {
                    fatal("Failed to bind to river_xkb_config_v1: {any}", .{@errorName(e)});
                };
            }
        },
        .global_remove => |_| {
            // wl_output removal is handled by the river protocol's .removed
            // event, and we don't care about any other globals being removed.
        },
    }
}

var stderr_buffer: [1024]u8 = undefined;
var stderr_writer = fs.File.stderr().writer(&stderr_buffer);
const stderr = &stderr_writer.interface;

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

/// Set the default log level based on the build mode.
var runtime_log_level: std.log.Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .info,
};

pub const std_options: std.Options = .{
    // Tell std.log to leave all log level filtering to us.
    .log_level = .debug,
    .logFn = logFn,
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(runtime_log_level)) return;

    const scope_prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    stderr.print(level.asText() ++ scope_prefix ++ format ++ "\n", args) catch return;
    stderr.flush() catch return;
}

const build_options = @import("build_options");
const builtin = @import("builtin");
const std = @import("std");
const fatal = std.process.fatal;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const posix = std.posix;
const process = std.process;
const time = std.time;

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;
const fcft = @import("fcft");

const flags = @import("flags.zig");
const utils = @import("utils.zig");
const Config = @import("Config.zig");
const Context = @import("Context.zig");
const WindowManager = @import("WindowManager.zig");
const XkbBindings = @import("XkbBindings.zig");

const log = std.log.scoped(.main);

test {
    _ = @import("utils.zig");
    _ = @import("Config.zig");
    _ = @import("globber.zig");
}
