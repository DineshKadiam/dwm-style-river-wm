// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Output = @This();

context: *Context,

river_output_v1: *river.OutputV1,
river_layer_shell_output_v1: *river.LayerShellOutputV1,

// We have to wait for the rwm.wl_output event to get this
wl_output: ?*wl.Output = null,

// Friendly name of this output
name: ?[]const u8 = null,

// Output geometry
scale: u31 = 1,
geometry: Rect = .{},

// Area available for window layout (output geometry minus bar space)
// Maybe I'll re-add support for layer shell exclusive areas later,
// but adding that makes it more work for me and I don't personally
// know of anything that makes me want them since external bars won't
// work with beansprout.
usable_geometry: Rect = .{},

// Information for this Output's wallpaper
wallpaper_render_scale: u31 = 0,
wallpaper_render_width: u31 = 0,
wallpaper_render_height: u31 = 0,

surfaces: ?struct {
    wl_surface: *wl.Surface,
    layer_surface: *zwlr.LayerSurfaceV1,
} = null,

bar: ?Bar,
tag_overlay: ?TagOverlay,

/// Proportion of output width taken by the primary stack
primary_ratio: f32,

/// Number of windows in the primary stack
primary_count: u8,

/// Proportion of output width taken by a window when it is the only visible tiled window
single_window_ratio: f32,

/// Per-tagmask layout overrides
/// These only get added when the user modifies primary count or ratio
/// Any tagmask NOT in this map keeps using the defaults from Config
tag_layout_overrides: std.AutoHashMapUnmanaged(u32, TagLayoutOverride) = .{},

/// Tags are 32-bit bitfield. A window can be active on one(?) or more tags.
tags: u32 = 0x0001,

/// State consumed in manage() phase, reset at end of manage().
pending_manage: PendingManage = .{},

/// Used for wallpaper rendering management
configured: bool = false,

windows: wl.list.Head(Window, .link),

link: wl.list.Link,

/// Struct used for tagmask-specific count/ratio overrides
pub const TagLayoutOverride = struct {
    primary_count: u8,
    primary_ratio: f32,
};

pub const PendingManage = struct {
    position: ?struct { x: i32, y: i32 } = null,
    dimensions: ?struct { width: u31, height: u31 } = null,

    tags: ?u32 = null,
    primary_ratio: ?f32 = null,
    primary_count: ?u8 = null,
    single_window_ratio: ?f32 = null,
};

pub fn create(context: *Context, river_output_v1: *river.OutputV1) !*Output {
    var output = try utils.gpa.create(Output);
    errdefer utils.gpa.destroy(output);

    output.* = .{
        .context = context,
        .river_output_v1 = river_output_v1,
        .river_layer_shell_output_v1 = try context.river_layer_shell_v1.getOutput(river_output_v1),
        .bar = null,
        .tag_overlay = null,
        .primary_count = context.config.primary_count,
        .primary_ratio = context.config.primary_ratio,
        .single_window_ratio = context.config.single_window_ratio,
        .windows = undefined, // we will initialize this shortly
        .link = undefined, // Handled by the wl.list
    };

    output.bar = if (context.config.bar_config) |bar_config| blk: {
        break :blk Bar.init(context, output, bar_config.toBarOptions()) catch |e| {
            log.err("Failed to create a bar: {}", .{e});
            break :blk null;
        };
    } else null;
    errdefer if (output.bar) |*b| b.deinit();

    output.tag_overlay = if (context.config.tag_overlay_config) |tag_overlay_config| blk: {
        break :blk TagOverlay.init(context, output, tag_overlay_config.toTagOverlayOptions()) catch |e| {
            log.err("Failed to create a tag overlay: {}", .{e});
            break :blk null;
        };
    } else null;
    errdefer if (output.tag_overlay) |*to| to.deinit();

    output.windows.init();

    output.river_output_v1.setListener(*Output, riverOutputListener, output);

    return output;
}

