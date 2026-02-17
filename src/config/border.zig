// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const NodeName = enum {
    width,
    color_focused,
    color_unfocused,
};

pub fn load(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                // If it's a node, we check if it's a valid NodeName
                const node_name = std.meta.stringToEnum(NodeName, node.name);
                if (node_name) |name| {
                    if (!helpers.hostMatches(node, parser, hostname)) {
                        log.debug("Skipping \"border.{s}\" (host mismatch)", .{@tagName(name)});
                        continue;
                    }
                    switch (name) {
                        .width => {
                            const width_str = utils.stripQuotes(node.arg(parser, 0) orelse "");
                            config.border_width = fmt.parseInt(u8, width_str, 10) catch {
                                logWarnInvalidNodeArg(name, width_str);
                                continue;
                            };
                            logDebugSettingNode(name, width_str);
                        },
                        .color_focused => {
                            const color_str = utils.stripQuotes(node.arg(parser, 0) orelse "");
                            config.border_color_focused = utils.parseRgba(color_str) catch {
                                logWarnInvalidNodeArg(name, color_str);
                                continue;
                            };
                            logDebugSettingNode(name, color_str);
                        },
                        .color_unfocused => {
                            const color_str = utils.stripQuotes(node.arg(parser, 0) orelse "");
                            config.border_color_unfocused = utils.parseRgba(color_str) catch {
                                logWarnInvalidNodeArg(name, color_str);
                                continue;
                            };
                            logDebugSettingNode(name, color_str);
                        },
                    }
                } else {
                    helpers.logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => {
                // borders should never have a nested child block
                try helpers.skipChildBlock(parser);
            },
            .child_block_end => {
                // Done parsing the borders block; return
                return;
            },
        }
    }
}

inline fn logDebugSettingNode(node_name: NodeName, node_value: []const u8) void {
    log.debug("Setting border.{s} to {s}", .{ @tagName(node_name), node_value });
}

inline fn logWarnInvalidNodeArg(node_name: NodeName, node_value: []const u8) void {
    log.warn("Invalid \"border.{s}\" ({s}). Ignoring", .{ @tagName(node_name), node_value });
}

const std = @import("std");
const fmt = std.fmt;

const kdl = @import("kdl");

const utils = @import("../utils.zig");
const Config = @import("../Config.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.config_border);
