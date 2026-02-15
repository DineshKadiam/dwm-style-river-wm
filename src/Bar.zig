// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Bar = @This();

/// Standard base DPI at a scale of 1
const base_dpi = 96;

context: *Context,

/// The timezone of the computer.
timezone: zeit.timezone.TimeZone,

fonts: *fcft.Font,
font_scale: u31 = 0,

output: *Output,

// Bar geometry
width: u31 = 0,
height: u31 = 0,

wl_surface: ?*wl.Surface = null,
layer_surface: ?*zwlr.LayerSurfaceV1 = null,

configured: bool = false,

pub fn init(context: *Context, output: *Output) !Bar {
    const timezone = try zeit.local(utils.gpa, &context.env);
    errdefer timezone.deinit();

    const fonts = try getFcftFonts("monospace:size=14", 1);
    errdefer fonts.destroy();

    return .{
        .context = context,
        .fonts = fonts,
        .timezone = timezone,
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
    const vertical_padding = 5;
    const bar_height: u31 = @intCast(bar.fonts.height + 2 * vertical_padding);

    const wl_surface = try context.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    // TODO: Allow clicking on tags to switch between them?
    // We don't want our surface to have any input region (default is infinite)
    const empty_region = try context.wl_compositor.createRegion();
    defer empty_region.destroy();
    wl_surface.setInputRegion(empty_region);

    const layer_surface = try context
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
    bar.timezone.deinit();
    bar.fonts.destroy();
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

            if (bar.configured and
                bar.width == width and
                bar.height == height and
                bar.output.scale == bar.font_scale)
            {
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

            bar.render() catch |err| {
                log.err("Bar render failed: {}", .{err});
            };
        },
        .closed => {
            bar.deinit();
        },
    }
}

// TODO: Configure number of visible tags
/// Renders the bar and its components
pub fn render(bar: *Bar) !void {
    const context = bar.context;

    const scale = bar.output.scale;

    // Recreate fonts at the output's new scale
    if (scale != bar.font_scale) {
        bar.fonts.destroy();
        bar.fonts = try getFcftFonts("monospace:size=14", scale);
        bar.font_scale = scale;
    }

    // Scaled width/height
    const render_width = bar.width * scale;
    const render_height = bar.height * scale;

    // Don't have anything to render
    if (render_width == 0 or render_height == 0 or scale == 0) {
        return;
    }
    const buffer = try context.buffer_pool.nextBuffer(bar.context.wl_shm, render_width, render_height);

    // Fill with a solid color (e.g., dark background)
    // TODO: Configure text/bg colors
    const bg_color: pixman.Color = .{ .red = 0x1e1e, .green = 0x1e1e, .blue = 0x2e2e, .alpha = 0xffff };
    _ = pixman.Image.fillRectangles(
        .src,
        buffer.pixman_image,
        &bg_color,
        1,
        &[1]pixman.Rectangle16{.{
            .x = 0,
            .y = 0,
            .width = @intCast(render_width),
            .height = @intCast(render_height),
        }},
    );

    // Set-up text color
    const text_color: pixman.Color = .{ .red = 0xffff, .green = 0xffff, .blue = 0xffff, .alpha = 0xffff };
    const color = pixman.Image.createSolidFill(&text_color) orelse return error.FailedToCreatePixmanImage;
    defer _ = color.unref();

    // Get the current time in seconds since the epoch,
    // then load the local timezone,
    // then convert `now` to the `local` timezone
    const now = try zeit.instant(.{});
    const now_local = now.in(&bar.timezone);

    // Generate date/time info for this instant
    const dt = now_local.time();

    // Convert time to a string
    var buf: [255:0]u8 = undefined;
    var fbs = io.fixedBufferStream(&buf);
    // TODO: Support 12-hour clock (%I:%M)
    try dt.strftime(fbs.writer(), "%H:%M");

    // Convert ASCII text string to unicode
    // XXX: Not sure if this even needs to be converted to unicode
    var codepoint_it = (try unicode.Utf8View.init(fbs.getWritten())).iterator();
    const codepoint_count = try unicode.utf8CountCodepoints(fbs.getWritten());
    // We use u32 for fcft even if zig uses u21
    var codepoints: []u32 = try utils.gpa.alloc(u32, codepoint_count);
    defer utils.gpa.free(codepoints);
    var i: usize = 0;
    while (codepoint_it.nextCodepoint()) |cp| : (i += 1) {
        codepoints[i] = cp;
    }

    const text_width = try bar.textWidth(codepoints);
    var x: i32 = @divFloor(buffer.width - text_width, 2);
    const y: i32 = @divFloor(buffer.height - bar.fonts.height, 2);

    // Actually render the unicode codepoints
    try bar.renderChars(codepoints, buffer, &x, y, color);

    // Finally, attach the buffer to the surface
    const wl_surface = bar.wl_surface orelse return;
    wl_surface.setBufferScale(scale);
    wl_surface.attach(buffer.wl_buffer, 0, 0);
    wl_surface.damageBuffer(0, 0, render_width, render_height);
    wl_surface.commit();
}