pub fn destroy(output: *Output) void {
    // Destroy any windows left on the Output
    // This *should* be empty
    var it = output.windows.safeIterator(.forward);
    while (it.next()) |window| {
        window.link.remove();
        window.destroy();
    }

    // Deinit optional surfaces
    if (output.bar) |*bar| bar.deinit();
    if (output.tag_overlay) |*tag_overlay| tag_overlay.deinit();
    output.deinitWallpaperLayerSurface();

    // Destroy/deinit other Output fields
    output.tag_layout_overrides.deinit(utils.gpa);
    if (output.name) |name| utils.gpa.free(name);

    // Destroy/release relevant Wayland interfaces
    output.river_layer_shell_output_v1.destroy();
    output.river_output_v1.destroy();
    if (output.wl_output) |wl_output| wl_output.release();

    utils.gpa.destroy(output);
}

/// Get the next window in the list that shares at least one tag
/// with the output, wrapping to first if at end.
pub fn nextWindow(output: *Output, current: *Window) ?*Window {
    var link = current.link.next.?;
    // Walk forward, wrapping at sentinel, until we find a visible window or return to current
    while (true) {
        // If this is the sentinel, wrap to the beginning
        if (link == &output.windows.link) {
            link = link.next.?;
        }
        const window: *Window = @fieldParentPtr("link", link);
        if (window.tags & output.tags != 0 or window == current) return window;
        link = link.next.?;
    }
}

/// Get the previous window in the list that shares at least one tag
/// with the output, wrapping to the last if at beginning
pub fn prevWindow(output: *Output, current: *Window) ?*Window {
    var link = current.link.prev.?;
    while (true) {
        // If this is the sentinel, wrap to the end
        if (link == &output.windows.link) {
            link = link.prev.?;
        }
        const window: *Window = @fieldParentPtr("link", link);
        if (window.tags & output.tags != 0 or window == current) return window;
        link = link.prev.?;
    }
}

// Used for the river_output_v1 interface
fn riverOutputListener(river_output_v1: *river.OutputV1, event: river.OutputV1.Event, output: *Output) void {
    assert(output.river_output_v1 == river_output_v1);
    switch (event) {
        .removed => {
            const context = output.context;
            const wm = context.wm;

            // Move windows to the previous output in the list.
            // If this was the only output, windows become orphans.
            const prev_output: ?*Output = if (wm.prevOutput(output)) |prev| blk: {
                if (prev == output) break :blk null; // Only output; wrapped to itself
                break :blk prev; // We got the previous list
            } else unreachable;

            const window_pending_output: Window.PendingManage.PendingOutput =
                if (prev_output) |prev|
                    .{ .output = prev }
                else
                    .clear_output;

            // Update each window's output before moving the list
            var it = output.windows.iterator(.forward);
            while (it.next()) |window| {
                window.pending_manage.pending_output = window_pending_output;
            }

            // Move windows to new destination
            const dest_list = if (prev_output) |prev| &prev.windows else &wm.orphan_windows;
            dest_list.appendList(&output.windows);

            blk: {
                // If the removed output was focused, move focus to the next
                // available output (and its first window, if any).
                const seat = wm.seats.first() orelse break :blk;
                if (seat.focused_output != output) break :blk;

                const next_output = wm.nextOutput(output);
                if (next_output == output or next_output == null) {
                    // This was the last output; clear focus
                    seat.pending_manage.output = .clear_focus;
                    seat.pending_manage.window = .clear_focus;
                    break :blk;
                }
                const o = next_output.?;

                seat.pending_manage.output = .{ .output = o };
                if (o.windows.first()) |window| {
                    seat.pending_manage.window = .{ .window = window };
                }
            }

            output.link.remove();
            output.destroy();
        },
        .wl_output => |ev| {
            // Bind the wl_output here so that our listener is set before the server sends the
            // initial events (.scale, .mode, .name, .done, etc.). The .done handler will init
            // bar/wallpaper surfaces.
            const wl_output = output.context.wl_registry.bind(
                ev.name,
                wl.Output,
                4,
            ) catch |err| {
                log.err("Failed to bind wl_output: {}", .{err});
                return;
            };
            wl_output.setListener(*Output, wlOutputListener, output);
            output.wl_output = wl_output;
        },
        .dimensions => |ev| {
            // Protocol guarantees that width and height are strictly greater than zero
            assert(ev.width > 0 and ev.height > 0);
            output.pending_manage.dimensions = .{
                .width = @intCast(ev.width),
                .height = @intCast(ev.height),
            };
        },
        .position => |ev| {
            output.pending_manage.position = .{
                .x = ev.x,
                .y = ev.y,
            };
        },
    }
}

