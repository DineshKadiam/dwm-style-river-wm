// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const NodeName = enum {
    width,
    color_focused,
    color_unfocused,
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

pub fn load(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
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
        log.debug("Skipping \"border.{s}\" (host mismatch)", .{@tagName(name)});
        return;
    }
    if (state.arg_count < 1) {
        return errMissingArg(name);
    }
    const val_str = utils.stripQuotes(state.arg);
    switch (name) {
        .width => {
            config.border_width = fmt.parseInt(u8, val_str, 10) catch {
                return errInvalidArg(name, val_str);
            };
            logDebugSettingNode(name, val_str);
        },
        .color_focused => {
            config.border_color_focused = utils.parseRgba(val_str) catch {
                return errInvalidArg(name, val_str);
            };
            logDebugSettingNode(name, val_str);
        },
        .color_unfocused => {
            config.border_color_unfocused = utils.parseRgba(val_str) catch {
                return errInvalidArg(name, val_str);
            };
            logDebugSettingNode(name, val_str);
        },
    }
}

inline fn logDebugSettingNode(node_name: NodeName, node_value: []const u8) void {
    log.debug("Setting border.{s} to {s}", .{ @tagName(node_name), node_value });
}

fn errInvalidArg(node_name: NodeName, node_value: []const u8) error{InvalidConfig} {
    log.err("Invalid \"border.{s}\" ({s})", .{ @tagName(node_name), node_value });
    return error.InvalidConfig;
}

fn errMissingArg(node_name: NodeName) error{InvalidConfig} {
    log.err("\"border.{s}\" missing argument", .{@tagName(node_name)});
    return error.InvalidConfig;
}

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const kdl = @import("kdl");

const utils = @import("../utils.zig");
const Config = @import("../Config.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.config_border);
