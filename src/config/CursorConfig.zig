// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const CursorConfig = @This();

/// Name of the XCursor theme to use, e.g. "Adwaita" or "Bibata-Modern-Classic"
theme: [:0]const u8,
/// Cursor size in pixels
size: u32,

pub fn parse(node: kdl.Parser.Node, parser: *kdl.Parser) !CursorConfig {
    if (node.argcount() < 1) {
        log.err("\"cursor_theme\" missing theme name argument", .{});
        return error.InvalidConfig;
    }
    const theme_str = utils.stripQuotes(node.arg(parser, 0).?);
    const theme = try utils.gpa.dupeZ(u8, theme_str);
    errdefer utils.gpa.free(theme);

    const size: u32 = if (node.argcount() >= 2) blk: {
        const size_str = utils.stripQuotes(node.arg(parser, 1).?);
        break :blk fmt.parseInt(u32, size_str, 10) catch {
            log.err("Invalid \"cursor_theme\" size ({s})", .{size_str});
            return error.InvalidConfig;
        };
    } else 24; // 24 is the standard default size

    log.debug("Setting cursor theme to \"{s}\", size {d}", .{ theme_str, size });
    return .{ .theme = theme, .size = size };
}

pub fn deinit(config: CursorConfig) void {
    utils.gpa.free(config.theme);
}

const std = @import("std");
const fmt = std.fmt;

const kdl = @import("kdl");

const utils = @import("../utils.zig");

const log = std.log.scoped(.CursorConfig);
