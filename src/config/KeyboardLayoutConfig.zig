// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const KeyboardLayoutConfig = @This();

const NodeName = enum {
    rules,
    model,
    layout,
    variant,
    options,
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

rules: ?[]const u8 = null,
model: ?[]const u8 = null,
layout: ?[]const u8 = null,
variant: ?[]const u8 = null,
options: ?[]const u8 = null,

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
        log.debug("Skipping \"keyboard_layout.{s}\" (host mismatch)", .{@tagName(name)});
        return;
    }
    if (state.arg_count < 1) {
        return errMissingArg(name);
    }
    const value = utils.stripQuotes(state.arg);
    const duped = try utils.gpa.dupe(u8, value);
    const target = switch (name) {
        .rules => &config.keyboard_layout.rules,
        .model => &config.keyboard_layout.model,
        .layout => &config.keyboard_layout.layout,
        .variant => &config.keyboard_layout.variant,
        .options => &config.keyboard_layout.options,
    };
    if (target.*) |old| {
        utils.gpa.free(old);
    }
    target.* = duped;
    logDebugSettingNode(name, value);
}

inline fn logDebugSettingNode(node_name: NodeName, node_value: []const u8) void {
    log.debug("Setting keyboard_layout.{s} to {s}", .{ @tagName(node_name), node_value });
}

fn errMissingArg(node_name: NodeName) error{InvalidConfig} {
    log.err("\"keyboard_layout.{s}\" missing argument", .{@tagName(node_name)});
    return error.InvalidConfig;
}

const std = @import("std");
const mem = std.mem;

const kdl = @import("kdl");

const utils = @import("../utils.zig");
const Config = @import("../Config.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.config_keyboard_layout);
