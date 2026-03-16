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

rules: ?[]const u8 = null,
model: ?[]const u8 = null,
layout: ?[]const u8 = null,
variant: ?[]const u8 = null,
options: ?[]const u8 = null,

pub fn load(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                const node_name = std.meta.stringToEnum(NodeName, node.name);
                if (node_name) |name| {
                    if (!helpers.hostMatches(node, parser, hostname)) {
                        log.debug("Skipping \"keyboard_layout.{s}\" (host mismatch)", .{@tagName(name)});
                        continue;
                    }
                    const value = utils.stripQuotes(node.arg(parser, 0) orelse {
                        logWarnMissingNodeArg(name);
                        continue;
                    });
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
                } else {
                    helpers.logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => try helpers.skipChildBlock(parser),
            .child_block_end => return,
        }
    }
}

inline fn logDebugSettingNode(node_name: NodeName, node_value: []const u8) void {
    log.debug("Setting keyboard_layout.{s} to {s}", .{ @tagName(node_name), node_value });
}

inline fn logWarnMissingNodeArg(node_name: NodeName) void {
    log.warn("\"keyboard_layout.{s}\" missing argument. Ignoring", .{@tagName(node_name)});
}

const std = @import("std");

const kdl = @import("kdl");

const utils = @import("../utils.zig");
const Config = @import("../Config.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.config_keyboard_layout);
