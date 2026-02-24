// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const WallpaperImage = @This();

// This is used as the backing store for the pixman image
// It's the actual image (png, jpeg, etc.) decoded into pixels.
zigimg_image: zigimg.Image,
// Only used on big-endian; holds manually converted ARGB pixel data.
// On BE: std.ArrayList(u32), on LE: void
argb_pixels: if (native_endian == .big) std.ArrayList(u32) else void = if (native_endian == .big) .empty else {},

// This is the actual scaled, transformed, and rendered image
pix_image: *pixman.Image,

pub fn create(image_path: []const u8) !*WallpaperImage {
    var wallpaper_image = try utils.gpa.create(WallpaperImage);
    errdefer utils.gpa.destroy(wallpaper_image);

    var read_buf: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    wallpaper_image.zigimg_image = try zigimg.Image.fromFilePath(utils.gpa, image_path, &read_buf);
    errdefer wallpaper_image.zigimg_image.deinit(utils.gpa);

    // We don't want to deal with all the possible formats,
    // so let's just convert to one we can use with pixman.
    if (wallpaper_image.zigimg_image.pixelFormat() != .rgba32) {
        try wallpaper_image.zigimg_image.convert(utils.gpa, .rgba32);
    }

    log.debug("image loaded ({}x{})", .{ wallpaper_image.zigimg_image.width, wallpaper_image.zigimg_image.height });

    const pixels = wallpaper_image.zigimg_image.pixels.rgba32;
    const width: c_int = @intCast(wallpaper_image.zigimg_image.width);
    const height: c_int = @intCast(wallpaper_image.zigimg_image.height);
    const stride: c_int = @intCast(wallpaper_image.zigimg_image.width * wallpaper_image.zigimg_image.pixelFormat().pixelStride());

    // zigimg's Rgba32 is an extern struct {r, g, b, a}, which actually matches pixman's a8b8g8r8
    // (u32 with R at bits 0-7, A at bits 24-31) on little endian machines. That means we can actually
    // use zigimg's pixel data directly. On big-endian we keep the manual conversion I used to use.
    switch (native_endian) {
        .little => {
            wallpaper_image.pix_image = pixman.Image.createBits(
                .a8b8g8r8,
                width,
                height,
                @ptrCast(@alignCast(pixels.ptr)),
                stride,
            ) orelse return error.FailedToCreatePixmanImage;
        },
        .big => {
            wallpaper_image.argb_pixels = try std.ArrayList(u32).initCapacity(utils.gpa, pixels.len);
            errdefer wallpaper_image.argb_pixels.deinit(utils.gpa);
            for (pixels) |px| {
                const a: u32 = px.a;
                const r: u32 = px.r;
                const g: u32 = px.g;
                const b: u32 = px.b;
                wallpaper_image.argb_pixels.appendAssumeCapacity((a << 24) | (r << 16) | (g << 8) | b);
            }
            wallpaper_image.pix_image = pixman.Image.createBits(
                .a8r8g8b8,
                width,
                height,
                @ptrCast(@alignCast(wallpaper_image.argb_pixels.items.ptr)),
                stride,
            ) orelse return error.FailedToCreatePixmanImage;
        },
    }

    return wallpaper_image;
}

pub fn destroy(wallpaper_image: *WallpaperImage) void {
    _ = wallpaper_image.pix_image.unref();
    if (native_endian == .big) wallpaper_image.argb_pixels.deinit(utils.gpa);
    wallpaper_image.zigimg_image.deinit(utils.gpa);

    utils.gpa.destroy(wallpaper_image);
}

const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const pixman = @import("pixman");
const zigimg = @import("zigimg");

const utils = @import("utils.zig");

const log = std.log.scoped(.WallpaperImage);
