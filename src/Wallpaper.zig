// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Wallpaper = @This();

context: *Context,
output: *Output,

surfaces: struct {
    wl_surface: *wl.Surface,
    river_shell_surface: *river.ShellSurfaceV1,
    node: *river.NodeV1,
},

pending_render: PendingRender = .{},

pub const PendingRender = struct {
    should_draw: bool = false,
};

/// Decoded image data shared across all outputs.
/// Stored on Context; each output's Wallpaper references it for rendering.
pub const Image = struct {
    // This is used as the backing store for the pixman image
    // It's the raw image decoded into pixels.
    stbi_pixels: [*]u8,
    // Only used on big-endian; holds manually converted ARGB pixel data.
    // On BE: std.ArrayList(u32), on LE: void
    argb_pixels: if (native_endian == .big) std.ArrayList(u32) else void = if (native_endian == .big) .empty else {},

    // This is the actual scaled, transformed, and rendered image
    pix_image: *pixman.Image,

    pub fn create(image_path: [:0]const u8) !*Image {
        var image = try utils.gpa.create(Image);
        errdefer utils.gpa.destroy(image);

        var width: c_int = 0;
        var height: c_int = 0;
        var channels_in_file: c_int = 0;
        const stbi_pixels = stbi_load(image_path, &width, &height, &channels_in_file, 4) orelse {
            if (stbi_failure_reason()) |reason| {
                log.err("stbi_load failed: {s}", .{reason});
            }
            return error.FailedToLoadImage;
        };
        image.stbi_pixels = stbi_pixels;
        errdefer stbi_image_free(stbi_pixels);

        log.debug("Image loaded ({}x{})", .{ width, height });

        const stride: c_int = width * 4;

        // stbi_load with desired_channels=4 returns pixels as {r, g, b, a} bytes, which actually
        // matches pixman's a8b8g8r8 (u32 with R at bits 0-7, A at bits 24-31) on little endian
        // machines. That means we can use the pixel data directly. On big-endian we keep the
        // manual conversion.
        switch (native_endian) {
            .little => {
                image.pix_image = pixman.Image.createBits(
                    .a8b8g8r8,
                    width,
                    height,
                    @ptrCast(@alignCast(stbi_pixels)),
                    stride,
                ) orelse return error.FailedToCreatePixmanImage;
            },
            .big => {
                const pixel_count: usize = @intCast(width * height);
                image.argb_pixels = try std.ArrayList(u32).initCapacity(utils.gpa, pixel_count);
                errdefer image.argb_pixels.deinit(utils.gpa);
                for (0..pixel_count) |i| {
                    const r: u32 = stbi_pixels[i * 4 + 0];
                    const g: u32 = stbi_pixels[i * 4 + 1];
                    const b: u32 = stbi_pixels[i * 4 + 2];
                    const a: u32 = stbi_pixels[i * 4 + 3];
                    image.argb_pixels.appendAssumeCapacity((a << 24) | (r << 16) | (g << 8) | b);
                }
                image.pix_image = pixman.Image.createBits(
                    .a8r8g8b8,
                    width,
                    height,
                    @ptrCast(@alignCast(image.argb_pixels.items.ptr)),
                    stride,
                ) orelse return error.FailedToCreatePixmanImage;
            },
        }

        return image;
    }

    pub fn destroy(image: *Image) void {
        _ = image.pix_image.unref();
        if (native_endian == .big) image.argb_pixels.deinit(utils.gpa);
        stbi_image_free(image.stbi_pixels);
        utils.gpa.destroy(image);
    }
};

pub fn init(context: *Context, output: *Output) !Wallpaper {
    const wl_surface = try context.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    const river_shell_surface = try context
        .wm
        .river_window_manager_v1
        .getShellSurface(wl_surface);
    errdefer river_shell_surface.destroy();

    const node = try river_shell_surface.getNode();
    errdefer node.destroy();

    // We don't want our surface to have any input region (default is infinite)
    const empty_region = try context.wl_compositor.createRegion();
    defer empty_region.destroy();
    wl_surface.setInputRegion(empty_region);

    context.buffer_pool.surface_count += 1;

    // Full surface should be opaque
    const opaque_region = try context.wl_compositor.createRegion();
    opaque_region.add(0, 0, output.geometry.width, output.geometry.height);
    defer opaque_region.destroy();
    wl_surface.setOpaqueRegion(opaque_region);

    return .{
        .context = context,
        .output = output,
        .surfaces = .{
            .wl_surface = wl_surface,
            .river_shell_surface = river_shell_surface,
            .node = node,
        },
        .pending_render = .{ .should_draw = true },
    };
}

