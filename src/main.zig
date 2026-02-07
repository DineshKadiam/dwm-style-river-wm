// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

/// Wayland globals that we need to bind listen in alphabetical order
const Globals = struct {
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
        globals.wl_outputs.deinit(utils.allocator);
    }
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
                globals.wl_outputs.put(utils.allocator, ev.name, wl_output) catch |e| {
                    fatal("Failed to add wl_output to hashmap: {any}", .{@errorName(e)});
                };
            } else if (mem.orderZ(u8, ev.interface, wl.Shm.interface.name) == .eq) {
                globals.wl_shm = registry.bind(ev.name, wl.Shm, 1) catch |e| {
                    fatal("Failed to bind to wl_shm: {any}", .{@errorName(e)});
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
        // We don't need .global_remove
        .global_remove => |ev| {
            // The only remove we care about is for wl_outputs
            if (!globals.wl_outputs.remove(ev.name)) {
                log.debug("Received a global_remove event for something other than a wl_output", .{});
            }
        },
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
