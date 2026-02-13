// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Bar = @This();

context: *Context,

// TODO: Get this in Config then save in Context
font: *fcft.Font,

/// The output that this Bar is on
output: *Output,

// Bar geometry
width: u31 = 0,
height: u31 = 0,

wl_surface: ?*wl.Surface = null,
layer_surface: ?*zwlr.LayerSurfaceV1 = null,

configured: bool = false,

pub fn init(context: *Context, output: *Output) !Bar {
    return .{
        .context = context,
        .font = try getFcftFonts("monospace:size=14"),
        .output = output,
    };
}

// TODO: Add config options for whether it's top or bottom
pub fn initSurface(bar: *Bar) !void {
    if (bar.layer_surface) |_| {
        // This bar already has a layer surface, we can exit early
        return;
    }

    const context = bar.context;

    // TODO: Add padding to config
    const padding = 5;
    const bar_height: u31 = @intCast(bar.font.height + 2 * padding);

    const wl_surface: *wl.Surface = try context.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    // TODO: Allow clicking on tags to switch between them?
    // We don't want our surface to have any input region (default is infinite)
    const empty_region: *wl.Region = try context.wl_compositor.createRegion();
    defer empty_region.destroy();
    wl_surface.setInputRegion(empty_region);

    const layer_surface: *zwlr.LayerSurfaceV1 = try context
        .zwlr_layer_shell_v1
        .getLayerSurface(wl_surface, bar.output.wl_output, .top, "beansprout-bar");
    layer_surface.setSize(0, bar_height);
    layer_surface.setAnchor(.{ .top = true, .right = true, .left = true });

    bar.wl_surface = wl_surface;
    bar.layer_surface = layer_surface;
    context.buffer_pool.surface_count += 1;

    layer_surface.setListener(*Bar, layerSurfaceListener, bar);
    wl_surface.commit();
}

pub fn deinit(bar: *Bar) void {
    bar.configured = false;
    if (bar.wl_surface) |wl_surface| {
        wl_surface.destroy();
    }
    if (bar.layer_surface) |layer_surface| {
        layer_surface.destroy();
        bar.context.buffer_pool.surface_count -= 1;
    }
}

pub fn layerSurfaceListener(
    layer_surface: *zwlr.LayerSurfaceV1,
    event: zwlr.LayerSurfaceV1.Event,
    bar: *Bar,
) void {
    switch (event) {
        .configure => |ev| {
            layer_surface.ackConfigure(ev.serial);
            const width: u31 = @intCast(ev.width);
            const height: u31 = @intCast(ev.height);

            if (bar.configured and bar.width == width and bar.height == height) {
                if (bar.wl_surface) |wl_surface| {
                    wl_surface.commit();
                } else {
                    log.warn("Bar is marked as configured but is missing a layer_surface for the wallpaper", .{});
                }
                return;
            }

            log.debug("configuring bar surface with width {} and height {}", .{ width, height });
            bar.width = width;
            bar.height = height;
            // Excluse zone == the bar's height
            layer_surface.setExclusiveZone(bar.height);

            // Full surface should be opaque
            const opaque_region: *wl.Region = bar.context.wl_compositor.createRegion() catch |e| {
                log.err("Failed to create opaque region for bar: {}", .{e});
                return;
            };
            // TODO: Need to change the x/y if we support anchoring to the bottom
            opaque_region.add(0, 0, bar.width, bar.height);
            defer opaque_region.destroy();
            bar.wl_surface.?.setOpaqueRegion(opaque_region);

            bar.configured = true;

            log.debug("bwbuhse before render", .{});
            bar.render() catch |err| {
                log.err("Bar render failed: {}", .{err});
            };
        },
        .closed => {
            bar.deinit();
        },
    }
}

fn render(bar: *Bar) !void {
    const buffer = try bar.context.buffer_pool.nextBuffer(bar.context.wl_shm, bar.width, bar.height);

    // Fill with a solid color (e.g., dark background)
    const bg_color = pixman.Color{ .red = 0x1e1e, .green = 0x1e1e, .blue = 0x2e2e, .alpha = 0xffff };
    const fill = pixman.Image.createSolidFill(&bg_color) orelse return;
    defer _ = fill.unref();
    pixman.Image.composite32(.src, fill, null, buffer.pixman_image, 0, 0, 0, 0, 0, 0, bar.width, bar.height);

    const wl_surface = bar.wl_surface orelse return;
    wl_surface.attach(buffer.wl_buffer, 0, 0);
    wl_surface.damageBuffer(0, 0, bar.width, bar.height);
    wl_surface.commit();
    log.debug("bwbuhse end of render", .{});
}

