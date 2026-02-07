// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Output = @This();

context: *Context,

river_output_v1: *river.OutputV1,

// We have to wait for the rwm.wl_output event to get this
wl_output: ?*wl.Output = null,

// Output geometry
scale: u31 = 0,
width: u31 = 0,
height: u31 = 0,
x: i32 = 0,
y: i32 = 0,

// Information for this Output's wallpaper
render_width: u31 = 0,
render_height: u31 = 0,
wl_surface: ?*wl.Surface = null,
layer_surface: ?*zwlr.LayerSurfaceV1 = null,

/// Proportion of output width taken by the primary stack
primary_ratio: f32 = 0.55,

/// Number of windows in the primary stack
primary_count: u8 = 1,

/// Tags are 32-bit bitfield. A window can be active on one(?) or more tags.
tags: u32 = 0x0001,

/// State consumed in manage() phase, reset at end of manage().
pending_manage: PendingManage = .{},

// Friendly name of this output
name: ?[]const u8 = null,

/// Used for wallpaper rendering management
configured: bool = false,

windows: wl.list.Head(Window, .link),

link: wl.list.Link,

pub const PendingManage = struct {
    width: ?u31 = null,
    height: ?u31 = null,
    x: ?i32 = null,
    y: ?i32 = null,

    tags: ?u32 = null,
    primary_ratio: ?f32 = null,
    primary_count: ?u8 = null,
};

pub fn create(context: *Context, river_output_v1: *river.OutputV1) !*Output {
    var output = try utils.allocator.create(Output);
    errdefer output.destroy();

    output.* = .{
        .context = context,
        .river_output_v1 = river_output_v1,
        .windows = undefined, // we will initialize this shortly
        .link = undefined, // Handled by the wl.list
    };

    output.windows.init();

    output.river_output_v1.setListener(*Output, riverOutputListener, output);

    return output;
}

pub fn destroy(output: *Output) void {
    var it = output.windows.safeIterator(.forward);
    while (it.next()) |window| {
        window.link.remove();
        window.destroy();
    }

    output.deinitWallpaperLayerSurface();
    output.river_output_v1.destroy();
    utils.allocator.destroy(output);
}

/// Get the next window in the list, wrapping to first if at end
pub fn nextWindow(output: *Output, current: *Window) ?*Window {
    const next_link = current.link.next orelse return output.windows.first();
    // If we've reached the sentinel (head's link), wrap to first
    if (next_link == &output.windows.link) return output.windows.first();
    return @fieldParentPtr("link", next_link);
}

/// Get the previous window in the list, wrapping to last if at beginning
pub fn prevWindow(output: *Output, current: *Window) ?*Window {
    const prev_link = current.link.prev orelse return output.windows.last();
    // If we've reached the sentinel (head's link), wrap to last
    if (prev_link == &output.windows.link) return output.windows.last();
    return @fieldParentPtr("link", prev_link);
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
                // TODO: Support multiple seats
                const seat = wm.seats.first() orelse break :blk;
                if (seat.focused_output != output) break :blk;

                const next_output = wm.nextOutput(output);
                if (next_output == output) break :blk;
                const o = next_output orelse break :blk;

                seat.pending_manage.output = .{ .output = o };
                if (o.windows.first()) |window| {
                    seat.pending_manage.window = .{ .window = window };
                }
            }

            output.link.remove();
            output.destroy();
        },
        .wl_output => |ev| {
            // It's guaranteed for the wl_output global to advertised before this event happens
            output.wl_output = output.context.wl_outputs.get(ev.name) orelse unreachable;
            output.wl_output.?.setListener(*Output, wlOutputListener, output);
        },
        .dimensions => |ev| {
            // Protocol guarantees that width and height are strictly greater than zero
            assert(ev.width > 0 and ev.height > 0);
            output.pending_manage.width = @intCast(ev.width);
            output.pending_manage.height = @intCast(ev.height);
        },
        .position => |ev| {
            output.pending_manage.x = ev.x;
            output.pending_manage.y = ev.y;
        },
    }
}

