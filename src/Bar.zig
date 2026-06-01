// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Bar = @This();

/// Standard base DPI at a scale of 1
const base_dpi = 96;

/// Default strftime string to use for the clock
pub const default_time_format = "%Y-%m-%d %H:%M, %A";

context: *Context,

/// The timezone of the computer.
timezone: zeit.timezone.TimeZone,

options: Options,

fcft_fonts: *fcft.Font,
font_scale: u31 = 1,

output: *Output,

// Bar geometry
geometry: Rect = .{},

surfaces: struct {
    wl_surface: *wl.Surface,
    river_shell_surface: *river.ShellSurfaceV1,
    node: *river.NodeV1,
},

pending_manage: PendingManage = .{},
pending_render: PendingRender = .{},

const PendingManage = struct {
    /// Recalculate bar geometry (size and position) on the next manage cycle
    /// Set when output dimensions, position, scale, or exclusive zones change
    output_geometry: bool = false,
};

const PendingRender = struct {
    position: ?struct { x: i32, y: i32 } = null,
    draw: bool = false,
};

pub const Position = enum { top, bottom };
pub const Component = enum { title, clock, wm_info, none };

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
    margins: struct { top: u8 = 0, right: u8 = 0, bottom: u8 = 0, left: u8 = 0 } = .{},

    /// Vertical padding between bar edges and content, in pixels
    vertical_padding: u8 = 5,
    /// Horizontal padding between bar edges and content, in pixels
    horizontal_padding: u8 = 5,

    /// strftime format string for the clock display
    time_format: []const u8 = default_time_format,

    /// Which component to show on the left side of the bar
    left: Component = .title,
    /// Which component to show in the center of the bar
    center: Component = .clock,
    /// Which component to show on the right side of the bar
    right: Component = .wm_info,
};

pub fn init(context: *Context, output: *Output, options: Options) !Bar {
    const timezone = try zeit.local(utils.gpa, io, .{});
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
        .pending_manage = .{ .output_geometry = true },
    };
}

pub fn deinit(bar: *Bar) void {
    bar.timezone.deinit();
    bar.fcft_fonts.destroy();

    bar.surfaces.node.destroy();
    bar.surfaces.river_shell_surface.destroy();
    bar.surfaces.wl_surface.destroy();
    bar.context.buffer_pool.surface_count -= 1;

    bar.output.bar = null;
}

/// Update bar options in-place without destroying/recreating Wayland surfaces
/// This is used when reloading the config
pub fn reconfigure(bar: *Bar, options: Options) !void {
    const new_fonts = try getFcftFonts(options.fonts, bar.font_scale);
    bar.fcft_fonts.destroy();
    bar.fcft_fonts = new_fonts;
    bar.options = options;
    bar.pending_manage.output_geometry = true;
}

pub fn manage(bar: *Bar) !void {
    defer bar.pending_manage = .{};

    // Need to adjust for new output dimensions
    if (bar.pending_manage.output_geometry) {
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

        const logical_font_height = @divFloor(bar.fcft_fonts.height, @as(i32, bar.font_scale));
        const height: u31 = @intCast(logical_font_height + 2 * options.vertical_padding);
        // Use the non-exclusive area so the bar sits adjacent to any external layer shell
        // surfaces rather than overlapping them.
        const base = output.non_exclusive_area;
        const width: u31 = @as(u31, @intCast(base.width)) -| @as(u31, @intCast(options.margins.left + options.margins.right));

        if (bar.geometry.width != width or bar.geometry.height != height) {
            bar.geometry.width = width;
            bar.geometry.height = height;

            const opaque_region = try bar.context.wl_compositor.createRegion();
            defer opaque_region.destroy();
            opaque_region.add(0, 0, width, height);
            bar.surfaces.wl_surface.setOpaqueRegion(opaque_region);
        }

        const x = base.x + options.margins.left;
        const y = switch (options.position) {
            .top => base.y + options.margins.top,
            .bottom => base.y + base.height - bar.geometry.height - options.margins.bottom,
        };
        bar.pending_render.position = .{ .x = x, .y = y };
        bar.pending_render.draw = true;
    }
}

