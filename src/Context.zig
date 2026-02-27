// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

/// Context to pass Wayland info around.
const Context = @This();

initialized: bool,

env: process.EnvMap,

// Wayland globals
wl_compositor: *wl.Compositor,
wl_display: *wl.Display,
wl_registry: *wl.Registry,
wl_shm: *wl.Shm,

river_layer_shell_v1: *river.LayerShellV1,
zwlr_layer_shell_v1: *zwlr.LayerShellV1,

// Wayland globals that we have special structs for
im: *InputManager,
wm: *WindowManager,
xkb_bindings: *XkbBindings,

/// Pool of Buffers used for rendering wallpapers
buffer_pool: BufferPool = .{},

/// Holds a pixman.Image (and its raw pixels) for the wallpaper
/// (same image on all outputs, but scaled separately)
wallpaper_image: ?*WallpaperImage,

// WM Configuration
config: *Config,

/// Shared timerfd for hiding tag overlays after their timeout expires.
/// This stays null if no tag overlays exist.
tag_overlay_timer_fd: ?posix.fd_t,

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

    river_input_manager_v1: *river.InputManagerV1,
    river_libinput_config_v1: *river.LibinputConfigV1,
    river_layer_shell_v1: *river.LayerShellV1,
    river_window_manager_v1: *river.WindowManagerV1,
    river_xkb_bindings_v1: *river.XkbBindingsV1,

    zwlr_layer_shell_v1: *zwlr.LayerShellV1,
    config: *Config,
};

pub fn create(options: Options) !*Context {
    const context = try utils.gpa.create(Context);
    errdefer utils.gpa.destroy(context);

    const im = try InputManager.create(context, options.river_input_manager_v1, options.river_libinput_config_v1);
    errdefer im.destroy();
    const wm = try WindowManager.create(context, options.river_window_manager_v1);
    errdefer wm.destroy();
    const xkb_bindings = try XkbBindings.create(context, options.river_xkb_bindings_v1);
    errdefer xkb_bindings.destroy();

    const env = try process.getEnvMap(utils.gpa);
    errdefer env.deinit();

    const tag_overlay_timer_fd: ?posix.fd_t = if (options.config.tag_overlay_config) |_|
        posix.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }) catch |e| blk: {
            log.err("Failed to create tag overlay timer: {}", .{e});
            break :blk null;
        }
    else
        null;

    context.* = .{
        .initialized = false,
        .env = env,
        .wl_compositor = options.wl_compositor,
        .wl_display = options.wl_display,
        .wl_registry = options.wl_registry,
        .wl_shm = options.wl_shm,
        .river_layer_shell_v1 = options.river_layer_shell_v1,
        .zwlr_layer_shell_v1 = options.zwlr_layer_shell_v1,
        .wallpaper_image = loadWallpaperImage(options.config),
        .im = im,
        .wm = wm,
        .xkb_bindings = xkb_bindings,
        .config = options.config,
        .tag_overlay_timer_fd = tag_overlay_timer_fd,
    };

    return context;
}

