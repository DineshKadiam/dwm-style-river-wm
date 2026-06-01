// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Output = @This();

context: *Context,

river_output_v1: *river.OutputV1,
river_layer_shell_output_v1: *river.LayerShellOutputV1,

/// We have to wait for the rwm.wl_output event to get this
wl_output: ?*wl.Output = null,

/// Friendly name of this output
name: ?[]const u8 = null,

/// Description of this output
description: ?[]const u8 = null,

scale: u31 = 1,
/// The rect for the entire output, this includes space that's taken by widgets like bars and not
/// made available to windows.
geometry: Rect = .{},

/// Output geometry minus layer shell exclusive zones
non_exclusive_area: Rect = .{},

/// Area available for window layout (non_exclusive_area minus bar space)
usable_geometry: Rect = .{},

wallpaper: ?Wallpaper = null,

bar: ?Bar,
tag_overlay: ?TagOverlay,

/// Proportion of output width taken by the primary stack
primary_ratio: f32,

/// Number of windows in the primary stack
primary_count: u8,

/// Proportion of output width taken by a window when it is the only visible tiled window
single_window_ratio: f32,

/// Per-tagmask layout overrides
/// These only get added when the user modifies primary count or ratio
/// Any tagmask NOT in this map keeps using the defaults from Config
tag_layout_overrides: std.AutoHashMapUnmanaged(u32, TagLayoutOverride) = .{},

/// Tags are 32-bit bitfield. A window can be active on one(?) or more tags.
tags: u32 = 0x0001,

/// When this is `.async`, the compositor will allow the output to tear
presentation_mode: PresentationMode = .vsync,

/// State consumed in manage() phase, reset at end of manage().
pending_manage: PendingManage = .{},

/// State consumed in render() phase, reset at end of render().
pending_render: PendingRender = .{},

windows: wl.list.Head(Window, .link),

link: wl.list.Link,

/// Struct used for tagmask-specific count/ratio overrides
const TagLayoutOverride = struct {
    primary_count: u8,
    primary_ratio: f32,
};

const PendingManage = struct {
    position: ?struct { x: i32, y: i32 } = null,
    dimensions: ?struct { width: u31, height: u31 } = null,
    non_exclusive_area: ?Rect = null,

    tags: ?u32 = null,
    primary_ratio: ?f32 = null,
    primary_count: ?u8 = null,
    single_window_ratio: ?f32 = null,
};

const PendingRender = struct { presentation_mode: ?PresentationMode = null };

pub fn create(context: *Context, river_output_v1: *river.OutputV1) !*Output {
    var output = try utils.gpa.create(Output);
    errdefer utils.gpa.destroy(output);

    output.* = .{
        .context = context,
        .river_output_v1 = river_output_v1,
        .river_layer_shell_output_v1 = try context.river_layer_shell_v1.getOutput(river_output_v1),
        .bar = null,
        .tag_overlay = null,
        .primary_count = context.config.primary_count,
        .primary_ratio = context.config.primary_ratio,
        .single_window_ratio = context.config.single_window_ratio,
        .windows = undefined, // we will initialize this shortly
        .link = undefined, // Handled by the wl.list
    };

    output.bar = if (context.config.bar_config) |bar_config| blk: {
        break :blk Bar.init(context, output, bar_config.toBarOptions()) catch |e| {
            log.err("Failed to create a bar: {}", .{e});
            break :blk null;
        };
    } else null;
    errdefer if (output.bar) |*b| b.deinit();

    output.tag_overlay = if (context.config.tag_overlay_config) |tag_overlay_config| blk: {
        break :blk TagOverlay.init(context, output, tag_overlay_config.toTagOverlayOptions()) catch |e| {
            log.err("Failed to create a tag overlay: {}", .{e});
            break :blk null;
        };
    } else null;

    output.windows.init();

    output.river_output_v1.setListener(*Output, riverOutputListener, output);
    output.river_layer_shell_output_v1.setListener(*Output, riverLayerShellOutputListener, output);

    return output;
}

