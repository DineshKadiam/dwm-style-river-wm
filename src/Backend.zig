// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Backend = @This();

allocator: mem.Allocator,
initialized: bool,

display: *wl.Display,
registry: *wl.Registry,

compositor: ?*wl.Compositor = null,
shm: ?*wl.Shm = null,

wm: ?WindowManager = null,

/// Return a new Backend
pub fn init(allocator: mem.Allocator) !Backend {
    const wl_display = wl.Display.connect(null) catch {
        log.err("Error connecting to Wayland. Exiting", .{});
        std.posix.exit(1);
    };

    var backend: Backend = .{
        .initialized = false,
        .allocator = allocator,
        .display = wl_display,
        .registry = try wl_display.getRegistry(),
    };
    backend.registry.setListener(*Backend, registryListener, &backend);

    // Do an initial roundtrip so the registry globals fire
    const errno = backend.display.roundtrip();
    if (errno != .SUCCESS) {
        log.err("Initial roundtrip failed: E{s}", .{@tagName(errno)});
        std.posix.exit(1);
    }

    // These are all required by beansprout.
    // If we are missing any of them, then let's exit.
    if (backend.compositor == null) interfaceNotAdvertised(wl.Compositor);
    if (backend.shm == null) interfaceNotAdvertised(wl.Shm);
    if (backend.wm == null) interfaceNotAdvertised(river.WindowManagerV1);

    return backend;
}

/// Deinitialize a Backend
pub fn deinit(backend: *Backend) void {
    defer backend.display.disconnect();

    if (backend.compositor) |c| {
        c.destroy();
    }
    if (backend.shm) |s| {
        s.destroy();
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, backend: *Backend) void {
    // Since we can't return errors from the listener, we use a helper function so that
    // we can easily log any errors the same way.
    switch (event) {
        .global => |ev| {
            if (mem.orderZ(u8, ev.interface, wl.Compositor.interface.name) == .eq) {
                if (ev.version < 4) versionNotSupported(wl.Compositor, ev.version, 4);
                backend.compositor = try registry.bind(ev.name, wl.Compositor, 4);
            } else if (mem.orderZ(u8, ev.interface, wl.Shm.interface.name) == .eq) {
                backend.shm = try registry.bind(ev.name, wl.Shm, 1);
            } else if (mem.orderZ(u8, ev.interface, river.WindowManagerV1.interface.name) == .eq) {
                backend.wm = .{ .window_manager = try WindowManager.init(try registry.bind(ev.name, river.WindowManagerV1, 1)) catch {} };
                backend.wm.?.setListener();
            }
        },
        // We don't need .global_remove
        .global_remove => {},
    }
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
const wl = wayland.client.wl;
const river = wayland.client.river;

const WindowManager = @import("WindowManager.zig");

const log = std.log.scoped(.Backend);