// Used for the wl_output global interface that corresponds to the river_output_v1
fn wlOutputListener(_: *wl.Output, event: wl.Output.Event, output: *Output) void {
    switch (event) {
        .done => {
            output.initWallpaperLayerSurface() catch |err| {
                const output_name = output.name orelse "some output";
                log.err("failed to add a surface to {s}: {}", .{ output_name, err });
                return;
            };
            if (output.bar) |*bar| {
                // Trigger a full manage cycle if the scale changed so that
                // fonts are reloaded and bar geometry is recalculated.
                if (output.scale != bar.font_scale) {
                    bar.pending_manage.output_geometry = true;
                }
            }
            // Re-render wallpaper if scale changed
            if (output.configured and output.scale != output.wallpaper_render_scale) {
                output.renderWallpaper() catch |err| {
                    log.err("Wallpaper render failed: {}", .{err});
                };
            }
        },
        .scale => |ev| {
            if (ev.factor < 0) {
                // I'm not actually sure if this is possible, but just to be safe
                log.warn("Received wl_output.scale event with a negative factor ({d})", .{ev.factor});
                return;
            }
            output.scale = @intCast(ev.factor);
        },
        .name => |ev| {
            if (output.name) |old_name| utils.gpa.free(old_name);
            output.name = utils.gpa.dupe(u8, mem.span(ev.name)) catch @panic("Out of memory");
        },
        else => {},
    }
}

pub fn initWallpaperLayerSurface(output: *Output) !void {
    if (output.context.wallpaper_image == null) {
        // No wallpaper image, so we don't need any surfaces
        return;
    }

    if (output.surfaces) |_| {
        // This output already has a surface, we can exit early
        return;
    }

    const context = output.context;

    const wl_surface = try context.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    const layer_surface = try context.zwlr_layer_shell_v1.getLayerSurface(wl_surface, output.wl_output, .background, "beansprout-wallpaper");
    errdefer layer_surface.destroy();

    // We don't want our surface to have any input region (default is infinite)
    const empty_region = try context.wl_compositor.createRegion();
    defer empty_region.destroy();
    wl_surface.setInputRegion(empty_region);

    // Full surface should be opaque
    const opaque_region = try context.wl_compositor.createRegion();
    opaque_region.add(0, 0, output.geometry.width, output.geometry.height);
    defer opaque_region.destroy();
    wl_surface.setOpaqueRegion(opaque_region);

    layer_surface.setExclusiveZone(-1);
    layer_surface.setAnchor(.{ .top = true, .right = true, .bottom = true, .left = true });

    output.surfaces = .{
        .wl_surface = wl_surface,
        .layer_surface = layer_surface,
    };
    context.buffer_pool.surface_count += 1;

    layer_surface.setListener(*Output, wallpaperLayerSurfaceListener, output);
    wl_surface.commit();
}

pub fn deinitWallpaperLayerSurface(output: *Output) void {
    if (output.surfaces) |surfaces| {
        surfaces.layer_surface.destroy();
        surfaces.wl_surface.destroy();
        output.context.buffer_pool.surface_count -= 1;
    }

    output.surfaces = null;
    output.configured = false;
}

fn wallpaperLayerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, output: *Output) void {
    switch (event) {
        .configure => |ev| {
            layer_surface.ackConfigure(ev.serial);

            const width: u31 = @intCast(ev.width);
            const height: u31 = @intCast(ev.height);

            if (output.configured and
                output.wallpaper_render_width == width and
                output.wallpaper_render_height == height and
                output.scale == output.wallpaper_render_scale)
            {
                if (output.surfaces) |surfaces| {
                    surfaces.wl_surface.commit();
                } else {
                    log.warn("Output is marked as configured but is missing its surfaces.", .{});
                }
                return;
            }

            log.debug("configuring wallpaper surface with width {} and height {}", .{ width, height });
            output.wallpaper_render_width = width;
            output.wallpaper_render_height = height;
            output.configured = true;

            output.renderWallpaper() catch |err| {
                log.err("Wallpaper render failed: {}", .{err});
            };
        },
        .closed => {
            output.deinitWallpaperLayerSurface();
        },
    }
}

