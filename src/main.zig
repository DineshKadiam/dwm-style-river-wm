// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

/// Context to pass some info around.
pub const Context = struct {
    allocator: mem.Allocator,

    initialized: bool,

    display: *wl.Display,
    registry: *wl.Registry,

    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,

    wm: WindowManager,
    xkb_bindings: XkbBindings,

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
        switch (event) {
            .global => |ev| {
                if (mem.orderZ(u8, ev.interface, wl.Compositor.interface.name) == .eq) {
                    if (ev.version < 4) versionNotSupported(wl.Compositor, ev.version, 4);
                    context.compositor = registry.bind(ev.name, wl.Compositor, 4) catch |e| {
                        log.err("Failed to bind to compositor: {any}", .{@errorName(e)});
                        std.posix.exit(1);
                    };
                } else if (mem.orderZ(u8, ev.interface, wl.Shm.interface.name) == .eq) {
                    context.shm = registry.bind(ev.name, wl.Shm, 1) catch |e| {
                        log.err("Failed to bind to shm: {any}", .{@errorName(e)});
                        std.posix.exit(1);
                    };
                } else if (mem.orderZ(u8, ev.interface, river.WindowManagerV1.interface.name) == .eq) {
                    const window_manager_v1 = registry.bind(ev.name, river.WindowManagerV1, 3) catch |e| {
                        log.err("Failed to bind to window_manager_v1: {any}", .{@errorName(e)});
                        std.posix.exit(1);
                    };
                    context.wm.init(context, window_manager_v1);
                } else if (mem.orderZ(u8, ev.interface, river.XkbBindingsV1.interface.name) == .eq) {
                    const xkb_bindings_v1 = registry.bind(ev.name, river.XkbBindingsV1, 2) catch |e| {
                        log.err("Failed to bind to xkb_bindings_v1: {any}", .{@errorName(e)});
                        std.posix.exit(1);
                    };
                    context.xkb_bindings.init(context, xkb_bindings_v1);
                }
            },
            // We don't need .global_remove
            .global_remove => {},
        }
    }
};

const usage: []const u8 =
    \\usage: beansprout [options]
    \\
    \\  -i, --image <PATH>  TODO TODO TODO TODO
    \\  -h, --help          TODO TODO TODO TODO
    \\  -V, --version       TODO TODO TODO TODO
    \\
;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const wl_display = wl.Display.connect(null) catch {
        log.err("Error connecting to Wayland server. Exiting", .{});
        std.posix.exit(1);
    };

    const registry = try wl_display.getRegistry();

    var context: Context = .{
        .allocator = allocator,
        .initialized = false,
        .display = wl_display,
        .registry = registry,
        .wm = undefined,
        .xkb_bindings = undefined,
    };

    registry.setListener(*Context, Context.registryListener, &context);

    const errno = context.display.roundtrip();
    if (errno != .SUCCESS) {
        log.err("Initial roundtrip failed: E{s}", .{@tagName(errno)});
        std.posix.exit(1);
    }

    while (true) {
        if (wl_display.dispatch() != .SUCCESS) {
            log.err("wayland display dispatch failed", .{});
            std.posix.exit(1);
        }
    }

    log.info("Exiting beansprout", .{});
}

fn interfaceNotAdvertised(comptime WaylandGlobal: type) noreturn {
    log.err("{s} not advertised. Exiting", .{WaylandGlobal.interface.name});
    std.posix.exit(1);
}

fn versionNotSupported(comptime WaylandGlobal: type, have_version: u32, need_version: u32) noreturn {
    log.err("The compositor only advertised {s} version {d} but version {d} is required. Exiting", .{ WaylandGlobal.interface.name, have_version, need_version });
    std.posix.exit(1);
}

const std = @import("std");
const mem = std.mem;

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

const WindowManager = @import("WindowManager.zig");
const XkbBindings = @import("XkbBindings.zig");

const log = std.log.scoped(.main);
