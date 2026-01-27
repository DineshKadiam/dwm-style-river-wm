// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Config = @This();

const CONFIG_FILE = "beansprout/config.kdl";

/// Width of window borders in pixels
border_width: u8 = 2,
/// Color of focused window's border in 0xRRGGBBAA or 0xRRGGBB form
border_color_focused: RiverColor = utils.parseRgbaComptime("0x89b4fa"),
/// Color of uffocused windows' borders in 0xRRGGBBAA or 0xRRGGBB form
border_color_unfocused: RiverColor = utils.parseRgbaComptime("0x1e1e2e"),

/// Where a new window should attach, top or bottom of the stack
attach_mode: AttachMode = .top,
/// Should focus change when the cursor moves onto a new window
focus_follows_pointer: bool = true,
/// Should the pointer warp to the center of newly-focused windows
pointer_warp_on_focus_change: bool = true,

pub const AttachMode = enum {
    top,
    bottom,
};

const NodeName = enum {
    attach_mode,
    focus_follows_pointer,
    pointer_warp_on_focus_change,
    borders,
};

const BorderNodeName = enum {
    width,
    color_focused,
    color_unfocused,
};

pub fn create() !*Config {
    var config: *Config = try utils.allocator.create(Config);
    errdefer config.destroy();
    config.* = .{}; // create() gives us undefined memory

    if (try known_folders.getPath(utils.allocator, .local_configuration)) |config_dir| blk: {
        defer utils.allocator.free(config_dir);

        const config_path = try std.fmt.allocPrint(utils.allocator, "{s}/{s}", .{ config_dir, CONFIG_FILE });
        defer utils.allocator.free(config_path);

        const file = fs.openFileAbsolute(config_path, .{}) catch break :blk;

        var read_buffer: [1024]u8 = undefined;
        var file_reader = file.reader(&read_buffer);

        config.load(&file_reader.interface) catch |err| {
            log.err("Error while loading config: {s}. Continuing with default config", .{@errorName(err)});
            // Overwrite any partially-loaded config
            config.* = .{};
        };
    }

    return config;
}

pub fn destroy(config: *Config) void {
    utils.allocator.destroy(config);
}

fn load(config: *Config, reader: *Io.Reader) !void {
    var parser = try kdl.Parser.init(utils.allocator, reader, .{});
    defer parser.deinit(utils.allocator);

    var next_child_block: ?NodeName = null;

    // Parse the KDL config
    while (try parser.next()) |event| {
        // First, we switch on the type of event
        switch (event) {
            .node => |node| {
                if (next_child_block) |child_block| {
                    log.warn("Expected child block for {s}, but got another node instead", .{@tagName(child_block)});
                }
                // If it's a node, we check if it's a valid NodeName
                const node_name = std.meta.stringToEnum(NodeName, node.name);
                if (node_name) |name| {
                    // Next, we have to check the specifics for the NodeName
                    switch (name) {
                        .attach_mode => {
                            const attach_mode_str = node.arg(&parser, 0) orelse "";
                            if (std.meta.stringToEnum(AttachMode, attach_mode_str)) |mode| {
                                config.attach_mode = mode;
                                log.debug("Setting attach_mode to {s}", .{@tagName(mode)});
                            } else {
                                log.warn("Invalid \"attach_mode\". Using default", .{});
                                continue;
                            }
                        },
                        .focus_follows_pointer => {
                            const focus_follows_pointer_str = node.arg(&parser, 0) orelse "";
                            if (config.boolFromKdlStr(focus_follows_pointer_str)) |focus_follows_pointer| {
                                config.focus_follows_pointer = focus_follows_pointer;
                                log.debug("Setting focus_follows_pointer to {}", .{focus_follows_pointer});
                            } else {
                                log.warn("Invalid \"focus_follows_pointer\". Using default", .{});
                                continue;
                            }
                        },
                        .pointer_warp_on_focus_change => {
                            const pointer_warp_on_focus_change_str = node.arg(&parser, 0) orelse "";
                            if (config.boolFromKdlStr(pointer_warp_on_focus_change_str)) |pointer_warp_on_focus_change| {
                                config.pointer_warp_on_focus_change = pointer_warp_on_focus_change;
                                log.debug("Setting pointer_warp_on_focus_change to {}", .{pointer_warp_on_focus_change});
                            } else {
                                log.warn("Invalid \"pointer_warp_on_focus_change\". Using default", .{});
                                continue;
                            }
                        },
                        .borders => {
                            next_child_block = .borders;
                        },
                    }
                } else {
                    log.warn("Invalid KDL node {s}. Ignoring it and carrying on", .{node.name});
                }
            },
            .child_block_begin => {
                if (next_child_block) |child_block| {
                    switch (child_block) {
                        .borders => try config.loadBordersChildBlock(&parser),
                        else => {
                            // Nothing else should ever be marked as a next_child_block
                            unreachable;
                        },
                    }
                    next_child_block = null;
                } else {
                    try config.skipChildBlock(&parser);
                }
            },
            .child_block_end => log.err("Reached unexpected .child_block_end. Ignoring it", .{}),
        }
    }
}