pub fn destroy(output: *Output) void {
    const context = output.context;
    const wm = context.wm;

    // Before we destroy the output, we wnant to take care of any window that are on it
    // We chooe to move windows to the previous output in the WM's output list
    // If this was the only output, windows go to the WM's orphan window list instead
    const prev_output: ?*Output = if (wm.prevOutput(output)) |prev| blk: {
        if (prev == output) break :blk null; // Only output; wrapped to itself
        break :blk prev;
    } else unreachable;

    const window_pending_output: Window.PendingManage.PendingOutput =
        if (prev_output) |prev|
            .{ .output = prev }
        else
            .clear_output;

    // Update each window's output before moving the list
    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        window.pending_manage.pending_output = window_pending_output;
    }

    // Finally, move the windows to their new output (or the orphan list)
    const dest_list = if (prev_output) |prev| &prev.windows else &wm.orphan_windows;
    dest_list.appendList(&output.windows);

    seat_blk: {
        // If the output was focused, move focus to the output that took this one's windows
        // (and its first window, if any).
        const seat = wm.seats.first() orelse break :seat_blk;
        const focused = seat.focused orelse break :seat_blk;
        if (focused.output != output) break :seat_blk;

        seat.pending_manage.focus = if (prev_output) |prev|
            .{ .focus = .{
                .output = prev,
                .window = if (prev.windows.first()) |window| window else null,
            } }
        else
            .clear;
    }

    // Deinit optional surfaces
    if (output.bar) |*bar| bar.deinit();
    if (output.tag_overlay) |*tag_overlay| tag_overlay.deinit();
    if (output.wallpaper) |*wallpaper| wallpaper.deinit();

    // Destroy/deinit other Output fields
    output.tag_layout_overrides.deinit(utils.gpa);
    if (output.name) |name| utils.gpa.free(name);
    if (output.description) |description| utils.gpa.free(description);

    // Destroy/release relevant Wayland interfaces
    output.river_layer_shell_output_v1.destroy();
    output.river_output_v1.destroy();
    if (output.wl_output) |wl_output| wl_output.release();

    output.link.remove();
    utils.gpa.destroy(output);
}

/// Get the next window in the list that shares at least one tag
/// with the output, wrapping to first if at end.
pub fn nextWindow(output: *Output, current: *Window) ?*Window {
    var link = current.link.next.?;
    while (true) {
        // If this is the sentinel, wrap to the beginning
        if (link == &output.windows.link) {
            link = link.next.?;
        }
        const window: *Window = @fieldParentPtr("link", link);
        if (window.tags & output.tags != 0 or window == current) return window;
        link = link.next.?;
    }
}

/// Get the previous window in the list that shares at least one tag
/// with the output, wrapping to the last if at beginning
pub fn prevWindow(output: *Output, current: *Window) ?*Window {
    var link = current.link.prev.?;
    while (true) {
        // If this is the sentinel, wrap to the end
        if (link == &output.windows.link) {
            link = link.prev.?;
        }
        const window: *Window = @fieldParentPtr("link", link);
        if (window.tags & output.tags != 0 or window == current) return window;
        link = link.prev.?;
    }
}

fn riverLayerShellOutputListener(
    _: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    output: *Output,
) void {
    switch (event) {
        .non_exclusive_area => |area| {
            output.pending_manage.non_exclusive_area = .{
                .x = area.x,
                .y = area.y,
                .width = @intCast(area.width),
                .height = @intCast(area.height),
            };
        },
    }
}

fn riverOutputListener(
    river_output_v1: *river.OutputV1,
    event: river.OutputV1.Event,
    output: *Output,
) void {
    assert(output.river_output_v1 == river_output_v1);
    switch (event) {
        .removed => {
            output.destroy();
        },
        .wl_output => |ev| {
            // We wait to bind the wl_output here so that our listener is set before the server sends
            // the initial events (.scale, .mode, .name, .done, etc.). The .done handler will init
            // bar/wallpaper surfaces.
            const wl_output = output.context.wl_registry.bind(ev.name, wl.Output, 4) catch |err| {
                log.err("Failed to bind wl_output: {}", .{err});
                return;
            };
            wl_output.setListener(*Output, wlOutputListener, output);
            output.wl_output = wl_output;
        },
        .dimensions => |ev| {
            output.pending_manage.dimensions = .{
                .width = @intCast(ev.width),
                .height = @intCast(ev.height),
            };
        },
        .position => |ev| {
            output.pending_manage.position = .{
                .x = ev.x,
                .y = ev.y,
            };
        },
    }
}

