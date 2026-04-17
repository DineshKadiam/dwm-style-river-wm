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

/// State accumulated while parsing a KDL node
/// Each node gets its own parse state, i.e. state is reset between nodes
const ParseState = struct {
    /// Enum version of the current node
    cur_node: ?NodeName = null,

    /// The hostname that this node should apply to
    host: ?[]const u8 = null,

    /// Argument to the current node
    arg: []const u8 = "",
    /// The number of arguments parsed so far on this node
    arg_count: usize = 0,
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

    var state: ParseState = .{};

    var event = try parser.next();
    while (true) : (event = try parser.next()) {
        switch (event) {
            .node => |node| {
                try flushNode(config, hostname, state);
                state = .{
                    .cur_node = std.meta.stringToEnum(NodeName, node.val) orelse {
                        return helpers.invalidNode(node.val);
                    },
                };
            },
            .arg => |arg| {
                state.arg = arg.val;
                state.arg_count += 1;
            },
            .prop => |prop| {
                if (mem.eql(u8, prop.key, "host")) {
                    state.host = prop.val;
                }
            },
            .child_block_begin => return helpers.unexpectedChildBlock(),
            .child_block_end => {
                try flushNode(config, hostname, state);
                return;
            },
            .invalid => return error.KdlInvalidConfig,
            .eof => return error.UnclosedBlock,
        }
    }
}

fn flushNode(config: *Config, hostname: ?[]const u8, state: ParseState) !void {
    const name = state.cur_node orelse return;
    if (!helpers.hostMatches(state.host, hostname)) {
        logDebugHostMismatch(name);
        return;
    }
    if (state.arg_count < 1) {
        return errMissingArg(name);
    }
    const val_str = utils.stripQuotes(state.arg);
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

fn errMissingArg(node_name: NodeName) error{InvalidConfig} {
    log.err("\"tag_overlay.{s}\" missing argument", .{@tagName(node_name)});
    return error.InvalidConfig;
}

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const kdl = @import("kdl");
const pixman = @import("pixman");

const utils = @import("../utils.zig");
const Config = @import("../Config.zig");
const TagOverlay = @import("../TagOverlay.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.TagOverlayConfig);