// TODO: This should be moved to utils once fonts are in config
/// Computes the pixel width of a text string.
fn textWidth(bar: *Bar, text: []const u32) !i32 {
    var width: i32 = 0;
    for (text, 0..) |cp, i| {
        const glyph = try bar.fonts.rasterizeCharUtf32(cp, .default);
        width += glyph.advance.x;
        if (i > 0) {
            var x_kern: c_long = 0;
            if (bar.fonts.kerning(text[i - 1], cp, &x_kern, null)) {
                width += @intCast(x_kern);
            }
        }
    }
    return width;
}

// Borrowed and modified from https://git.sr.ht/~novakane/zig-fcft-example
fn renderChars(
    bar: *Bar,
    text: []const u32,
    buffer: *Buffer,
    x: *i32,
    y: i32,
    color: *pixman.Image,
) !void {
    const glyphs = try utils.gpa.alloc(*const fcft.Glyph, text.len);
    const kerns = try utils.gpa.alloc(c_long, text.len);
    defer utils.gpa.free(glyphs);
    defer utils.gpa.free(kerns);

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        glyphs[i] = try bar.fonts.rasterizeCharUtf32(text[i], .default);

        kerns[i] = 0;
        if (i > 0) {
            var x_kern: c_long = 0;
            if (bar.fonts.kerning(text[i - 1], text[i], &x_kern, null)) {
                kerns[i] = x_kern;
            }
        }
    }

    bar.renderGlyphs(buffer, x, y, color, text.len, glyphs.ptr, kerns);
}

// Borrowed https://git.sr.ht/~novakane/zig-fcft-example
fn renderGlyphs(
    bar: *Bar,
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
                    y + bar.fonts.ascent - @as(i32, @intCast(glyphs[i].y)),
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
                    y + bar.fonts.ascent - @as(i32, @intCast(glyphs[i].y)),
                    glyphs[i].width,
                    glyphs[i].height,
                );
            },
        }

        x.* += glyphs[i].advance.x;
    }
}

// Borrowed and modified from https://git.sr.ht/~novakane/zig-fcft-example
fn getFcftFonts(fonts: []const u8, scale: u31) !*fcft.Font {
    // Create an arena to free just for this function;
    // It makes cleaning up the ArrayList easier.
    var arena = std.heap.ArenaAllocator.init(utils.gpa);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var list = try std.ArrayList([*:0]const u8).initCapacity(arena_alloc, 2);

    var it = mem.tokenizeScalar(u8, fonts, ',');
    while (it.next()) |font| {
        if (scale > 1) {
            // If scale >1, we append :dpi so we can scale the font
            const scaled = try arena_alloc.dupeZ(
                u8,
                try std.fmt.allocPrint(arena_alloc, "{s}:dpi={}", .{ font, @as(u32, base_dpi) * scale }),
            );
            try list.append(arena_alloc, scaled);
        } else {
            try list.append(arena_alloc, try arena_alloc.dupeZ(u8, font));
        }
    }

    const fcft_fonts = try fcft.Font.fromName(list.items[0..], null);
    errdefer fcft_fonts.destroy();
    fcft_fonts.setEmojiPresentation(.default);

    return fcft_fonts;
}

const std = @import("std");
const io = std.io;
const mem = std.mem;
const process = std.process;
const unicode = std.unicode;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const fcft = @import("fcft");
const pixman = @import("pixman");
const zeit = @import("zeit");

const utils = @import("utils.zig");
const Buffer = @import("Buffer.zig");
const Context = @import("Context.zig");
const Output = @import("Output.zig");

const log = std.log.scoped(.Bar);