/// Calculates image_dimension / (output_dimension * scale)
fn calculateScale(image_dimension: c_int, output_dimension: u31, scale: u31) f64 {
    const numerator: f64 = @floatFromInt(image_dimension);
    const denominator: f64 = @floatFromInt(output_dimension * scale);

    return numerator / denominator;
}

/// Calculates (image_dimension / dimension_scale - output_dimension) / 2 / dimension_scale
fn calculateTransform(image_dimension: c_int, output_dimension: u31, dimension_scale: f64) f64 {
    const numerator1: f64 = @floatFromInt(image_dimension);
    const denominator1: f64 = dimension_scale;
    const subtrahend: f64 = @floatFromInt(output_dimension);
    const numerator2: f64 = numerator1 / denominator1 - subtrahend;

    return numerator2 / 2 / dimension_scale;
}

/// Render the wallpaper image onto the layer surface
pub fn renderWallpaper(output: *Output) !void {
    const context = output.context;
    const width = output.wallpaper_render_width;
    const height = output.wallpaper_render_height;
    const scale = output.scale;

    // Don't have anything to render
    if (width == 0 or height == 0 or scale == 0) {
        return;
    }
    // Scale our loaded image and then copy it into the Buffer's pixman.Image
    const wallpaper_image = context.wallpaper_image orelse return error.MissingWallpaperImage;
    const image = wallpaper_image.pix_image;
    const image_data = image.getData();
    const image_width = image.getWidth();
    const image_height = image.getHeight();
    const image_stride = image.getStride();
    const image_format = image.getFormat();

    const buffer = try context.buffer_pool.nextBuffer(context.wl_shm, width * scale, height * scale);

    const pix = pixman.Image.createBitsNoClear(image_format, image_width, image_height, image_data, image_stride) orelse {
        log.err("Failed to copy the wallpaper image for rendering", .{});
        return error.FailedToCreatePixmanImage;
    };
    defer _ = pix.unref();

    // Calculate image scale
    var sx: f64 = @as(f64, @floatFromInt(image_width)) / @as(f64, @floatFromInt(width * scale));
    var sy: f64 = calculateScale(image_height, height, scale);

    const s = if (sx > sy) sy else sx;
    sx = s;
    sy = s;

    // Calculate translation offsets to center the image on the output.
    // If the scaled image is larger than the output, the offset crops equally from both sides.
    const tx: f64 = calculateTransform(image_width, width * scale, sx);
    const ty: f64 = calculateTransform(image_height, height * scale, sy);

    // Build a combined source-to-destination transform matrix.
    // Pixman transforms map destination pixels back to source pixels, so:
    //   t_scale: maps a destination pixel to the corresponding source pixel (scaling)
    //   t_trans: shifts the sampling point to center the image
    //   t = t_trans * t_scale: first scale, then translate (in source space)
    var t_scale: pixman.FTransform = undefined;
    var t_trans: pixman.FTransform = undefined;
    var t: pixman.FTransform = undefined;
    // t2 is the fixed-point version of t, which is what pixman actually uses internally
    var t2: pixman.Transform = undefined;

    pixman.FTransform.initScale(&t_scale, sx, sy);
    pixman.FTransform.initTranslate(&t_trans, tx, ty);
    pixman.FTransform.multiply(&t, &t_trans, &t_scale);
    _ = pixman.Transform.fromFTransform(&t2, &t);
    _ = pix.setTransform(&t2);
    _ = pix.setFilter(.best, &[_]pixman.Fixed{}, 0);

    // Combine the transformed source image into the buffer.
    pixman.Image.composite32(.src, pix, null, buffer.pixman_image, 0, 0, 0, 0, 0, 0, width * scale, height * scale);

    log.info("render: {}x{} (scaled from {}x{})", .{ width * scale, height * scale, image_width, image_height });

    // Attach the buffer to the surface
    const surfaces = output.surfaces orelse return error.NoSurfaces;
    const wl_surface = surfaces.wl_surface;
    wl_surface.setBufferScale(scale);
    wl_surface.attach(buffer.wl_buffer, 0, 0);
    wl_surface.damageBuffer(0, 0, width * scale, height * scale);
    wl_surface.commit();

    output.wallpaper_render_scale = scale;
}

