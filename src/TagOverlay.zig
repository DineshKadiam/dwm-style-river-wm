// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

//! TagOverlay is a Zig clone of Leon Plickat's river-tag-overlay but built for beansprout
//! Find river-tag-overlay at: https://git.sr.ht/~leon_plickat/river-tag-overlay/

const TagOverlay = @This();

context: *Context,

options: Options,

output: *Output,

// Overlay geometry
width: u31 = 0,
height: u31 = 0,
scale: u31 = 1,

rows: u31,

surfaces: ?struct {
    wl_surface: *wl.Surface,
    layer_surface: *zwlr.LayerSurfaceV1,
} = null,

configured: bool = false,

pub const Options = struct {
    /// Width of the widget border in pixels
    border_width: u8,
    /// Number of displayed tags
    /// Put in config as 1-32 but we subtract 1 to store it in a u5
    tag_amount: u5,
    /// Amount of tags per row
    /// Put in config as 1-32 but we subtract 1 to store it in a u5
    tags_per_row: u5,
    /// Size of tag squares in pixels
    square_size: u8,
    /// Padding around the tag occupied indicator in pixels
    square_inner_padding: u8,
    /// Padding around tag squares in pixels
    square_padding: u8,
    /// Border width of the tag squares in pixels
    square_border_width: u8,
    /// Widget background color
    background_color: pixman.Color,
    /// Widget border color
    border_color: pixman.Color,
    /// Background color of active tag squares
    square_active_background_color: pixman.Color,
    /// Border color of active tag squares
    square_active_border_color: pixman.Color,
    /// Occupied indicator color of active tag squares
    square_active_occupied_color: pixman.Color,
    /// Background color of inactive tag squares
    square_inactive_background_color: pixman.Color,
    /// Border color of inactive tag squares
    square_inactive_border_color: pixman.Color,
    /// Occupied indicator color of inactive tag squares
    square_inactive_occupied_color: pixman.Color,
    // XXX: We do not support urgent windows right now
    // /// Background color of urgent tag squares
    // square_urgent_background_color: pixman.Color,
    // /// Border color of urgent tag squares
    // square_urgent_border_color: pixman.Color,
    // /// Occupied indicator color of urgent tag squares
    // square_urgent_occupied_color: pixman.Color,
    /// Directional anchors top, right bottom, left; true for on, false for off
    anchors: zwlr.LayerSurfaceV1.Anchor,
    /// Directional margins top, right, bottom, left, in pixels
    margins: struct { top: i32 = 0, right: i32 = 0, bottom: i32 = 0, left: i32 = 0 } = .{},
    /// Duration of widget display in milliseconds
    timeout: u32,
};

pub fn init(context: *Context, output: *Output, options: Options) !TagOverlay {
    const rows = try math.divCeil(u31, options.tag_amount, options.tags_per_row);

    return .{
        .context = context,
        .options = options,
        .rows = rows,
        .output = output,
    };
}

pub fn initSurface(tag_overlay: *TagOverlay) !void {
    if (tag_overlay.surfaces) |_| {
        // This tag overlay already has a layer surface, we can exit early
        return;
    }

    const context = tag_overlay.context;
    const options = tag_overlay.options;

    const wl_surface = try context.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    const layer_surface = try context
        .zwlr_layer_shell_v1
        .getLayerSurface(wl_surface, tag_overlay.output.wl_output, .overlay, "beansprout-tag-overlay");
    errdefer layer_surface.destroy();
    layer_surface.setExclusiveZone(-1);

    // We don't want our surface to have any input region (default is infinite)
    const empty_region = try context.wl_compositor.createRegion();
    defer empty_region.destroy();
    wl_surface.setInputRegion(empty_region);

    const surface_width = (@min(options.tag_amount, options.tags_per_row) * (options.square_size + options.square_padding)) + options.square_padding + (2 * options.border_width);
    const surface_height = (options.rows * (options.square_size + options.square_padding)) + options.square_padding + (2 * options.border_width);
    layer_surface.setSize(surface_width, surface_height);

    layer_surface.setAnchor(options.anchors);
    layer_surface.setMargin(options.margins);

    tag_overlay.surfaces = .{ .wl_surface = wl_surface, .layer_surface = layer_surface };
    context.buffer_pool.surface_count += 1;

    // layer_surface.setListener(*Bar, layerSurfaceListener, bar);
    wl_surface.commit();
}

