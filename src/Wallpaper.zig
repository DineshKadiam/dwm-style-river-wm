// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Wallpaper = @This();

context: *Context,
output: *Output,

wl_surface: *wl.Surface,
layer_surface: *zwlr.LayerSurfaceV1,

render_scale: u31 = 0,
render_width: u31 = 0,
render_height: u31 = 0,
configured: bool = false,

/// Decoded image data shared across all outputs.
/// Stored on Context; each output's Wallpaper references it for rendering.
pub const Image = struct {
    // This is used as the backing store for the pixman image
    // It's the actual image (png, jpeg, etc.) decoded into pixels.
    zigimg_image: zigimg.Image,
    // Only used on big-endian; holds manually converted ARGB pixel data.
    // On BE: std.ArrayList(u32), on LE: void
    argb_pixels: if (native_endian == .big) std.ArrayList(u32) else void = if (native_endian == .big) .empty else {},

    // This is the actual scaled, transformed, and rendered image
    pix_image: *pixman.Image,

    pub fn create(image_path: []const u8) !*Image {
        var image = try utils.gpa.create(Image);
        errdefer utils.gpa.destroy(image);

        var read_buf: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
        image.zigimg_image = try zigimg.Image.fromFilePath(utils.gpa, image_path, &read_buf);
        errdefer image.zigimg_image.deinit(utils.gpa);

        // We don't want to deal with all the possible formats,
        // so let's just convert to one we can use with pixman.
        if (image.zigimg_image.pixelFormat() != .rgba32) {
            try image.zigimg_image.convert(utils.gpa, .rgba32);
        }

        log.debug("image loaded ({}x{})", .{ image.zigimg_image.width, image.zigimg_image.height });

        const pixels = image.zigimg_image.pixels.rgba32;
        const width: c_int = @intCast(image.zigimg_image.width);
        const height: c_int = @intCast(image.zigimg_image.height);
        const stride: c_int = @intCast(image.zigimg_image.width * image.zigimg_image.pixelFormat().pixelStride());

        // zigimg's Rgba32 is an extern struct {r, g, b, a}, which actually matches pixman's a8b8g8r8
        // (u32 with R at bits 0-7, A at bits 24-31) on little endian machines. That means we can actually
        // use zigimg's pixel data directly. On big-endian we keep the manual conversion I used to use.
        switch (native_endian) {
            .little => {
                image.pix_image = pixman.Image.createBits(
                    .a8b8g8r8,
                    width,
                    height,
                    @ptrCast(@alignCast(pixels.ptr)),
                    stride,
                ) orelse return error.FailedToCreatePixmanImage;
            },
            .big => {
                image.argb_pixels = try std.ArrayList(u32).initCapacity(utils.gpa, pixels.len);
                errdefer image.argb_pixels.deinit(utils.gpa);
                for (pixels) |px| {
                    const a: u32 = px.a;
                    const r: u32 = px.r;
                    const g: u32 = px.g;
                    const b: u32 = px.b;
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
        image.zigimg_image.deinit(utils.gpa);

        utils.gpa.destroy(image);
    }
};

pub fn init(context: *Context, output: *Output) !Wallpaper {
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

    context.buffer_pool.surface_count += 1;

    layer_surface.setListener(*Output, layerSurfaceListener, output);
    wl_surface.commit();

    return .{
        .context = context,
        .output = output,
        .wl_surface = wl_surface,
        .layer_surface = layer_surface,
    };
}

pub fn deinit(wallpaper: *Wallpaper) void {
    wallpaper.layer_surface.destroy();
    wallpaper.wl_surface.destroy();
    wallpaper.context.buffer_pool.surface_count -= 1;
}

fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, output: *Output) void {
    switch (event) {
        .configure => |ev| {
            layer_surface.ackConfigure(ev.serial);

            const wallpaper = &(output.wallpaper orelse return);

            const width: u31 = @intCast(ev.width);
            const height: u31 = @intCast(ev.height);

            if (wallpaper.configured and
                wallpaper.render_width == width and
                wallpaper.render_height == height and
                output.scale == wallpaper.render_scale)
            {
                wallpaper.wl_surface.commit();
                return;
            }

            log.debug("configuring wallpaper surface with width {} and height {}", .{ width, height });
            wallpaper.render_width = width;
            wallpaper.render_height = height;
            wallpaper.configured = true;

            wallpaper.render() catch |err| {
                log.err("Wallpaper render failed: {}", .{err});
            };
        },
        .closed => {
            if (output.wallpaper) |*wp| wp.deinit();
            output.wallpaper = null;
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
pub fn render(wallpaper: *Wallpaper) !void {
    const context = wallpaper.context;
    const output = wallpaper.output;
    const width = wallpaper.render_width;
    const height = wallpaper.render_height;
    const scale = output.scale;

    // Don't have anything to render
    if (width == 0 or height == 0 or scale == 0) {
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
    const wl_surface = wallpaper.wl_surface;
    wl_surface.setBufferScale(scale);
    wl_surface.attach(buffer.wl_buffer, 0, 0);
    wl_surface.damageBuffer(0, 0, width * scale, height * scale);
    wl_surface.commit();

    wallpaper.render_scale = scale;
}

const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const pixman = @import("pixman");
const zigimg = @import("zigimg");

const utils = @import("utils.zig");
const Context = @import("Context.zig");
const Output = @import("Output.zig");

const log = std.log.scoped(.Wallpaper);