// Used for the wl_output global interface that corresponds to the river_output_v1
fn wlOutputListener(_: *wl.Output, event: wl.Output.Event, output: *Output) void {
    switch (event) {
        .done => {
            if (output.context.wallpaper_image != null and output.wallpaper == null) {
                output.wallpaper = Wallpaper.init(output.context, output) catch |err| {
                    const output_name = output.name orelse "some output";
                    log.err("Failed to add a wallpaper surface to {s}: {}", .{ output_name, err });
                    return;
                };
            }
            if (output.bar) |*bar| {
                // Trigger a full manage cycle if the scale changed so that
                // fonts are reloaded and bar geometry is recalculated.
                if (output.scale != bar.font_scale) {
                    bar.pending_manage.output_geometry = true;
                }
            }
        },
        .scale => |ev| {
            if (ev.factor < 0) {
                // I'm not actually sure if this is possible, but just to be safe
                log.warn("Received wl_output.scale event with a negative factor ({d})", .{ev.factor});
                return;
            }
            const new_scale: u31 = @intCast(ev.factor);
            if (new_scale != output.scale) {
                output.scale = new_scale;
                if (output.wallpaper) |*wallpaper| {
                    wallpaper.pending_render.draw = true;
                }
            }
        },
        .name => |ev| {
            if (output.name) |old_name| utils.gpa.free(old_name);
            output.name = utils.gpa.dupe(u8, mem.span(ev.name)) catch @panic("Out of memory");
        },
        .description => |ev| {
            if (output.description) |old_description| utils.gpa.free(old_description);
            output.description = utils.gpa.dupe(u8, mem.span(ev.description)) catch @panic("Out of memory");
        },
        else => {},
    }
}

pub fn manage(output: *Output) void {
    defer output.pending_manage = .{};

    if (output.pending_manage.position) |position| {
        output.geometry.x = position.x;
        output.geometry.y = position.y;
    }
    if (output.pending_manage.dimensions) |dimensions| {
        output.geometry.width = dimensions.width;
        output.geometry.height = dimensions.height;
    }

    if (output.pending_manage.non_exclusive_area) |non_exclusive_area| {
        output.non_exclusive_area = non_exclusive_area;
    }

    if (output.pending_manage.position != null or
        output.pending_manage.dimensions != null or
        output.pending_manage.non_exclusive_area != null)
    {
        if (output.wallpaper) |*wallpaper| {
            wallpaper.pending_render.draw = true;
        }
        if (output.bar) |*bar| {
            bar.pending_manage.output_geometry = true;
        }
    }

    if (output.pending_manage.primary_ratio) |primary_ratio| {
        // Ratios outside of this range could cause crashes (when doing the layout calculation)
        output.primary_ratio = std.math.clamp(
            primary_ratio,
            Config.min_primary_ratio,
            Config.max_primary_ratio,
        );
        if (output.bar) |*bar| {
            bar.pending_render.draw = true;
        }
    }
    if (output.pending_manage.primary_count) |primary_count| {
        // Don't allow less than 1 primary
        output.primary_count = @max(1, primary_count);
        if (output.bar) |*bar| {
            bar.pending_render.draw = true;
        }
    }
    if (output.pending_manage.single_window_ratio) |single_window_ratio| {
        output.single_window_ratio = std.math.clamp(
            single_window_ratio,
            Config.min_primary_ratio,
            1.00,
        );
        if (output.bar) |*bar| {
            bar.pending_render.draw = true;
        }
    }

    if (output.pending_manage.tags) |new_tags| {
        // Save current layout for the old tagmask
        output.tag_layout_overrides.put(utils.gpa, output.tags, .{
            .primary_count = output.primary_count,
            .primary_ratio = output.primary_ratio,
        }) catch @panic("Out of memory");

        // Restore layout for the new tagmask, or fall back to config defaults
        if (output.tag_layout_overrides.get(new_tags)) |tag_layout_override| {
            output.primary_count = tag_layout_override.primary_count;
            output.primary_ratio = tag_layout_override.primary_ratio;
        } else {
            output.primary_count = output.context.config.primary_count;
            output.primary_ratio = output.context.config.primary_ratio;
        }

        output.tags = new_tags;

        // If the focused window is no longer visible on the new tags, update focus.
        if (output.context.wm.seats.first()) |seat| {
            if (seat.focused) |focused| if (focused.output == output) {
                // Whether focus has changed, either to a new window or to no focus
                if (focused.window == null or focused.window.?.tags & new_tags == 0) {
                    var new_focus: ?*Window = null;
                    var it = output.windows.iterator(.forward);
                    while (it.next()) |window| {
                        if (window.tags & new_tags != 0) {
                            new_focus = window;
                            break;
                        }
                    }
                    if (new_focus) |window| {
                        seat.pending_manage.focus = .{ .focus = .{
                            .output = output,
                            .window = window,
                        } };
                        seat.pending_manage.should_warp_pointer = true;
                    } else {
                        seat.pending_manage.focus = .{ .focus = .{
                            .output = output,
                            .window = null,
                        } };
                    }
                }
            };
        }

        // Show tag overlay (or refresh its timeout if already visible)
        if (output.tag_overlay) |*tag_overlay| blk: {
            tag_overlay.initSurfaces() catch |e| {
                log.err("Failed to show TagOverlay: {}", .{e});
                break :blk;
            };
            tag_overlay.last_shown = Io.Timestamp.now(io, .awake);
            tag_overlay.pending_render.draw = true;
        }

        if (output.bar) |*bar| {
            bar.pending_render.draw = true;
        }
    }

    if (output.bar) |*bar| {
        bar.manage() catch |err| {
            log.err("Bar manage failed: {}", .{err});
        };
    }

    // Compute usable geometry starting from the non-exclusive area reported by the layer shell,
    // then additionally subtract space for beansprout's own bar (which uses river shell, not layer
    // shell, so it's not included in the exclusive zone calculation).
    output.usable_geometry = output.non_exclusive_area;
    if (output.bar) |bar| {
        if (bar.geometry.height > 0) {
            const bar_height: i32 = bar.geometry.height;
            const margins = bar.options.margins;
            const reserved: u31 = @intCast(bar_height + margins.top + margins.bottom);
            switch (bar.options.position) {
                .top => {
                    output.usable_geometry.y += bar_height + margins.top + margins.bottom;
                    output.usable_geometry.height -|= reserved;
                },
                .bottom => {
                    output.usable_geometry.height -|= reserved;
                },
            }
        }
    }

    // Calculate layout before managing windows, but only if output dimensions are initialized
    if (output.usable_geometry.width > 0 and output.usable_geometry.height > 0) {
        @branchHint(.likely);
        output.calculateLayout();
    }

    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        window.manage();
    }
}

