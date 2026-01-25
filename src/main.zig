// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

/// Wayland globals that we need to bind to
const Globals = struct {
    wl_compositor: ?*wl.Compositor = null,
    river_window_manager_v1: ?*river.WindowManagerV1 = null,
    river_xkb_bindings_v1: ?*river.XkbBindingsV1 = null,
};

pub fn main() !void {
    const wayland_display_var = try utils.allocator.dupeZ(u8, process.getEnvVarOwned(utils.allocator, "WAYLAND_DISPLAY") catch {
        log.err("Error getting WAYLAND_DISPLAY environment variable. Exiing", .{});
        std.posix.exit(1);
    });
    defer utils.allocator.free(wayland_display_var);

    const wl_display = wl.Display.connect(null) catch {
        log.err("Error connecting to Wayland server. Exiting", .{});
        std.posix.exit(1);
    };
    defer wl_display.disconnect();

    const wl_registry = try wl_display.getRegistry();

    var globals: Globals = .{};
    wl_registry.setListener(*Globals, registryListener, &globals);

    const errno = wl_display.roundtrip();
    if (errno != .SUCCESS) {
        log.err("Initial roundtrip failed: E{s}", .{@tagName(errno)});
        std.posix.exit(1);
    }

    const wl_compositor = globals.wl_compositor orelse utils.interfaceNotAdvertised(wl.Compositor);
    const river_window_manager_v1 = globals.river_window_manager_v1 orelse utils.interfaceNotAdvertised(river.WindowManagerV1);
    const river_xkb_bindings_v1 = globals.river_xkb_bindings_v1 orelse utils.interfaceNotAdvertised(river.XkbBindingsV1);

    const context = try Context.create(
        wl_display,
        wl_registry,
        wl_compositor,
        river_window_manager_v1,
        river_xkb_bindings_v1,
        // Hardcoded config for now
        .{ .border_width = 2, .border_color_focused = utils.parseRgbaComptime("0x89b4fa"), .border_color_unfocused = utils.parseRgbaComptime("0x1e1e2e") },
    );
    defer context.destroy();

    while (true) {
        if (wl_display.dispatch() != .SUCCESS) {
            log.err("wayland display dispatch failed", .{});
            std.posix.exit(1);
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
                    log.err("Failed to bind to compositor: {any}", .{@errorName(e)});
                    std.posix.exit(1);
                };
            } else if (mem.orderZ(u8, ev.interface, river.WindowManagerV1.interface.name) == .eq) {
                globals.river_window_manager_v1 = registry.bind(ev.name, river.WindowManagerV1, 3) catch |e| {
                    log.err("Failed to bind to window_manager_v1: {any}", .{@errorName(e)});
                    std.posix.exit(1);
                };
            } else if (mem.orderZ(u8, ev.interface, river.XkbBindingsV1.interface.name) == .eq) {
                globals.river_xkb_bindings_v1 = registry.bind(ev.name, river.XkbBindingsV1, 2) catch |e| {
                    log.err("Failed to bind to xkb_bindings_v1: {any}", .{@errorName(e)});
                    std.posix.exit(1);
                };
            }
        },
        // We don't need .global_remove
        .global_remove => {},
    }
}

const std = @import("std");
const mem = std.mem;
const process = std.process;

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

const utils = @import("utils.zig");
const Config = @import("Config.zig");
const Context = @import("Context.zig");
const WindowManager = @import("WindowManager.zig");
const XkbBindings = @import("XkbBindings.zig");

const log = std.log.scoped(.main);