pub fn deinit(tag_overlay: *TagOverlay) void {
    tag_overlay.configured = false;
    if (tag_overlay.surfaces) |surfaces| {
        surfaces.wl_surface.destroy();
        surfaces.layer_surface.destroy();
        tag_overlay.context.buffer_pool.surface_count -= 1;
    }
}

pub fn layerSurfaceListener(
    layer_surface: *zwlr.LayerSurfaceV1,
    event: zwlr.LayerSurfaceV1.Event,
    tag_overlay: *TagOverlay,
) void {
    assert(tag_overlay.surfaces.?.layer_surface == layer_surface);
    switch (event) {
        .configure => |ev| {
            layer_surface.ackConfigure(ev.serial);
            const width: u31 = @intCast(ev.width);
            const height: u31 = @intCast(ev.height);

            if (tag_overlay.configured and
                tag_overlay.width == width and
                tag_overlay.height == height and
                tag_overlay.output.scale == tag_overlay.scale)
            {
                tag_overlay.surfaces.?.wl_surface.commit();
                return;
            }

            log.debug("Configuring tag_overlay surface with width {} and height {}", .{ width, height });
            tag_overlay.width = width;
            tag_overlay.height = height;

            // Full surface should be opaque
            const opaque_region: *wl.Region = tag_overlay.context.wl_compositor.createRegion() catch |e| {
                log.err("Failed to create opaque region for tag_overlay: {}", .{e});
                return;
            };
            defer opaque_region.destroy();
            opaque_region.add(0, 0, tag_overlay.width, tag_overlay.height);
            tag_overlay.surfaces.?.wl_surface.setOpaqueRegion(opaque_region);

            tag_overlay.configured = true;

            tag_overlay.render() catch |err| {
                log.err("tag_overlay render failed: {}", .{err});
            };
        },
        .closed => {
            tag_overlay.deinit();
        },
    }
}

pub fn render(tag_overlay: *TagOverlay) !void {
    const context = tag_overlay.context;
    const options = tag_overlay.options;

    // Scaled width/height
    const scale = tag_overlay.output.scale;
    const render_width = tag_overlay.width * scale;
    const render_height = tag_overlay.height * scale;

    // Don't have anything to render
    if (render_width == 0 or render_height == 0) {
        return;
    }
    const buffer = try context.buffer_pool.nextBuffer(context.wl_shm, render_width, render_height);

    buffer.borderedRectangle(0, 0, tag_overlay.width, tag_overlay.height, options.border_width, scale, options.background_color, options.border_color);

    const focused_tags = tag_overlay.output.tags;
    const occupied_tags = tag_overlay.output.occupiedTags();

    for (0..tag_overlay.rows) |row| {
        for (0..options.tags_per_row) |tag| {
            const current_tag = tag + row * options.tags_per_row;
            if (current_tag >= options.tag_amount) break;

            const bg_color, const border_color, const occupied_color =
                // Check whether this tag is focused or not to decide colors
                if (focused_tags & (@as(u32, 1) << @intCast(current_tag)) != 0)
                    .{ &options.square_active_background_color, &options.square_active_border_color, &options.square_active_occupied_color }
                else
                    .{ &options.square_inactive_background_color, &options.square_inactive_border_color, &options.square_inactive_occupied_color };

            const x = options.border_width + ((tag + 1) * options.square_padding) + (tag * options.square_size);
            const y = options.border_width + ((row + 1) * options.square_padding) + (row * options.square_size);

            buffer.borderedRectangle(x, y, options.square_size, options.square_size, options.square_border_width, scale, bg_color, border_color);

            if (occupied_tags & (@as(u32, 1) << @intCast(current_tag)) != 0) {
                buffer.borderedRectangle(
                    x + options.square_inner_padding,
                    y + options.square_inner_padding,
                    options.square_size - 2 * options.square_inner_padding,
                    options.square_size - 2 * options.square_inner_padding,
                    options.square_border_width,
                    scale,
                    occupied_color,
                    border_color,
                );
            }
        }
    }

    // Finally, attach the buffer to the surface
    const surfaces = tag_overlay.surfaces orelse return error.NoSurfaces;
    const wl_surface = surfaces.wl_surface;
    wl_surface.setBufferScale(scale);
    wl_surface.attach(buffer.wl_buffer, 0, 0);
    wl_surface.damageBuffer(0, 0, render_width, render_height);
    wl_surface.commit();
}

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const fcft = @import("fcft");
const pixman = @import("pixman");

const utils = @import("utils.zig");
const Buffer = @import("Buffer.zig");
const Context = @import("Context.zig");
const Output = @import("Output.zig");

const log = std.log.scoped(.TagOverlay);