pub fn render(bar: *Bar) void {
    defer bar.pending_render = .{};

    const surfaces = bar.surfaces;

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
fn draw(bar: *Bar) !void {
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
    const text_color = pixman.Image.createSolidFill(&options.text_color) orelse return error.FailedToCreatePixmanImage;
    defer _ = text_color.unref();

    // Y is shared between all components
    const y: i32 = @divFloor(buffer.height - bar.fcft_fonts.height, 2);

    // Pre-compute codepoints for each component type

    // Clock
    var time_buf: [255:0]u8 = undefined;
    var time_writer = Io.Writer.fixed(&time_buf);
    const now = try zeit.instant(io, .{});
    const now_local = now.in(&bar.timezone);
    try now_local.time().strftime(&time_writer, options.time_format);
    const clock_codepoints = try utils.utf8ToCodepoints(time_writer.buffered());
    defer utils.gpa.free(clock_codepoints);

    // Title (empty string if no focused window)
    const focused_title: []const u8 = blk: {
        const seat = context.wm.seats.first() orelse break :blk "";
        const focused = seat.focused orelse break :blk "";
        const window = focused.window orelse break :blk "";
        break :blk window.title orelse "";
    };
    const title_codepoints = try utils.utf8ToCodepoints(focused_title);
    defer utils.gpa.free(title_codepoints);

    // WM info
    const output = bar.output;
    var wm_info_buf: [255:0]u8 = undefined;
    var wm_info_writer = Io.Writer.fixed(&wm_info_buf);
    const primary_ratio_percent: u32 = @intFromFloat(@round(output.primary_ratio * 100));
    try wm_info_writer.print("P:{d}/{d}%", .{ output.primary_count, primary_ratio_percent });
    if (output.single_window_ratio != 1) {
        const single_window_ratio_percent: u32 = @intFromFloat(@round(output.single_window_ratio * 100));
        try wm_info_writer.print("({d}%)", .{single_window_ratio_percent});
    }
    try wm_info_writer.print(" W:{d}({d})", .{ output.countVisible(), output.windows.length() });
    try wm_info_writer.flush();

    const wm_info_codepoints = try utils.utf8ToCodepoints(wm_info_writer.buffered());
    defer utils.gpa.free(wm_info_codepoints);

    // Map a Component to its pre-computed codepoints slice
    const componentSlice = struct {
        fn f(component: Component, clock: []u32, title: []u32, wm_info: []u32) []u32 {
            return switch (component) {
                .clock => clock,
                .title => title,
                .wm_info => wm_info,
                .none => &.{},
            };
        }
    }.f;

    // Measure center first; needed to constrain left and right widths
    const center_codepoints = componentSlice(options.center, clock_codepoints, title_codepoints, wm_info_codepoints);
    const center_width = try bar.textWidth(center_codepoints);
    var center_x: i32 = @divFloor(buffer.width - center_width, 2);

    // Render left slot
    const left_codepoints = componentSlice(options.left, clock_codepoints, title_codepoints, wm_info_codepoints);
    if (left_codepoints.len > 0) {
        const max_width = center_x - 2 * options.horizontal_padding;
        const truncated = try bar.truncateToWidth(left_codepoints, max_width);
        var x: i32 = options.horizontal_padding;
        try bar.renderChars(truncated, buffer, &x, y, text_color);
    }

    // Render right slot
    const right_codepoints = componentSlice(options.right, clock_codepoints, title_codepoints, wm_info_codepoints);
    if (right_codepoints.len > 0) {
        const max_width = buffer.width - (center_x + center_width) - 2 * options.horizontal_padding;
        const truncated = try bar.truncateToWidth(right_codepoints, max_width);
        const text_width = try bar.textWidth(truncated);
        var x: i32 = buffer.width - text_width - options.horizontal_padding;
        try bar.renderChars(truncated, buffer, &x, y, text_color);
    }

    // Render center slot
    if (center_codepoints.len > 0) {
        try bar.renderChars(center_codepoints, buffer, &center_x, y, text_color);
    }

    // Attach the buffer to the surface
    const surfaces = bar.surfaces;
    const wl_surface = surfaces.wl_surface;
    wl_surface.setBufferScale(scale);
    wl_surface.attach(buffer.wl_buffer, 0, 0);
    wl_surface.damageBuffer(0, 0, render_width, render_height);
    wl_surface.commit();
}

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

/// Return the longest prefix of `text` that fits within `max_width` pixels.
fn truncateToWidth(bar: *Bar, text: []const u32, max_width: i32) ![]const u32 {
    var width: i32 = 0;
    for (text, 0..) |cp, i| {
        const glyph = try bar.fcft_fonts.rasterizeCharUtf32(cp, .default);
        if (i > 0) {
            var x_kern: c_long = 0;
            if (bar.fcft_fonts.kerning(text[i - 1], cp, &x_kern, null)) {
                width += @intCast(x_kern);
            }
        }
        if (width + glyph.advance.x > max_width) {
            return text[0..i];
        }
        width += glyph.advance.x;
    }
    return text;
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
                try fmt.allocPrint(arena_alloc, "{s}:dpi={}", .{ font, @as(u32, base_dpi) * scale }),
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
const fmt = std.fmt;
const mem = std.mem;
const process = std.process;
const Io = std.Io;
const io = Io.Threaded.global_single_threaded.io();

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