pub fn render(output: *Output) void {
    defer output.pending_render = .{};

    if (output.wallpaper) |*wallpaper| {
        wallpaper.render();
    }

    if (output.bar) |*bar| {
        bar.render();
    }

    if (output.tag_overlay) |*tag_overlay| {
        tag_overlay.render();
    }

    const seat = output.context.wm.seats.first();
    const focused = if (seat) |s| s.focused else null;

    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        window.render();

        // Make sure floating windows are above tiled windows
        if (window.floating and output.tags & window.tags != 0) {
            window.river_node_v1.placeTop();
        }
    }

    // Make sure that the *focused* floating window goes above any other floating windows
    if (focused) |f| if (f.window) |focused_window| {
        if (focused_window.floating and focused_window.output == output) {
            // If the window is focused, it must be visible. Not being visible is a bug.
            assert(output.tags & focused_window.tags != 0);

            focused_window.river_node_v1.placeTop();
        }
    };

    if (output.pending_render.presentation_mode) |mode| {
        output.river_output_v1.setPresentationMode(mode);
        output.presentation_mode = mode;
    }
}

/// Calculate primary/stack layout positions for all windows
/// - Single window: window is told it's maximized and takes up usable_width * single_window_ratio width
/// - Multiple windows: two stacks, primary and secondary. By default, the stack is on the left and takes
///     up 55% of the output width, but this can be configured. Each tagmask has its own primary ratio and count
///
/// Must not be called until the output has dimensions
fn calculateLayout(output: *Output) void {
    // Shouldn't be called if height/width are not positive
    assert(output.geometry.width > 0 and output.geometry.height > 0);

    // Get a list of active tiled windows
    // i.e. any windows that are:
    // - on this output
    // - have at least one active tag
    // - are not fullscreen or floating
    var active_list: DoublyLinkedList = .{};
    var active_count: u31 = 0;
    var async_count: usize = 0;
    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        // Initialize new windows early so that window rules are applied to the layout
        if (!window.initialized) {
            @branchHint(.unlikely);
            window.initialize();
        }
        if (output.tags & window.tags != 0x0000) {
            // Fullscreen and floating windows should be shown but not included in layout generation
            const will_be_fullscreen = window.pending_manage.fullscreen orelse window.fullscreen;
            const will_float = window.pending_manage.floating orelse window.floating;
            if (!will_be_fullscreen and !will_float) {
                active_count += 1;
                active_list.append(&window.active_list_node);
            }

            switch (window.presentation_mode) {
                .vsync => {}, // Nothing to do
                .async => async_count +|= 1,
                else => unreachable,
            }

            window.pending_render.show = true;
        } else {
            window.pending_render.show = false;
        }
    }

    // Only set presentation mode if it's changing
    if (async_count > 0) {
        if (output.presentation_mode == .vsync) {
            output.pending_render.presentation_mode = .async;
        }
    } else {
        if (output.presentation_mode == .async) {
            output.pending_render.presentation_mode = .vsync;
        }
    }

    if (active_count == 0) return;

    // Use the usable area for layout so windows don't overlap the bar
    const output_x = output.usable_geometry.x;
    const output_y = output.usable_geometry.y;
    const output_width = output.usable_geometry.width;
    const output_height = output.usable_geometry.height;
    const border_width = output.context.config.border_width;

    // Single window: maximize and return early
    if (active_count == 1) {
        const window: *Window = @fieldParentPtr("active_list_node", active_list.popFirst().?);

        const width = @as(u31, @intFromFloat(@as(f32, @floatFromInt(output_width)) * output.single_window_ratio)) -|
            2 * border_width;
        const x = output_x + @divFloor(output_width - width, 2);

        window.pending_render.position = .{ .x = x, .y = output_y + border_width };
        window.pending_manage.dimensions = .{
            .width = width,
            .height = output_height -| 2 * border_width,
        };
        window.pending_manage.maximized = true;
        return;
    }

    // Multiple windows: primary/stack layout
    const primary_count = @min(active_count, output.primary_count);
    const stack_count = active_count - primary_count;

    // Primary width is equal to output width when all windows are primaries
    // (since there would be no secondaries)
    const primary_width: u31 = if (primary_count == active_count)
        output_width
    else
        @intFromFloat(@as(f32, @floatFromInt(output_width)) * output.primary_ratio);
    const primary_height: u31 = @divFloor(output_height, primary_count);

    const stack_width: u31 = output_width - primary_width;
    const stack_height: u31 = if (stack_count > 0)
        @divFloor(output_height, stack_count)
    else
        0;

    // Determine the x coordinates based on whether primary is set to the left or right
    const primary_x, const stack_x = switch (output.context.config.primary_side) {
        .right => .{ output_x + @as(i32, stack_width), output_x },
        .left => .{ output_x, output_x + @as(i32, primary_width) },
    };

    // Iterate through the active windows and apply positions
    var i: u31 = 0;
    while (active_list.popFirst()) |node| : (i += 1) {
        const window: *Window = @fieldParentPtr("active_list_node", node);
        window.pending_manage.maximized = false;

        if (i < primary_count) {
            // Primary window(s)
            window.pending_render.position = .{
                .x = primary_x,
                .y = output_y + @as(i32, i) * @as(i32, primary_height),
            };
            const pending_width = primary_width;
            // Last primary window gets remaining height to avoid gaps from integer division
            const pending_height = if (i == primary_count - 1)
                output_height - i * primary_height
            else
                primary_height;
            window.pending_manage.dimensions = .{
                .width = pending_width,
                .height = pending_height,
            };
        } else {
            // Stack window(s)
            const stack_index = i - primary_count;
            window.pending_render.position = .{
                .x = stack_x,
                .y = output_y + @as(i32, stack_index) * @as(i32, stack_height),
            };
            const pending_width = stack_width;
            // Last stack window gets remaining height to avoid gaps from integer division
            const pending_height = if (stack_index == stack_count - 1)
                output_height - stack_index * stack_height
            else
                stack_height;
            window.pending_manage.dimensions = .{
                .width = pending_width,
                .height = pending_height,
            };
        }

        // Make space for borders
        if (window.pending_manage.dimensions.?.height > 2 * border_width and
            window.pending_manage.dimensions.?.width > 2 * border_width)
        {
            window.pending_manage.dimensions.?.height -= 2 * border_width;
            window.pending_manage.dimensions.?.width -= 2 * border_width;
        } else {
            log.warn("Can't add borders to some window; {s}'s dimensions are too small.", .{output.name orelse "some output"});
        }
        window.pending_render.position.?.x += border_width;
        window.pending_render.position.?.y += border_width;
    }

    // Make sure we went through the whole list
    assert(active_list.first == null);
}

pub fn occupiedTags(output: *Output) u32 {
    var occupied_tags: u32 = 0x0000;
    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        occupied_tags |= window.tags;
    }
    return occupied_tags;
}

pub fn countVisible(output: *Output) usize {
    var visible: usize = 0;
    var it = output.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window.tags & output.tags != 0) visible += 1;
    }
    return visible;
}

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const posix = std.posix;
const time = std.time;
const DoublyLinkedList = std.DoublyLinkedList;
const Io = std.Io;
const io = Io.Threaded.global_single_threaded.io();

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const PresentationMode = river.OutputV1.PresentationMode;

const utils = @import("utils.zig");
const Rect = utils.Rect;
const Bar = @import("Bar.zig");
const Config = @import("Config.zig");
const Context = @import("Context.zig");
const TagOverlay = @import("TagOverlay.zig");
const Wallpaper = @import("Wallpaper.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.Output);
