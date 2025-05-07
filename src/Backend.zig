// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");
const mem = std.mem;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const log = std.log.scoped(.Backend);

const Backend = @This();

allocator: mem.Allocator,
initialized: bool,

display: *wl.Display,
registry: *wl.Registry,

compositor: ?*wl.Compositor = null,
shm: ?*wl.Shm = null,

window_manager: ?*river.WindowManagerV1 = null,

// outputs: std.SinglyLinkedList(Output) = .{},

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
    backend.registry.setListener(*Backend, registry_listener, &backend);

    // Do an initial roundtrip so the registry globals fire
    const errno = backend.display.roundtrip();
    if (errno != .SUCCESS) {
        log.err("Initial roundtrip failed: E{s}", .{@tagName(errno)});
        std.posix.exit(1);
    }

    // These are all required by beansprout.
    // If we are missing any of them, then let's exit.
    if (backend.compositor == null) interface_not_advertised(wl.Compositor);
    if (backend.shm == null) interface_not_advertised(wl.Shm);
    if (backend.window_manager == null) interface_not_advertised(river.WindowManagerV1);

    return backend;
}

/// Deinitialize a Backend
pub fn deinit(backend: *Backend) void {
    _ = backend;
}

fn registry_listener(registry: *wl.Registry, event: wl.Registry.Event, backend: *Backend) void {
    // Since we can't return errors from the listener, we use a helper function so that
    // we can easily log any errors the same way.
    registry_listener_helper(registry, event, backend) catch |err| {
        log.err("{any}", .{err});
        return;
    };
}

fn registry_listener_helper(registry: *wl.Registry, event: wl.Registry.Event, backend: *Backend) !void {
    // Use a helper function to log errors; the actual listener can't return an error.
    switch (event) {
        .global => |ev| {
            if (mem.orderZ(u8, ev.interface, wl.Compositor.interface.name) == .eq) {
                if (ev.version < 4) version_not_supported(wl.Compositor, ev.version, 4);
                backend.compositor = try registry.bind(ev.name, wl.Compositor, 4);
            } else if (mem.orderZ(u8, ev.interface, wl.Shm.interface.name) == .eq) {
                backend.shm = try registry.bind(ev.name, wl.Shm, 1);
            } else if (mem.orderZ(u8, ev.interface, river.WindowManagerV1.interface.name) == .eq) {
                backend.window_manager = try registry.bind(ev.name, river.WindowManagerV1, 1);
            }
        },
        .global_remove => |ev| {
            log.debug("TODO...", .{});
            _ = ev;
        },
    }
}

fn window_manager_listener(window_manager: *river.WindowManagerV1, event: river.WindowManagerV1.Event, backend: *Backend) !void {
    _ = backend;
    _ = window_manager;
    switch (event) {
        .update_windowing_start => log.debug("RAAAA"),
        .update_windowing_end => log.debug("REEE"),
        else => log.debug("WOOOO"),
    }
}

fn interface_not_advertised(comptime WaylandGlobal: type) noreturn {
    log.err("{s} not advertised. Exiting", .{WaylandGlobal.interface.name});
    std.posix.exit(1);
}

fn version_not_supported(comptime WaylandGlobal: type, have_version: u32, need_version: u32) noreturn {
    log.err("The compositor only advertised {s} version {d} but version {d} is required. Exiting", .{ WaylandGlobal.interface.name, have_version, need_version });
    std.posix.exit(1);
}
