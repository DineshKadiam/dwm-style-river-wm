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

    wl_compositor: ?*wl.Compositor = null,
    wl_shm: ?*wl.Shm = null,
    wl_outputs: std.AutoHashMapUnmanaged(u32, *wl.Output) = .empty,

    zwlr_layer_shell_v1: ?*zwlr.LayerShellV1 = null,

    fn deinit(globals: *Globals) void {
        var it = globals.wl_outputs.valueIterator();
        while (it.next()) |output| {
            output.*.release();
        }
        globals.wl_outputs.deinit(utils.gpa);
    }
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
    const result = flags.parser([*:0]const u8, &.{
        .{ .name = "h", .kind = .boolean },
        .{ .name = "version", .kind = .boolean },
        .{ .name = "log-level", .kind = .arg },
    }).parse(std.os.argv[1..]) catch {
        try stderr.writeAll(usage);
        try stderr.flush();
        posix.exit(1);
    };
    if (result.flags.h) {
        try stdout.writeAll(usage);
        try stdout.flush();
        posix.exit(0);
    }
    if (result.args.len != 0) {
        log.err("unknown option '{s}'", .{result.args[0]});
        try stderr.writeAll(usage);
        try stderr.flush();
        posix.exit(1);
    }

    if (result.flags.version) {
        try stdout.writeAll(build_options.version ++ "\n");
        try stdout.flush();
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

    const wayland_display_var = try utils.gpa.dupeZ(u8, process.getEnvVarOwned(utils.gpa, "WAYLAND_DISPLAY") catch {
        fatal("Error getting WAYLAND_DISPLAY environment variable. Exiting", .{});
    });
    defer utils.gpa.free(wayland_display_var);

    const wl_display = wl.Display.connect(null) catch {
        fatal("Error connecting to Wayland server. Exiting", .{});
    };
    defer wl_display.disconnect();

    const wl_registry = try wl_display.getRegistry();

    var globals: Globals = .{};
    defer globals.deinit();
    wl_registry.setListener(*Globals, registryListener, &globals);

    const errno = wl_display.roundtrip();
    if (errno != .SUCCESS) {
        fatal("Initial roundtrip failed: E{s}", .{@tagName(errno)});
    }

    const wl_compositor = globals.wl_compositor orelse utils.interfaceNotAdvertised(wl.Compositor);
    const wl_shm = globals.wl_shm orelse utils.interfaceNotAdvertised(wl.Shm);
    // We can theoretically start with zero wl_outputs; don't panic if it's empty.
    const wl_outputs = &globals.wl_outputs;

    const river_input_manager_v1 = globals.river_input_manager_v1 orelse utils.interfaceNotAdvertised(river.InputManagerV1);
    const river_libinput_config_v1 = globals.river_libinput_config_v1 orelse utils.interfaceNotAdvertised(river.LibinputConfigV1);
    const river_layer_shell_v1 = globals.river_layer_shell_v1 orelse utils.interfaceNotAdvertised(river.LayerShellV1);
    const river_window_manager_v1 = globals.river_window_manager_v1 orelse utils.interfaceNotAdvertised(river.WindowManagerV1);
    const river_xkb_bindings_v1 = globals.river_xkb_bindings_v1 orelse utils.interfaceNotAdvertised(river.XkbBindingsV1);

    const zwlr_layer_shell_v1 = globals.zwlr_layer_shell_v1 orelse utils.interfaceNotAdvertised(zwlr.LayerShellV1);

    const config = try Config.create();
    defer config.destroy();
    const context = try Context.create(.{
        .wl_compositor = wl_compositor,
        .wl_display = wl_display,
        .wl_outputs = wl_outputs,
        .wl_registry = wl_registry,
        .wl_shm = wl_shm,
        .river_input_manager_v1 = river_input_manager_v1,
        .river_libinput_config_v1 = river_libinput_config_v1,
        .river_layer_shell_v1 = river_layer_shell_v1,
        .river_window_manager_v1 = river_window_manager_v1,
        .river_xkb_bindings_v1 = river_xkb_bindings_v1,
        .zwlr_layer_shell_v1 = zwlr_layer_shell_v1,
        .config = config,
    });
    defer context.destroy();

    while (true) {
        if (wl_display.dispatch() != .SUCCESS) {
            fatal("wayland display dispatch failed", .{});
        }
    }

    log.info("Exiting beansprout", .{});
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

                const wl_output = registry.bind(ev.name, wl.Output, 4) catch |e| {
                    fatal("Failed to bind to wl_output: {any}", .{@errorName(e)});
                };

                // We can get multiple wl_outputs, so we have to try add them to our HashMap
                // instead of just keeping the one
                globals.wl_outputs.put(utils.gpa, ev.name, wl_output) catch |e| {
                    fatal("Failed to add wl_output to hashmap: {any}", .{@errorName(e)});
                };
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
                globals.river_window_manager_v1 = registry.bind(ev.name, river.WindowManagerV1, 3) catch |e| {
                    fatal("Failed to bind to river_window_manager_v1: {any}", .{@errorName(e)});
                };
            } else if (mem.orderZ(u8, ev.interface, river.XkbBindingsV1.interface.name) == .eq) {
                globals.river_xkb_bindings_v1 = registry.bind(ev.name, river.XkbBindingsV1, 2) catch |e| {
                    fatal("Failed to bind to river_xkb_bindings_v1: {any}", .{@errorName(e)});
                };
            } else if (mem.orderZ(u8, ev.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                if (ev.version < 3) utils.versionNotSupported(zwlr.LayerShellV1, ev.version, 3);
                globals.zwlr_layer_shell_v1 = registry.bind(ev.name, zwlr.LayerShellV1, 3) catch |e| {
                    fatal("Failed to bind to zwlr_layer_shell_v1: {any}", .{@errorName(e)});
                };
            }
        },
        .global_remove => |ev| {
            // The only remove we care about is for wl_outputs
            if (!globals.wl_outputs.remove(ev.name)) {
                log.debug("Received a global_remove event for something other than a wl_output", .{});
            }
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
const posix = std.posix;
const process = std.process;

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

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
}
