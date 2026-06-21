// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

//! TagOverlay is a Zig clone of Leon Plickat's river-tag-overlay but built for beansprout
//! Find river-tag-overlay at: https://git.sr.ht/~leon_plickat/river-tag-overlay/

const TagOverlay = @This();

context: *Context,

options: Options,

output: *Output,

rows: u31,

surfaces: ?struct {
    wl_surface: *wl.Surface,
    river_shell_surface: *river.ShellSurfaceV1,
    node: *river.NodeV1,
} = null,

/// Monotonic timestamp of the last time the overlay was shown/refreshed.
/// Used by the event loop to hide the overlay after `options.timeout` ms.
last_shown: ?Io.Timestamp = null,

pending_render: PendingRender = .{},

pub const PendingRender = struct {
    should_draw: bool = false,
};

pub const Options = struct {
    /// Width of the widget border in pixels
    border_width: u8,
    /// Number of displayed tags (1-32)
    tag_amount: u6,
    /// Amount of tags per row (1-32)
    tags_per_row: u6,
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

pub fn deinit(tag_overlay: *TagOverlay) void {
    tag_overlay.deinitSurfaces();
    tag_overlay.output.tag_overlay = null;
}

pub fn reconfigure(tag_overlay: *TagOverlay, options: Options) void {
    tag_overlay.options = options;
    tag_overlay.rows = math.divCeil(u31, options.tag_amount, options.tags_per_row) catch {
        log.err("Failed to calculate rows for tag overlay", .{});
        return;
    };
}

pub fn initSurfaces(tag_overlay: *TagOverlay) !void {
    if (tag_overlay.surfaces != null) return;

    const context = tag_overlay.context;

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

    const now = Io.Timestamp.now(io, .awake);

    context.buffer_pool.surface_count += 1;

    tag_overlay.surfaces = .{
        .wl_surface = wl_surface,
        .river_shell_surface = river_shell_surface,
        .node = node,
    };
    tag_overlay.last_shown = now;
    tag_overlay.pending_render.should_draw = true;
}

pub fn deinitSurfaces(tag_overlay: *TagOverlay) void {
    const surfaces = tag_overlay.surfaces orelse return;
    surfaces.node.destroy();
    surfaces.river_shell_surface.destroy();
    surfaces.wl_surface.destroy();
    tag_overlay.context.buffer_pool.surface_count -= 1;
    tag_overlay.surfaces = null;
    tag_overlay.last_shown = null;
}

pub fn render(tag_overlay: *TagOverlay) void {
    defer tag_overlay.pending_render = .{};

    if (tag_overlay.pending_render.should_draw) {
        tag_overlay.draw() catch |err| {
            log.err("tag_overlay draw failed: {}", .{err});
        };
    }
}

pub fn draw(tag_overlay: *TagOverlay) !void {
    const surfaces = tag_overlay.surfaces orelse return;
    const context = tag_overlay.context;
    const options = tag_overlay.options;

    // Scaled width/height
    const surface_width: u31 = @as(u31, @min(options.tag_amount, options.tags_per_row)) * (@as(u31, options.square_size) + options.square_padding) + options.square_padding + 2 * @as(u31, options.border_width);
    const surface_height: u31 = @as(u31, tag_overlay.rows) * (@as(u31, options.square_size) + options.square_padding) + options.square_padding + 2 * @as(u31, options.border_width);
    const scale = tag_overlay.output.scale;
    const render_width = surface_width * scale;
    const render_height = surface_height * scale;

    // Don't have anything to render
    if (render_width == 0 or render_height == 0) {
        return;
    }
    const buffer = try context.buffer_pool.nextBuffer(context.wl_shm, render_width, render_height);

    buffer.borderedRectangle(.{ .width = surface_width, .height = surface_height }, options.border_width, scale, &options.background_color, &options.border_color);

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

            const x = options.border_width + @as(u31, @intCast((tag + 1) * options.square_padding)) + @as(u31, @intCast(tag * options.square_size));
            const y = options.border_width + @as(u31, @intCast((row + 1) * options.square_padding)) + @as(u31, @intCast(row * options.square_size));

            buffer.borderedRectangle(.{ .x = x, .y = y, .width = options.square_size, .height = options.square_size }, options.square_border_width, scale, bg_color, border_color);

            if (occupied_tags & (@as(u32, 1) << @intCast(current_tag)) != 0) {
                buffer.borderedRectangle(
                    .{
                        .x = x + options.square_inner_padding,
                        .y = y + options.square_inner_padding,
                        .width = options.square_size - 2 * options.square_inner_padding,
                        .height = options.square_size - 2 * options.square_inner_padding,
                    },
                    options.square_border_width,
                    scale,
                    occupied_color,
                    border_color,
                );
            }
        }
    }

    // Position the overlay centered on the output
    const output_geo = tag_overlay.output.geometry;
    const x = output_geo.x + @divFloor(output_geo.width - surface_width, 2);
    const y = output_geo.y + @divFloor(output_geo.height - surface_height, 2);
    surfaces.node.setPosition(x, y);
    surfaces.node.placeTop();

    // Finally, attach the buffer to the surface
    const wl_surface = surfaces.wl_surface;
    wl_surface.setBufferScale(scale);
    wl_surface.attach(buffer.wl_buffer, 0, 0);
    wl_surface.damageBuffer(0, 0, render_width, render_height);
    wl_surface.commit();
}

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const time = std.time;
const Io = std.Io;
const io = Io.Threaded.global_single_threaded.io();

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const fcft = @import("fcft");
const pixman = @import("pixman");

const utils = @import("utils.zig");
const Buffer = @import("Buffer.zig");
const Context = @import("Context.zig");
const Output = @import("Output.zig");

const log = std.log.scoped(.TagOverlay);
