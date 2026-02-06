// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

/// Wayland globals that we need to bind listen in alphabetical order
const Globals = struct {
    river_layer_shell_v1: ?*river.LayerShellV1 = null,
    river_window_manager_v1: ?*river.WindowManagerV1 = null,
    river_xkb_bindings_v1: ?*river.XkbBindingsV1 = null,
    wl_compositor: ?*wl.Compositor = null,
    wl_output: ?*wl.Output = null,
    wl_shm: ?*wl.Shm = null,
    zwlr_layer_shell_v1: ?*zwlr.LayerShellV1 = null,
};

pub fn main() !void {
    const wayland_display_var = try utils.allocator.dupeZ(u8, process.getEnvVarOwned(utils.allocator, "WAYLAND_DISPLAY") catch {
        fatal("Error getting WAYLAND_DISPLAY environment variable. Exiting", .{});
    });
    defer utils.allocator.free(wayland_display_var);

    const wl_display = wl.Display.connect(null) catch {
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

    const river_layer_shell_v1 = globals.river_layer_shell_v1 orelse utils.interfaceNotAdvertised(river.LayerShellV1);
    const river_window_manager_v1 = globals.river_window_manager_v1 orelse utils.interfaceNotAdvertised(river.WindowManagerV1);
    const river_xkb_bindings_v1 = globals.river_xkb_bindings_v1 orelse utils.interfaceNotAdvertised(river.XkbBindingsV1);
    const wl_compositor = globals.wl_compositor orelse utils.interfaceNotAdvertised(wl.Compositor);
    const wl_output = globals.wl_output orelse utils.interfaceNotAdvertised(wl.Output);
    const wl_shm = globals.wl_shm orelse utils.interfaceNotAdvertised(wl.Shm);
    const zwlr_layer_shell_v1 = globals.zwlr_layer_shell_v1 orelse utils.interfaceNotAdvertised(zwlr.LayerShellV1);

    const config = try Config.create();
    defer config.destroy();
    const context = try Context.create(.{
        .wl_compositor = wl_compositor,
        .wl_display = wl_display,
        .wl_output = wl_output,
        .wl_registry = wl_registry,
        .wl_shm = wl_shm,
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
                    fatal("Failed to bind to compositor: {any}", .{@errorName(e)});
                };
            } else if (mem.orderZ(u8, ev.interface, river.WindowManagerV1.interface.name) == .eq) {
                globals.river_window_manager_v1 = registry.bind(ev.name, river.WindowManagerV1, 3) catch |e| {
                    fatal("Failed to bind to window_manager_v1: {any}", .{@errorName(e)});
                };
            } else if (mem.orderZ(u8, ev.interface, river.XkbBindingsV1.interface.name) == .eq) {
                globals.river_xkb_bindings_v1 = registry.bind(ev.name, river.XkbBindingsV1, 2) catch |e| {
                    fatal("Failed to bind to xkb_bindings_v1: {any}", .{@errorName(e)});
                };
            }
        },
        // We don't need .global_remove
        .global_remove => {},
    }
}

const std = @import("std");
const mem = std.mem;
const fatal = std.process.fatal;
const process = std.process;

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const utils = @import("utils.zig");
const Config = @import("Config.zig");
const Context = @import("Context.zig");
const WindowManager = @import("WindowManager.zig");
const XkbBindings = @import("XkbBindings.zig");

const log = std.log.scoped(.main);
