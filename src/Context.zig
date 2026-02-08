// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
//

/// Context to pass Wayland info around.
const Context = @This();

initialized: bool,

// Wayland globals
wl_compositor: *wl.Compositor,
wl_display: *wl.Display,
wl_registry: *wl.Registry,
wl_shm: *wl.Shm,
wl_outputs: *std.AutoHashMapUnmanaged(u32, *wl.Output),

zwlr_layer_shell_v1: *zwlr.LayerShellV1,

// Wayland globals that we have special structs for
wm: *WindowManager,
xkb_bindings: *XkbBindings,

/// Pool of Buffers used for rendering wallpapers
buffer_pool: BufferPool = .{},

/// Holds a pixman.Image (and its raw pixels) for the wallpaper
/// (same image on all outputs, but scaled separately)
wallpaper_image: ?*WallpaperImage,

// WM Configuration
config: *Config,

/// State consumed in manage() phase, reset at end of manage().
pending_manage: PendingManage = .{},

pub const PendingManage = struct {
    config: ?*Config = null,
};

// I use this because otherwise create() takes
// a LOT of arguments.
pub const Options = struct {
    wl_compositor: *wl.Compositor,
    wl_display: *wl.Display,
    wl_registry: *wl.Registry,
    wl_shm: *wl.Shm,
    wl_outputs: *std.AutoHashMapUnmanaged(u32, *wl.Output),

    river_layer_shell_v1: *river.LayerShellV1, // TODO
    river_window_manager_v1: *river.WindowManagerV1,
    river_xkb_bindings_v1: *river.XkbBindingsV1,

    zwlr_layer_shell_v1: *zwlr.LayerShellV1,
    config: *Config,
};

pub fn create(options: Options) !*Context {
    const context = try utils.allocator.create(Context);
    errdefer context.destroy();

    context.* = .{
        .initialized = false,
        .wl_compositor = options.wl_compositor,
        .wl_display = options.wl_display,
        .wl_registry = options.wl_registry,
        .wl_shm = options.wl_shm,
        .wl_outputs = options.wl_outputs,
        .zwlr_layer_shell_v1 = options.zwlr_layer_shell_v1,
        .wallpaper_image = loadWallpaperImage(options.config),
        .wm = try WindowManager.create(context, options.river_window_manager_v1),
        .xkb_bindings = try XkbBindings.create(context, options.river_xkb_bindings_v1),
        .config = options.config,
    };

    return context;
}

pub fn destroy(context: *Context) void {
    context.xkb_bindings.destroy();
    context.wm.destroy();

    if (context.wallpaper_image) |wallpaper_image| {
        wallpaper_image.destroy();
    }
    context.buffer_pool.deinit();

    utils.allocator.destroy(context);
}

pub fn manage(context: *Context) void {
    defer context.pending_manage = .{};

    if (context.pending_manage.config) |new_config| {
        // Destroy all existing bindings
        var it = context.xkb_bindings.bindings.safeIterator(.forward);
        while (it.next()) |binding| {
            binding.link.remove();
            binding.destroy();
        }

        // Check if wallpaper path changed before destroying old config
        const wallpaper_changed = !pathsEqual(
            context.config.wallpaper_image_path,
            new_config.wallpaper_image_path,
        );

        context.config.destroy();
        context.config = new_config;
        context.initialized = false;

        if (wallpaper_changed) {
            if (context.wallpaper_image) |img| img.destroy();
            context.wallpaper_image = loadWallpaperImage(new_config);

            var out_it = context.wm.outputs.iterator(.forward);
            while (out_it.next()) |output| {
                if (context.wallpaper_image == null) {
                    output.deinitWallpaperLayerSurface();
                } else if (output.wl_surface != null) {
                    output.renderWallpaper() catch |err| {
                        log.err("Wallpaper re-render failed: {}", .{err});
                    };
                } else {
                    output.initWallpaperLayerSurface() catch |err| {
                        log.err("Failed to init wallpaper surface: {}", .{err});
                    };
                }
            }
        }
    }
}

fn loadWallpaperImage(config: *Config) ?*WallpaperImage {
    const image_path = config.wallpaper_image_path orelse return null;
    if (image_path.len == 0) return null;
    return WallpaperImage.create(image_path) catch |e| {
        log.err("Failed to load wallpaper image from path \"{s}\": {s}", .{ image_path, @errorName(e) });
        return null;
    };
}

fn pathsEqual(a: ?[]const u8, b: ?[]const u8) bool {
    const a_val = a orelse return b == null;
    const b_val = b orelse return false;
    return mem.eql(u8, a_val, b_val);
}

const std = @import("std");
const mem = std.mem;

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const utils = @import("utils.zig");
const Config = @import("Config.zig");
const BufferPool = @import("BufferPool.zig");
const WallpaperImage = @import("WallpaperImage.zig");
const WindowManager = @import("WindowManager.zig");
const XkbBindings = @import("XkbBindings.zig");

const log = std.log.scoped(.Context);