fn loadBordersChildBlock(config: *Config, parser: *kdl.Parser) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                // If it's a node, we check if it's a valid NodeName
                const node_name = std.meta.stringToEnum(BorderNodeName, node.name);
                if (node_name) |name| {
                    switch (name) {
                        .width => {
                            const width_str = node.arg(parser, 0) orelse "";
                            config.border_width = fmt.parseInt(u8, width_str, 10) catch {
                                log.warn("Invalid border.width \"{s}\"", .{width_str});
                                continue;
                            };
                            log.debug("Setting border.width to {d}", .{config.border_width});
                        },
                        .color_focused => {
                            const color_str = node.arg(parser, 0) orelse "";
                            config.border_color_focused = utils.parseRgba(color_str) catch {
                                log.warn("Invalid border.color_focused \"{s}\"", .{color_str});
                                continue;
                            };
                            log.debug("Setting border.color_focused to {s}", .{color_str});
                        },
                        .color_unfocused => {
                            const color_str = node.arg(parser, 0) orelse "";
                            config.border_color_unfocused = utils.parseRgba(color_str) catch {
                                log.warn("Invalid border.color_unfocused \"{s}\"", .{color_str});
                                continue;
                            };
                            log.debug("Setting border.color_unfocused to {s}", .{color_str});
                        },
                    }
                } else {
                    log.warn("Invalid KDL node {s}. Ignoring it and carrying on", .{node.name});
                }
            },
            .child_block_begin => {
                // borders should never have a nested child block
                try config.skipChildBlock(parser);
            },
            .child_block_end => {
                // Done parsing the borders block; return
                return;
            },
        }
    }
}

/// Skips an entire child block in KDL
fn skipChildBlock(_: *Config, parser: *kdl.Parser) !void {
    log.warn("Unexpected child block. Skipping it", .{});

    var depth: usize = 0;
    while (try parser.next()) |event| {
        switch (event) {
            // Nested child block
            .child_block_begin => depth += 1,
            .child_block_end => {
                if (depth == 0) {
                    return;
                } else {
                    depth -= 1;
                }
            },
            else => {
                // We don't care about any nodes in here
            },
        }
    }
}

/// Convert a KDL argument into a bool or null if the string is not a bool
/// "#true" and "true" => true
/// "#false" and "false" => false
/// else => null
fn boolFromKdlStr(_: Config, arg_str: []const u8) ?bool {
    if (mem.eql(u8, arg_str, "#true") or
        mem.eql(u8, arg_str, "true"))
    {
        return true;
    } else if (mem.eql(u8, arg_str, "#false") or
        mem.eql(u8, arg_str, "false"))
    {
        return false;
    }
    return null;
}

const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const Io = std.Io;

const kdl = @import("kdl");
const known_folders = @import("known_folders");
const KdlNode = kdl.Parser.Node;

const utils = @import("utils.zig");
const RiverColor = utils.RiverColor;

const log = std.log.scoped(.Config);