pub fn manage(output: *Output) void {
    defer output.pending_manage = .{};

    if (output.pending_manage.position) |position| {
        output.geometry.x = position.x;
        output.geometry.y = position.y;
    }
    if (output.pending_manage.dimensions) |dimensions| {
        output.geometry.width = dimensions.width;
        output.geometry.height = dimensions.height;
    }

    if (output.pending_manage.position != null or output.pending_manage.dimensions != null) {
        if (output.bar) |*bar| {
            bar.pending_manage.output_geometry = true;
        }
    }

    if (output.pending_manage.primary_ratio) |primary_ratio| {
        // Ratios outside of this range could cause crashes (when doing the layout calculation)
        output.primary_ratio = std.math.clamp(
            primary_ratio,
            Config.min_primary_ratio,
            Config.max_primary_ratio,
        );
        if (output.bar) |*bar| {
            bar.pending_render.draw = true;
        }
    }
    if (output.pending_manage.primary_count) |primary_count| {
        // Don't allow less than 1 primary
        output.primary_count = @max(1, primary_count);
        if (output.bar) |*bar| {
            bar.pending_render.draw = true;
        }
    }
    if (output.pending_manage.single_window_ratio) |single_window_ratio| {
        output.single_window_ratio = std.math.clamp(
            single_window_ratio,
            Config.min_primary_ratio,
            1.00,
        );
    }

    if (output.pending_manage.tags) |new_tags| {
        // Save current layout for the old tagmask
        output.tag_layout_overrides.put(utils.gpa, output.tags, .{
            .primary_count = output.primary_count,
            .primary_ratio = output.primary_ratio,
        }) catch @panic("Out of memory");

        // Restore layout for the new tagmask, or fall back to config defaults
        if (output.tag_layout_overrides.get(new_tags)) |tag_layout_override| {
            output.primary_count = tag_layout_override.primary_count;
            output.primary_ratio = tag_layout_override.primary_ratio;
        } else {
            output.primary_count = output.context.config.primary_count;
            output.primary_ratio = output.context.config.primary_ratio;
        }

        output.tags = new_tags;

        // If the focused window is no longer visible on the new tags, update focus.
        if (output.context.wm.seats.first()) |seat| {
            if (seat.focused_output == output) {
                // Whether focus has changed, either to a new window or to no focus
                const should_update_focus = if (seat.focused_window) |w|
                    w.tags & new_tags == 0
                else
                    true;
                if (should_update_focus) {
                    var new_focus: ?*Window = null;
                    var it = output.windows.iterator(.forward);
                    while (it.next()) |window| {
                        if (window.tags & new_tags != 0) {
                            new_focus = window;
                            break;
                        }
                    }
                    if (new_focus) |w| {
                        seat.pending_manage.window = .{ .window = w };
                        seat.pending_manage.should_warp_pointer = true;
                    } else {
                        seat.pending_manage.window = .clear_focus;
                    }
                }
            }
        }

        // Show tag overlay and arm the hide timer
        if (output.tag_overlay) |*tag_overlay| {
            if (tag_overlay.surfaces) |_| {
                // The overlay is already visible, but we still need to re-render
                tag_overlay.render() catch |err| {
                    log.err("tag_overlay render failed: {}", .{err});
                };
            } else {
                // Create surface; the configure handler renders for us
                tag_overlay.initSurface() catch |err| {
                    log.err("tag_overlay initSurface failed: {}", .{err});
                };
            }
            if (output.context.tag_overlay_timer_fd) |fd| {
                const timeout_ms: isize = tag_overlay.options.timeout;
                posix.timerfd_settime(fd, .{}, &.{
                    .it_interval = .{ .sec = 0, .nsec = 0 },
                    .it_value = .{
                        .sec = @divFloor(timeout_ms, 1000),
                        .nsec = @mod(timeout_ms, 1000) * std.time.ns_per_ms,
                    },
                }, null) catch |err| {
                    log.err("Failed to arm tag overlay timer: {}", .{err});
                };
            }
        }

        if (output.bar) |*bar| {
            bar.pending_render.draw = true;
        }
    }

    if (output.bar) |*bar| {
        bar.manage() catch |err| {
            log.err("Bar manage failed: {}", .{err});
        };
    }

    // Compute usable geometry from output geometry minus bar space.
    // We don't use non_exclusive_area from layer shell since we don't support
    // other layer shell clients with exclusive zones (layer shell clients that
    // don't use exclusive areas are fine).
    output.usable_geometry = output.geometry;
    if (output.bar) |bar| {
        if (bar.geometry.height > 0) {
            const bar_height: i32 = bar.geometry.height;
            const margins = bar.options.margins;
            const reserved: u31 = @intCast(bar_height + margins.top + margins.bottom);
            switch (bar.options.position) {
                .top => {
                    output.usable_geometry.y += bar_height + margins.top + margins.bottom;
                    output.usable_geometry.height -|= reserved;
                },
                .bottom => {
                    output.usable_geometry.height -|= reserved;
                },
            }
        }
    }

    // Calculate layout before managing windows, but only if output dimensions are initialized
    if (output.usable_geometry.width > 0 and output.usable_geometry.height > 0) {
        output.calculateLayout();
    }

    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        window.manage();
    }
}