// Used for the wl_output global interface that corresponds to the river_output_v1
fn wlOutputListener(_: *wl.Output, event: wl.Output.Event, output: *Output) void {
    switch (event) {
        .mode => |ev| {
            if (ev.width < 0 or ev.height < 0) {
                // I'm not actually sure if this is possible, but just to be safe
                log.warn("Received wl_output.mode event with a negative width or height ({d}x{d})", .{ ev.width, ev.height });
                return;
            }

            output.width = @intCast(ev.width);
            output.height = @intCast(ev.height);
        },
        .done => {
            output.initWallpaperLayerSurface() catch |err| {
                const output_name = output.name orelse "some output";
                log.err("failed to add a surface to {s}: {}", .{ output_name, err });
                return;
            };
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
            output.name = utils.allocator.dupe(u8, mem.span(ev.name)) catch @panic("Out of memory");
        },
        else => {},
    }
}

fn initWallpaperLayerSurface(output: *Output) !void {
    if (output.context.wallpaper_image == null) {
        // No wallpaper image, so we don't need any surfaces
        return;
    }

    if (output.wl_surface) |_| {
        log.warn("Skipping adding a second wallpaper surface to {s}", .{output.name orelse "some output"});
        return;
    }

    const context = output.context;

    const wl_surface: *wl.Surface = try context.wl_compositor.createSurface();

    // We don't want our surface to have any input region (default is infinite)
    const empty_region: *wl.Region = try context.wl_compositor.createRegion();
    defer empty_region.destroy();
    wl_surface.setInputRegion(empty_region);

    // Full surface should be opaque
    const opaque_region: *wl.Region = try context.wl_compositor.createRegion();
    defer opaque_region.destroy();
    wl_surface.setOpaqueRegion(opaque_region);

    const layer_surface: *zwlr.LayerSurfaceV1 = try context.zwlr_layer_shell_v1.getLayerSurface(wl_surface, output.wl_output, .background, "beansprout");
    layer_surface.setExclusiveZone(-1);
    layer_surface.setAnchor(.{ .top = true, .right = true, .bottom = true, .left = true });

    output.wl_surface = wl_surface;
    output.layer_surface = layer_surface;
    context.buffer_pool.surface_count += 1;

    layer_surface.setListener(*Output, wallpaperLayerSurfaceListener, output);
    wl_surface.commit();
}

fn deinitWallpaperLayerSurface(output: *Output) void {
    if (output.layer_surface) |layer_surface| {
        layer_surface.destroy();
    }
    if (output.wl_surface) |wl_surface| {
        wl_surface.destroy();
    }

    output.layer_surface = null;
    output.wl_surface = null;
    output.configured = false;
    output.context.buffer_pool.surface_count -= 1;
}

fn wallpaperLayerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, output: *Output) void {
    switch (event) {
        .configure => |ev| {
            layer_surface.ackConfigure(ev.serial);

            if (ev.width < 0 or ev.height < 0) {
                // I'm not actually sure if this is possible, but just to be safe
                log.warn("Received zwlr_layer_surface_v1.configure event with a negative width or height ({d}x{d})", .{ ev.width, ev.height });
                return;
            }
            const width: u31 = @intCast(ev.width);
            const height: u31 = @intCast(ev.height);

            if (output.configured and output.render_width == width and output.render_height == height) {
                if (output.wl_surface) |wl_surface| {
                    wl_surface.commit();
                } else {
                    log.warn("Output is marked as configured but is missing a layer_surface for the wallpaper", .{});
                }
                return;
            }

            log.debug("configuring wallpaper surface with width {} and height {}", .{ width, height });
            output.render_width = width;
            output.render_height = height;
            output.configured = true;

            output.renderWallpaper() catch |err| {
                fatal("Wallpaper render failed: E{}", .{err});
            };
        },
        .closed => {
            output.deinitWallpaperLayerSurface();
        },
    }
}

