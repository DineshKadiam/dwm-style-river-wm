// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const WallpaperImage = @This();

image: *pixman.Image,
pixels: std.ArrayList(u32),

// TODO: Make image_path nullable, if null, do a single color with a single_pixel_buffer instead(?)
pub fn create(image_path: []const u8) !*WallpaperImage {
    var wallpaper_image = try utils.gpa.create(WallpaperImage);
    errdefer utils.gpa.destroy(wallpaper_image);

    var read_buf: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var image = try zigimg.Image.fromFilePath(utils.gpa, image_path, &read_buf);
    defer image.deinit(utils.gpa);

    // We don't want to deal with all the possible formats,
    // so let's just convert to one we can use with pixman.
    if (image.pixelFormat() != .rgba32) {
        try image.convert(utils.gpa, .rgba32);
    }

    log.debug("image loaded ({}x{})", .{ image.width, image.height });

    const pixels = image.pixels.rgba32;
    // We have to manually convert to argb --
    // It's only guaranteed that Wayland compositors will have xrgb and argb support but zigimg doesn't have either of those.
    wallpaper_image.pixels = try std.ArrayList(u32).initCapacity(utils.gpa, pixels.len);
    errdefer wallpaper_image.pixels.deinit(utils.gpa);
    for (0..pixels.len) |i| {
        const a: u32 = @intCast(pixels[i].a);
        const r: u32 = @intCast(pixels[i].r);
        const g: u32 = @intCast(pixels[i].g);
        const b: u32 = @intCast(pixels[i].b);
        const new_val: u32 = (a << 24) + (r << 16) + (g << 8) + b;
        wallpaper_image.pixels.appendAssumeCapacity(new_val);
    }

    wallpaper_image.image = pixman.Image.createBits(.a8r8g8b8, @intCast(image.width), @intCast(image.height), @ptrCast(@alignCast(wallpaper_image.pixels.items.ptr)), @intCast(image.width * image.pixelFormat().pixelStride())) orelse return error.FailedToCreatePixmanImage;

    return wallpaper_image;
}

pub fn destroy(wallpaper_image: *WallpaperImage) void {
    _ = wallpaper_image.image.unref();
    wallpaper_image.pixels.deinit(utils.gpa);

    utils.gpa.destroy(wallpaper_image);
}

const std = @import("std");

const pixman = @import("pixman");
const zigimg = @import("zigimg");

const utils = @import("utils.zig");

const log = std.log.scoped(.WallpaperImage);