pub fn render(output: *Output) void {
    if (output.bar) |*bar| {
        bar.render();
    }

    const seat = output.context.wm.seats.first();
    const focused = if (seat) |s| s.focused_window else null;

    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        window.render();

        // Make sure floating windows are above tiled windows
        if (window.floating and output.tags & window.tags != 0 and window != focused) {
            window.river_node_v1.placeTop();
        }
    }

    // Make sure that the *focused* floating window goes above any other floating windows
    if (focused) |f| {
        if (f.floating and f.output == output and output.tags & f.tags != 0) {
            f.river_node_v1.placeTop();
        }
    }
}

/// Calculate primary/stack layout positions for all windows.
/// - Single window: window is told it's maximized and takes up usable_width * single_window_ratio width
/// - Multiple windows: two stacks, primary and secondary. By default, the stack is on the right and takes
///     up 55% of the output width, but this can be configured. Each tagmask has its own primary ratio and count.
fn calculateLayout(output: *Output) void {
    // Shouldn't be called if height/width are not positive
    assert(output.geometry.width > 0 and output.geometry.height > 0);
    // Get a list of active tiled windows
    // i.e. any windows that are on this output with at least one active tag and aren't fullscreen or floating
    var active_list: DoublyLinkedList = .{};
    var active_count: u31 = 0;
    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        // Initialize new windows before checking tags/float so that
        // window rules are reflected in the first frame's layout.
        window.initialize();
        if (output.tags & window.tags != 0x0000) {
            // Fullscreen and floating windows should be shown but not included in layout generation
            const will_be_fullscreen = window.pending_manage.fullscreen orelse window.fullscreen;
            const will_float = window.pending_manage.floating orelse window.floating;
            if (!will_be_fullscreen and !will_float) {
                active_count += 1;
                active_list.append(&window.active_list_node);
            }
            window.pending_render.show = true;
        } else {
            window.pending_render.show = false;
        }
    }

    if (active_count == 0) return;

    // Use the usable area for layout so windows don't overlap the bar
    const output_x = output.usable_geometry.x;
    const output_y = output.usable_geometry.y;
    const output_width = output.usable_geometry.width;
    const output_height = output.usable_geometry.height;
    const border_width = output.context.config.border_width;

    // Single window: maximize and return early
    if (active_count == 1) {
        const window: *Window = @fieldParentPtr("active_list_node", active_list.popFirst().?);

        const width = @as(u31, @intFromFloat(@as(f32, @floatFromInt(output_width)) * output.single_window_ratio)) -|
            2 * border_width;
        const x = output_x + @divFloor(output_width - width, 2);

        window.pending_render.position = .{ .x = x, .y = output_y + border_width };
        window.pending_manage.dimensions = .{
            .width = width,
            .height = output_height -| 2 * border_width,
        };
        window.pending_manage.maximized = true;
        return;
    }

    // Multiple windows: primary/stack layout
    const primary_count = @min(active_count, output.primary_count);
    const stack_count = active_count - primary_count;

    // Primary width is equal to output width when all windows are primaries
    // (since there would be no secondaries)
    const primary_width: u31 = if (primary_count == active_count)
        output_width
    else
        @intFromFloat(@as(f32, @floatFromInt(output_width)) * output.primary_ratio);
    const primary_height: u31 = @divFloor(output_height, primary_count);

    const stack_width: u31 = output_width - primary_width;
    const stack_height: u31 = if (stack_count > 0)
        @divFloor(output_height, stack_count)
    else
        0;

    // Determine the stack x coordinates based on whether primary is set to the left or right
    const primary_x, const stack_x = switch (output.context.config.primary_side) {
        .right => .{ output_x + @as(i32, stack_width), output_x },
        .left => .{ output_x, output_x + @as(i32, primary_width) },
    };

    // Iterate through the active windows and apply positions
    var i: u31 = 0;
    while (active_list.popFirst()) |node| : (i += 1) {
        const window: *Window = @fieldParentPtr("active_list_node", node);
        window.pending_manage.maximized = false;

        if (i < primary_count) {
            // Primary window(s)
            window.pending_render.position = .{
                .x = primary_x,
                .y = output_y + @as(i32, i) * @as(i32, primary_height),
            };
            const pending_width = primary_width;
            // Last primary window gets remaining height to avoid gaps from integer division
            const pending_height = if (i == primary_count - 1)
                output_height - i * primary_height
            else
                primary_height;
            window.pending_manage.dimensions = .{
                .width = pending_width,
                .height = pending_height,
            };
        } else {
            // Stack window(s)
            const stack_index = i - primary_count;
            window.pending_render.position = .{
                .x = stack_x,
                .y = output_y + @as(i32, stack_index) * @as(i32, stack_height),
            };
            const pending_width = stack_width;
            // Last stack window gets remaining height to avoid gaps from integer division
            const pending_height = if (stack_index == stack_count - 1)
                output_height - stack_index * stack_height
            else
                stack_height;
            window.pending_manage.dimensions = .{
                .width = pending_width,
                .height = pending_height,
            };
        }

        // Make space for borders
        if (window.pending_manage.dimensions.?.height > 2 * border_width and
            window.pending_manage.dimensions.?.width > 2 * border_width)
        {
            window.pending_manage.dimensions.?.height -= 2 * border_width;
            window.pending_manage.dimensions.?.width -= 2 * border_width;
        } else {
            log.warn("Can't add borders to some window; {s}'s dimensions are too small.", .{output.name orelse "some output"});
        }
        window.pending_render.position.?.x += border_width;
        window.pending_render.position.?.y += border_width;
    }

    // Make sure we went through the whole list
    assert(active_list.first == null);
}

pub fn occupiedTags(output: *Output) u32 {
    var occupied_tags: u32 = 0x0000;
    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        occupied_tags |= window.tags;
    }
    return occupied_tags;
}

pub fn countVisible(output: *Output) usize {
    var visible: usize = 0;
    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window.tags & output.tags != 0) visible += 1;
    }
    return visible;
}

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const posix = std.posix;
const DoublyLinkedList = std.DoublyLinkedList;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const zwlr = wayland.client.zwlr;
const pixman = @import("pixman");

const utils = @import("utils.zig");
const Rect = utils.Rect;
const Bar = @import("Bar.zig");
const Buffer = @import("Buffer.zig");
const Config = @import("Config.zig");
const Context = @import("Context.zig");
const TagOverlay = @import("TagOverlay.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.Output);