/// Calculates image_dimension / (output_dimension * scale)
fn calculate_scale(image_dimension: c_int, output_dimension: u31, scale: u31) f64 {
    const numerator: f64 = @floatFromInt(image_dimension);
    const denominator: f64 = @floatFromInt(output_dimension * scale);

    return numerator / denominator;
}

/// Calculates (image_dimension / dimension_scale - output_dimension) / 2 / dimension_scale;
fn calculate_transform(image_dimension: c_int, output_dimension: u31, dimension_scale: f64) f64 {
    const numerator1: f64 = @floatFromInt(image_dimension);
    const denominator1: f64 = dimension_scale;
    const subtruend: f64 = @floatFromInt(output_dimension);
    const numerator2: f64 = numerator1 / denominator1 - subtruend;

    return numerator2 / 2 / dimension_scale;
}

/// Render the wallpaper image onto the layer surface
fn renderWallpaper(output: *Output) !void {
    const context = output.context;
    const width = output.render_width;
    const height = output.render_height;
    const scale = output.scale;

    // Don't have anything to render
    if (width == 0 or height == 0 or scale == 0) {
        return;
    }
    // Scale our loaded image and then copy it into the Buffer's pixman.Image
    const wallpaper_image = context.wallpaper_image orelse return;
    const image = wallpaper_image.image;
    const image_data = image.getData();
    const image_width = image.getWidth();
    const image_height = image.getHeight();
    const image_stride = image.getStride();
    const image_format = image.getFormat();

    const buffer: *Buffer = try context.buffer_pool.nextBuffer(context.wl_shm, width * scale, height * scale);

    const pix = pixman.Image.createBitsNoClear(image_format, image_width, image_height, image_data, image_stride);
    if (pix == null) {
        log.err("failed to copy the background image for rendering", .{});
        return error.ImageCopyError;
    }
    defer _ = pix.?.unref();

    // Get scale for our image compared to the monitor's scale
    // XXX: This sucks in Zig but also I'm sure there's a better way to write it
    var sx: f64 = @as(f64, @floatFromInt(image_width)) / @as(f64, @floatFromInt(width * scale));
    var sy: f64 = calculate_scale(image_height, height, scale);

    const s = if (sx > sy) sy else sx;
    sx = s;
    sy = s;

    const tx: f64 = calculate_transform(image_width, width, sx);
    const ty: f64 = calculate_transform(image_height, height, sy);

    var t: pixman.FTransform = undefined;
    var t2: pixman.Transform = undefined;

    pixman.FTransform.initTranslate(&t, tx, ty);
    pixman.FTransform.initScale(&t, sx, sy);
    _ = pixman.Transform.fromFTransform(&t2, &t);
    _ = pix.?.setTransform(&t2);
    _ = pix.?.setFilter(.best, &[_]pixman.Fixed{}, 0);

    pixman.Image.composite32(.src, pix.?, null, buffer.pixman_image, 0, 0, 0, 0, 0, 0, width * scale, height * scale);

    log.info("render: {}x{} (scaled from {}x{})", .{ width * scale, height * scale, image_width, image_height });

    // Attach the buffer to the surface
    const wl_surface = output.wl_surface.?;
    wl_surface.setBufferScale(scale);
    wl_surface.attach(buffer.wl_buffer, 0, 0);
    wl_surface.damageBuffer(0, 0, width * scale, height * scale);
    wl_surface.commit();
}

pub fn manage(output: *Output) void {
    defer output.pending_manage = .{};

    if (output.pending_manage.width) |width| {
        output.width = width;
    }
    if (output.pending_manage.height) |height| {
        output.height = height;
    }
    if (output.pending_manage.x) |x| {
        output.x = x;
    }
    if (output.pending_manage.y) |y| {
        output.y = y;
    }

    if (output.pending_manage.tags) |tags| {
        output.tags = tags;
    }
    if (output.pending_manage.primary_ratio) |primary_ratio| {
        // Ratios outside of this range could cause crashes (when doing the layout calculation)
        output.primary_ratio = std.math.clamp(primary_ratio, 0.10, 0.90);
    }
    if (output.pending_manage.primary_count) |primary_count| {
        // Don't allow less than 1 primary
        output.primary_count = @max(1, primary_count);
    }

    // Calculate layout before managing windows
    output.calculatePrimaryStackLayout();
    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        window.manage();
    }
}