// Borrowed and modified from https://git.sr.ht/~novakane/zig-fcft-example
fn renderChars(output: *Output, text: []const u32, buffer: *Buffer, color: *pixman.Image) !void {
    const glyphs = try utils.gpa.alloc(*const fcft.Glyph, text.len);
    const kerns = try utils.gpa.alloc(c_long, text.len);
    defer utils.gpa.free(glyphs);
    defer utils.gpa.free(kerns);

    var text_width: i32 = 0;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        glyphs[i] = try output.ctx.fonts.rasterizeCharUtf32(text[i], .default);

        kerns[i] = 0;
        if (i > 0) {
            var x_kern: c_long = 0;
            if (output.ctx.fonts.kerning(text[i - 1], text[i], &x_kern, null)) {
                kerns[i] = x_kern;
            }
        }

        text_width += @intCast(kerns[i] + glyphs[i].advance.x);
    }

    var x: i32 = @divFloor(buffer.width - text_width, 2);
    const y: i32 = @divFloor(buffer.height - output.ctx.fonts.height, 2);
    output.render_glyphs(buffer, &x, y, color, text.len, glyphs.ptr, kerns);
}

// Borrowed https://git.sr.ht/~novakane/zig-fcft-example
fn renderGlyphs(
    output: *Output,
    buffer: *Buffer,
    x: *i32,
    y: i32,
    color: *pixman.Image,
    len: usize,
    glyphs: [*]*const fcft.Glyph,
    kerns: ?[]c_long,
) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (kerns) |kern| x.* += @intCast(kern[i]);

        switch (pixman.Image.getFormat(glyphs[i].pix)) {
            // Glyph is a pre-rendered image. (e.g. a color emoji)
            .a8r8g8b8 => {
                pixman.Image.composite32(
                    .over,
                    glyphs[i].pix,
                    null,
                    buffer.pixman_image,
                    0,
                    0,
                    0,
                    0,
                    x.* + @as(i32, @intCast(glyphs[i].x)),
                    y + output.ctx.fonts.ascent - @as(i32, @intCast(glyphs[i].y)),
                    glyphs[i].width,
                    glyphs[i].height,
                );
            },
            // Glyph is an alpha mask.
            else => {
                pixman.Image.composite32(
                    .over,
                    color,
                    glyphs[i].pix,
                    buffer.pixman_image,
                    0,
                    0,
                    0,
                    0,
                    x.* + @as(i32, @intCast(glyphs[i].x)),
                    y + output.ctx.fonts.ascent - @as(i32, @intCast(glyphs[i].y)),
                    glyphs[i].width,
                    glyphs[i].height,
                );
            },
        }

        x.* += glyphs[i].advance.x;
    }
}

// Borrowed from https://git.sr.ht/~novakane/zig-fcft-example
fn getFcftFonts(fonts: []const u8) !*fcft.Font {
    // Create an arena to free just for this function;
    // It makes cleaning up the ArrayList easier.
    var arena = std.heap.ArenaAllocator.init(utils.gpa);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var list = try std.ArrayList([*:0]const u8).initCapacity(arena_alloc, 2);

    var it = mem.tokenizeScalar(u8, fonts, ',');
    while (it.next()) |font| {
        try list.append(arena_alloc, try arena_alloc.dupeZ(u8, font));
    }

    const fcft_fonts = try fcft.Font.fromName(list.items[0..], null);
    errdefer fcft_fonts.destroy();
    fcft_fonts.setEmojiPresentation(.default);

    return fcft_fonts;
}

const std = @import("std");
const mem = std.mem;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const fcft = @import("fcft");
const pixman = @import("pixman");

const utils = @import("utils.zig");
const Buffer = @import("Buffer.zig");
const Context = @import("Context.zig");
const Output = @import("Output.zig");

const log = std.log.scoped(.Bar);
