// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Bar = @This();

/// Standard base DPI at a scale of 1
const base_dpi = 96;

context: *Context,

/// The timezone of the computer.
timezone: zeit.timezone.TimeZone,

options: Options,

fcft_fonts: *fcft.Font,
font_scale: u31 = 1,

output: *Output,

// Bar geometry
geometry: Rect = .{},

surfaces: ?struct {
    wl_surface: *wl.Surface,
    river_shell_surface: *river.ShellSurfaceV1,
    node: *river.NodeV1,
} = null,

pending_manage: PendingManage = .{},
pending_render: PendingRender = .{},

configured: bool = false,

pub const PendingManage = struct {
    output_geometry: bool = false,
};

pub const PendingRender = struct {
    position: ?struct { x: i32, y: i32 } = null,
    draw: bool = false,
};

pub const Position = enum { top, bottom };

pub const Options = struct {
    /// Comma separated list of FontConfig formatted font specifications
    fonts: []const u8 = "monospace:size=14",
    /// Color of text on the bar
    text_color: pixman.Color = utils.parseRgbaPixmanComptime("0xcdd6f4"),
    /// Background color of the bar
    background_color: pixman.Color = utils.parseRgbaPixmanComptime("0x1e1e2e"),

    /// Whether the bar is at the top or bottom of the screen
    position: Position = .top,
    /// Directional margins top, right, bottom, left, in pixels
    margins: struct { top: i32 = 0, right: i32 = 0, bottom: i32 = 0, left: i32 = 0 } = .{},
};

pub fn init(context: *Context, output: *Output, options: Options) !Bar {
    const timezone = try zeit.local(utils.gpa, &context.env);
    errdefer timezone.deinit();

    const scale = output.scale;
    const fcft_fonts = try getFcftFonts(options.fonts, scale);
    errdefer fcft_fonts.destroy();

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

    return .{
        .context = context,
        .options = options,
        .fcft_fonts = fcft_fonts,
        .font_scale = scale,
        .timezone = timezone,
        .output = output,
        .surfaces = .{
            .wl_surface = wl_surface,
            .river_shell_surface = river_shell_surface,
            .node = node,
        },
        .configured = true,
    };
}

pub fn deinit(bar: *Bar) void {
    bar.configured = false;
    bar.timezone.deinit();
    if (bar.surfaces) |surfaces| {
        surfaces.node.destroy();
        surfaces.river_shell_surface.destroy();
        surfaces.wl_surface.destroy();
        bar.context.buffer_pool.surface_count -= 1;
    }
}

pub fn manage(bar: *Bar) !void {
    if (!bar.configured) return;
    defer bar.pending_manage = .{};

    // The only manage actions we need to do are when the output changes geometry
    if (!bar.pending_manage.output_geometry) return;

    const output = bar.output;
    const options = bar.options;

    // Recreate fonts if the output scale changed, so geometry calculations
    // below use the correct font metrics.
    const scale = output.scale;
    if (scale != bar.font_scale) {
        bar.fcft_fonts.destroy();
        bar.fcft_fonts = try getFcftFonts(bar.options.fonts, scale);
        bar.font_scale = scale;
    }

    const vertical_padding = 5;
    const logical_font_height = @divFloor(bar.fcft_fonts.height, @as(i32, bar.font_scale));
    const height: u31 = @intCast(logical_font_height + 2 * vertical_padding);
    const width: u31 = output.geometry.width;

    if (bar.geometry.width != width or bar.geometry.height != height) {
        bar.geometry.width = width;
        bar.geometry.height = height;

        const opaque_region = try bar.context.wl_compositor.createRegion();
        defer opaque_region.destroy();
        opaque_region.add(0, 0, width, height);
        bar.surfaces.?.wl_surface.setOpaqueRegion(opaque_region);
    }

    const x = output.geometry.x + options.margins.left;
    const y = switch (options.position) {
        .top => output.geometry.y + options.margins.top,
        .bottom => output.geometry.y + output.geometry.height - bar.geometry.height - options.margins.bottom,
    };
    bar.pending_render.position = .{ .x = x, .y = y };
    bar.pending_render.draw = true;
}

pub fn render(bar: *Bar) void {
    if (!bar.configured) return;
    defer bar.pending_render = .{};

    const surfaces = bar.surfaces orelse return;

    if (bar.pending_render.position) |position| {
        surfaces.node.setPosition(position.x, position.y);
        surfaces.node.placeTop();
    }

    if (bar.pending_render.draw) {
        bar.draw() catch |err| {
            log.err("Bar draw failed: {}", .{err});
        };
    }
}

/// Draw the bar and its components (clock, title, etc.)
pub fn draw(bar: *Bar) !void {
    const context = bar.context;
    const options = bar.options;

    const scale = bar.font_scale;

    // Scaled width/height
    const render_width = bar.geometry.width * scale;
    const render_height = bar.geometry.height * scale;

    // Don't have anything to render
    if (render_width == 0 or render_height == 0 or scale == 0) {
        return;
    }
    const buffer = try context.buffer_pool.nextBuffer(bar.context.wl_shm, render_width, render_height);

    // Fill with a solid color (e.g., dark background)
    const bg_color = options.background_color;
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
    const text_color = options.text_color;
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
    const y: i32 = @divFloor(buffer.height - bar.fcft_fonts.height, 2);

    // Actually render the unicode codepoints
    try bar.renderChars(codepoints, buffer, &x, y, color);

    // Finally, attach the buffer to the surface
    const surfaces = bar.surfaces orelse return error.NoSurfaces;
    const wl_surface = surfaces.wl_surface;
    surfaces.river_shell_surface.syncNextCommit();
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
        const glyph = try bar.fcft_fonts.rasterizeCharUtf32(cp, .default);
        width += glyph.advance.x;
        if (i > 0) {
            var x_kern: c_long = 0;
            if (bar.fcft_fonts.kerning(text[i - 1], cp, &x_kern, null)) {
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
        glyphs[i] = try bar.fcft_fonts.rasterizeCharUtf32(text[i], .default);

        kerns[i] = 0;
        if (i > 0) {
            var x_kern: c_long = 0;
            if (bar.fcft_fonts.kerning(text[i - 1], text[i], &x_kern, null)) {
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
                    y + bar.fcft_fonts.ascent - @as(i32, @intCast(glyphs[i].y)),
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
                    y + bar.fcft_fonts.ascent - @as(i32, @intCast(glyphs[i].y)),
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
            log.debug("Scaling font DPI: base={d} scale={d}", .{ base_dpi, scale });
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
const assert = std.debug.assert;
const io = std.io;
const mem = std.mem;
const process = std.process;
const unicode = std.unicode;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const fcft = @import("fcft");
const pixman = @import("pixman");
const zeit = @import("zeit");

const utils = @import("utils.zig");
const Rect = utils.Rect;
const Buffer = @import("Buffer.zig");
const Context = @import("Context.zig");
const Output = @import("Output.zig");

const log = std.log.scoped(.Bar);
