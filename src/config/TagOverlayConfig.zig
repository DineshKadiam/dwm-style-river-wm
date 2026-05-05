// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const TagOverlayConfig = @This();

const NodeName = enum {
    border_width,
    tag_amount,
    tags_per_row,
    square_size,
    square_inner_padding,
    square_padding,
    square_border_width,
    background_color,
    border_color,
    square_active_background_color,
    square_active_border_color,
    square_active_occupied_color,
    square_inactive_background_color,
    square_inactive_border_color,
    square_inactive_occupied_color,
    timeout,
};

border_width: u8 = 2,
tag_amount: u8 = 9,
tags_per_row: u8 = 32,
square_size: u8 = 40,
square_inner_padding: u8 = 10,
square_padding: u8 = 15,
square_border_width: u8 = 1,
background_color: pixman.Color = utils.parseRgbaPixmanComptime("0x1e1e2e"),
border_color: pixman.Color = utils.parseRgbaPixmanComptime("0x6c7086"),
square_active_background_color: pixman.Color = utils.parseRgbaPixmanComptime("0x89b4fa"),
square_active_border_color: pixman.Color = utils.parseRgbaPixmanComptime("0x6c7086"),
square_active_occupied_color: pixman.Color = utils.parseRgbaPixmanComptime("0xcdd6f4"),
square_inactive_background_color: pixman.Color = utils.parseRgbaPixmanComptime("0x585b70"),
square_inactive_border_color: pixman.Color = utils.parseRgbaPixmanComptime("0x6c7086"),
square_inactive_occupied_color: pixman.Color = utils.parseRgbaPixmanComptime("0xcdd6f4"),
timeout: u32 = 500,

pub fn toTagOverlayOptions(config: TagOverlayConfig) TagOverlay.Options {
    return .{
        .border_width = config.border_width,
        .tag_amount = @intCast(std.math.clamp(@as(u32, config.tag_amount), 1, 32)),
        .tags_per_row = @intCast(std.math.clamp(@as(u32, config.tags_per_row), 1, 32)),
        .square_size = config.square_size,
        .square_inner_padding = config.square_inner_padding,
        .square_padding = config.square_padding,
        .square_border_width = config.square_border_width,
        .background_color = config.background_color,
        .border_color = config.border_color,
        .square_active_background_color = config.square_active_background_color,
        .square_active_border_color = config.square_active_border_color,
        .square_active_occupied_color = config.square_active_occupied_color,
        .square_inactive_background_color = config.square_inactive_background_color,
        .square_inactive_border_color = config.square_inactive_border_color,
        .square_inactive_occupied_color = config.square_inactive_occupied_color,
        .timeout = config.timeout,
    };
}

pub fn load(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    config.tag_overlay_config = .{}; // Presence of block = enabled; initialize with defaults

    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                const node_name = std.meta.stringToEnum(NodeName, node.name);
                if (node_name) |name| {
                    if (!helpers.hostMatches(node, parser, hostname)) {
                        logDebugHostMismatch(name);
                        continue;
                    }
                    const val_str = utils.stripQuotes(node.arg(parser, 0) orelse "");
                    switch (name) {
                        // These are all u8s, so we can inline the branch
                        inline .border_width,
                        .tag_amount,
                        .tags_per_row,
                        .square_size,
                        .square_inner_padding,
                        .square_padding,
                        .square_border_width,
                        => |tag| {
                            const val = fmt.parseInt(u8, val_str, 10) catch {
                                return errInvalidArg(name, val_str);
                            };
                            @field(config.tag_overlay_config.?, @tagName(tag)) = val;
                            logDebugSettingNode(name, val_str);
                        },
                        .timeout => {
                            config.tag_overlay_config.?.timeout = fmt.parseInt(u32, val_str, 10) catch {
                                return errInvalidArg(name, val_str);
                            };
                            logDebugSettingNode(name, val_str);
                        },
                        inline .background_color,
                        .border_color,
                        .square_active_background_color,
                        .square_active_border_color,
                        .square_active_occupied_color,
                        .square_inactive_background_color,
                        .square_inactive_border_color,
                        .square_inactive_occupied_color,
                        => |tag| {
                            @field(config.tag_overlay_config.?, @tagName(tag)) = utils.parseRgbaPixman(val_str) catch {
                                return errInvalidArg(name, val_str);
                            };
                            logDebugSettingNode(name, val_str);
                        },
                    }
                } else {
                    return helpers.invalidNode(node.name);
                }
            },
            .child_block_begin => try helpers.unexpectedChildBlock(parser),
            .child_block_end => return,
        }
    }
}

inline fn logDebugSettingNode(node_name: anytype, node_value: []const u8) void {
    const node_name_type = @TypeOf(node_name);
    switch (node_name_type) {
        NodeName => log.debug("Setting tag_overlay.{s} to {s}", .{ @tagName(node_name), node_value }),
        else => @compileError("This function does not (yet) support type \"" ++ @typeName(@TypeOf(node_name)) ++ "\""),
    }
}

inline fn logDebugHostMismatch(node_name: anytype) void {
    const node_name_type = @TypeOf(node_name);
    switch (node_name_type) {
        NodeName => log.debug("Skipping \"tag_overlay.{s}\" (host mismatch)", .{@tagName(node_name)}),
        else => @compileError("This function does not (yet) support type \"" ++ @typeName(node_name_type) ++ "\""),
    }
}

fn errInvalidArg(node_name: NodeName, node_value: []const u8) error{InvalidConfig} {
    log.err("Invalid \"tag_overlay.{s}\" ({s})", .{ @tagName(node_name), node_value });
    return error.InvalidConfig;
}

const std = @import("std");
const fmt = std.fmt;

const kdl = @import("kdl");
const pixman = @import("pixman");

const utils = @import("../utils.zig");
const Config = @import("../Config.zig");
const TagOverlay = @import("../TagOverlay.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.TagOverlayConfig);