pub fn deinit(wallpaper: *Wallpaper) void {
    wallpaper.surfaces.node.destroy();
    wallpaper.surfaces.river_shell_surface.destroy();
    wallpaper.surfaces.wl_surface.destroy();

    wallpaper.context.buffer_pool.surface_count -= 1;

    wallpaper.output.wallpaper = null;
}

pub fn render(wallpaper: *Wallpaper) void {
    defer wallpaper.pending_render = .{};

    // We draw whenever the output's dimensions or scale change
    if (wallpaper.pending_render.should_draw) {
        const output = wallpaper.output;
        const geometry = output.geometry;
        const width = geometry.width;
        const height = geometry.height;
        const scale = output.scale;

        const opaque_region = wallpaper.context.wl_compositor.createRegion() catch |err| {
            log.err("Failed to create opaque region: {}", .{err});
            return;
        };
        defer opaque_region.destroy();
        opaque_region.add(0, 0, width, height);

        wallpaper.surfaces.node.placeBottom();
        wallpaper.surfaces.node.setPosition(
            wallpaper.output.geometry.x,
            wallpaper.output.geometry.y,
        );

        wallpaper.surfaces.wl_surface.setOpaqueRegion(opaque_region);
        wallpaper.draw(width, height, scale) catch |err| {
            log.err("Wallpaper draw failed: {}", .{err});
        };
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

/// Draw the shared Wallpaper.Image onto the specific layer surface for this Wallpaper
fn draw(wallpaper: *Wallpaper, output_width: u31, output_height: u31, output_scale: u31) !void {
    const context = wallpaper.context;

    if (output_width == 0 or output_height == 0 or output_scale == 0) {
        return;
    }

    // Scale our loaded image and then copy it into the Buffer's pixman.Image
    const wp_image = context.wallpaper_image orelse return error.MissingWallpaperImage;
    const image = wp_image.pix_image;
    const image_data = image.getData();
    const image_width = image.getWidth();
    const image_height = image.getHeight();
    const image_stride = image.getStride();
    const image_format = image.getFormat();

    const buffer = try context.buffer_pool.nextBuffer(
        context.wl_shm,
        output_width * output_scale,
        output_height * output_scale,
    );

    const pix = pixman.Image.createBitsNoClear(
        image_format,
        image_width,
        image_height,
        image_data,
        image_stride,
    ) orelse {
        log.err("Failed to copy the wallpaper image for rendering", .{});
        return error.FailedToCreatePixmanImage;
    };
    defer _ = pix.unref();

    // Calculate image scale in both dimensions. We choose the larger of the two scales to use
    // (they're not equal when image aspect ratio != the output's aspect ratio).
    const s = blk: {
        const sx: f64 = calculateScale(image_width, output_width, output_scale);
        const sy: f64 = calculateScale(image_height, output_height, output_scale);

        break :blk if (sx > sy) sy else sx;
    };

    // Calculate translation offsets to center the image on the output.
    // If the scaled image is larger than the output, the offset crops equally from both sides.
    const tx: f64 = calculateTransform(image_width, output_width * output_scale, s);
    const ty: f64 = calculateTransform(image_height, output_height * output_scale, s);

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

    pixman.FTransform.initScale(&t_scale, s, s);
    pixman.FTransform.initTranslate(&t_trans, tx, ty);
    pixman.FTransform.multiply(&t, &t_scale, &t_trans);
    _ = pixman.Transform.fromFTransform(&t2, &t);
    _ = pix.setTransform(&t2);
    _ = pix.setFilter(.best, &[_]pixman.Fixed{}, 0);

    // Combine the transformed source image into the buffer.
    pixman.Image.composite32(.src, pix, null, buffer.pixman_image, 0, 0, 0, 0, 0, 0, output_width * output_scale, output_height * output_scale);

    log.info("draw: {}x{} (scaled from {}x{})", .{ output_width * output_scale, output_height * output_scale, image_width, image_height });

    // Attach the buffer to the surface
    const wl_surface = wallpaper.surfaces.wl_surface;
    wl_surface.setBufferScale(output_scale);
    wl_surface.attach(buffer.wl_buffer, 0, 0);
    wl_surface.damageBuffer(0, 0, output_width * output_scale, output_height * output_scale);
    wl_surface.commit();
}

const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const pixman = @import("pixman");

const utils = @import("utils.zig");
const Context = @import("Context.zig");
const Output = @import("Output.zig");

const log = std.log.scoped(.Wallpaper);

extern fn stbi_load(filename: [*:0]const u8, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
extern fn stbi_failure_reason() ?[*:0]const u8;