pub fn destroy(context: *Context) void {
    context.env.deinit();
    context.im.destroy();
    context.wm.destroy();
    context.xkb_bindings.destroy();

    if (context.wallpaper_image) |wallpaper_image| {
        wallpaper_image.destroy();
    }
    if (context.tag_overlay_timer_fd) |fd| posix.close(fd);
    context.buffer_pool.deinit();

    // Destroy Wayland globals
    context.river_layer_shell_v1.destroy();
    context.zwlr_layer_shell_v1.destroy();
    context.wl_shm.destroy();
    context.wl_compositor.destroy();
    context.wl_registry.destroy();

    utils.gpa.destroy(context);
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

        // Capture old config state before destroying
        const had_overlay = context.config.tag_overlay_config != null;
        const had_bar = context.config.bar_config != null;

        // Check if wallpaper path changed before destroying old config
        const wallpaper_changed = !pathsEqual(
            context.config.wallpaper_image_path,
            new_config.wallpaper_image_path,
        );

        context.config.destroy();
        context.config = new_config;
        context.initialized = false;

        // Update output defaults from new config
        var out_it_cfg = context.wm.outputs.iterator(.forward);
        while (out_it_cfg.next()) |output| {
            output.primary_ratio = new_config.primary_ratio;
            output.primary_count = new_config.primary_count;
            output.single_window_ratio = new_config.single_window_ratio;
        }

        // Mark all libinput devices as needing config re-application
        var dev_it = context.im.libinput_devices.iterator(.forward);
        while (dev_it.next()) |libinput_device| {
            libinput_device.should_manage = true;
        }

        // Handle tag overlay config changes
        const has_overlay = new_config.tag_overlay_config != null;

        if (!had_overlay and has_overlay) {
            // Create timerfd for newly enabled tag overlay
            context.tag_overlay_timer_fd = posix.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true }) catch |e| blk: {
                log.err("Failed to create tag overlay timer: {}", .{e});
                break :blk null;
            };
        } else if (had_overlay and !has_overlay) {
            // Close timerfd for disabled tag overlay
            if (context.tag_overlay_timer_fd) |fd| posix.close(fd);
            context.tag_overlay_timer_fd = null;
        }

        // Recreate or destroy tag overlays on all outputs
        if (had_overlay or has_overlay) {
            var out_it = context.wm.outputs.iterator(.forward);
            while (out_it.next()) |output| {
                // Destroy existing overlay
                if (output.tag_overlay) |*tag_overlay| {
                    tag_overlay.deinit();
                    output.tag_overlay = null;
                }
                // Create new overlay if configured
                // Create new overlay struct if configured (surfaces created on-demand)
                if (new_config.tag_overlay_config) |tag_overlay_config| {
                    output.tag_overlay = TagOverlay.init(context, output, tag_overlay_config.toTagOverlayOptions()) catch |e| {
                        log.err("Failed to create tag overlay: {}", .{e});
                        continue;
                    };
                }
            }
        }

        // Update, create, or destroy bars on all outputs
        const has_bar = new_config.bar_config != null;
        if (had_bar or has_bar) {
            var out_it = context.wm.outputs.iterator(.forward);
            while (out_it.next()) |output| {
                if (new_config.bar_config) |bar_config| {
                    if (output.bar) |*bar| {
                        // Existing bar; reconfigure in-place to keep surfaces
                        bar.reconfigure(bar_config.toBarOptions()) catch |e| {
                            log.err("Failed to reconfigure bar: {}", .{e});
                            bar.deinit();
                            output.bar = null;
                            continue;
                        };
                    } else {
                        // No bar; we need to initialize a new one
                        output.bar = Bar.init(context, output, bar_config.toBarOptions()) catch |e| {
                            log.err("Failed to create bar: {}", .{e});
                            continue;
                        };
                    }
                } else {
                    // New config doesn't have a bar; destroy existing one
                    if (output.bar) |*bar| {
                        bar.deinit();
                        output.bar = null;
                    }
                }
            }
        }

        if (wallpaper_changed) {
            if (context.wallpaper_image) |img| img.destroy();
            context.wallpaper_image = loadWallpaperImage(new_config);

            var out_it = context.wm.outputs.iterator(.forward);
            while (out_it.next()) |output| {
                if (context.wallpaper_image == null) {
                    output.deinitWallpaperLayerSurface();
                } else if (output.surfaces != null) {
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

    // Apply input configs for new or reconfigured devices
    var dev_it = context.im.libinput_devices.iterator(.forward);
    while (dev_it.next()) |libinput_device| {
        libinput_device.manage();
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
const posix = std.posix;
const process = std.process;

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const utils = @import("utils.zig");
const Bar = @import("Bar.zig");
const BufferPool = @import("BufferPool.zig");
const Config = @import("Config.zig");
const InputManager = @import("InputManager.zig");
const Output = @import("Output.zig");
const TagOverlay = @import("TagOverlay.zig");
const WallpaperImage = @import("WallpaperImage.zig");
const WindowManager = @import("WindowManager.zig");
const XkbBindings = @import("XkbBindings.zig");

const log = std.log.scoped(.Context);