pub fn render(output: *Output) void {
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

// TODO - CONFIG: Allow primary on the left
// TODO - CONFIG: Allow setting a ratio for single-window width (useful for ultrawides)
/// Calculate primary/stack layout positions for all windows.
/// - Single window: maximized
/// - Multiple windows: stack (45% left, vertically tiled), primary (55% right)
fn calculatePrimaryStackLayout(output: *Output) void {
    // Get a list of active windows
    var active_list: DoublyLinkedList = .{};
    var active_count: u31 = 0;
    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        if (output.tags & window.tags != 0x0000) {
            // Floating windows should be shown but not included in this layout generation
            const will_float = window.pending_manage.floating orelse window.floating;
            if (!will_float) {
                active_count += 1;
                active_list.append(&window.active_list_node);
            }
            window.pending_render.show = true;
        } else {
            window.pending_render.show = false;
        }
    }

    if (active_count == 0) return;

    // Output dimensions come as i32 from the protocol, convert to u31 for window dimensions
    // since they can't be negative.
    const output_width: u31 = @intCast(output.width);
    const output_height: u31 = @intCast(output.height);
    const output_x = output.x;
    const output_y = output.y;
    const border_width = output.context.config.border_width;

    // Single window: maximize and return early
    if (active_count == 1) {
        const window: *Window = @fieldParentPtr("active_list_node", active_list.popFirst().?);
        window.pending_render.x = output_x + border_width;
        window.pending_render.y = output_y + border_width;
        window.pending_manage.width = output_width - 2 * border_width;
        window.pending_manage.height = output_height - 2 * border_width;
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

    // Iterate through the active windows and apply positions
    var i: u31 = 0;
    while (active_list.popFirst()) |node| : (i += 1) {
        const window: *Window = @fieldParentPtr("active_list_node", node);
        window.pending_manage.maximized = false;

        if (i < primary_count) {
            // Primary window(s) - right side
            window.pending_render.x = output_x + @as(i32, stack_width);
            window.pending_render.y = output_y + @as(i32, i) * @as(i32, primary_height);
            window.pending_manage.width = primary_width;
            // Last primary window gets remaining height to avoid gaps from integer division
            if (i == primary_count - 1) {
                window.pending_manage.height = output_height - i * primary_height;
            } else {
                window.pending_manage.height = primary_height;
            }
        } else {
            // Stack window(s) - left side
            const stack_index = i - primary_count;
            window.pending_render.x = output_x;
            window.pending_render.y = output_y + @as(i32, stack_index) * @as(i32, stack_height);
            window.pending_manage.width = stack_width;
            // Last stack window gets remaining height to avoid gaps from integer division
            if (stack_index == stack_count - 1) {
                window.pending_manage.height = output_height - stack_index * stack_height;
            } else {
                window.pending_manage.height = stack_height;
            }
        }

        // Make space for borders
        window.pending_manage.height.? -= 2 * border_width;
        window.pending_manage.width.? -= 2 * border_width;
        window.pending_render.x.? += border_width;
        window.pending_render.y.? += border_width;
    }

    // Make sure we went through the whole list
    assert(active_list.first == null);
}

const std = @import("std");
const assert = std.debug.assert;
const fatal = std.process.fatal;
const mem = std.mem;
const DoublyLinkedList = std.DoublyLinkedList;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const zwlr = wayland.client.zwlr;
const pixman = @import("pixman");

const utils = @import("utils.zig");
const Buffer = @import("Buffer.zig");
const Context = @import("Context.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.Output);
