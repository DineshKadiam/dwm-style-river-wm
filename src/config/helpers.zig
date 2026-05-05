// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

/// Convert a KDL argument into a bool
///
/// if arg_str in ["#true", "true"], return true
/// if arg_str in ["#false", "false"], return false
/// else, return null
pub fn boolFromKdlStr(arg_str: []const u8) !bool {
    if (mem.eql(u8, arg_str, "#true") or
        mem.eql(u8, arg_str, "true"))
    {
        return true;
    } else if (mem.eql(u8, arg_str, "#false") or
        mem.eql(u8, arg_str, "false"))
    {
        return false;
    }
    return error.NotABool;
}

pub fn parseButton(s: []const u8) ?u32 {
    // Support both numeric and named buttons
    var lower_buf: [16]u8 = undefined;
    const len = @min(s.len, 16);
    const lower = std.ascii.lowerString(lower_buf[0..len], s[0..len]);

    if (mem.eql(u8, lower, "btn_left") or mem.eql(u8, lower, "button1")) {
        return 0x110; // BTN_LEFT = 272
    } else if (mem.eql(u8, lower, "btn_right") or mem.eql(u8, lower, "button3")) {
        return 0x111; // BTN_RIGHT = 273
    } else if (mem.eql(u8, lower, "btn_middle") or mem.eql(u8, lower, "button2")) {
        return 0x112; // BTN_MIDDLE = 274
    }

    // Try parsing as hex or decimal
    return fmt.parseInt(u32, s, 0) catch null;
}

/// Expand a tilde in a string to the user's $HOME directory
pub fn expandTilde(path: []const u8) ![:0]const u8 {
    if (path.len > 0 and path[0] == '~') {
        const home = posix.getenv("HOME") orelse return error.HomeNotSet;
        return mem.concatWithSentinel(utils.gpa, u8, &.{ home, path[1..] }, 0);
    }
    return utils.gpa.dupeZ(u8, path);
}

/// Check whether this machine's hostname matches the hostname property
/// Always returns true if the "host" property is missing (no host = config applies to
/// all hosts). Returns false if the hostname argument is null or does not match.
pub fn hostMatches(node: kdl.Parser.Node, parser: *kdl.Parser, hostname: ?[]const u8) bool {
    const host_property = utils.stripQuotes(node.prop(parser, "host") orelse return true);
    const hostname_str = hostname orelse return false;
    return mem.eql(u8, host_property, hostname_str);
}

/// Returns error.InvalidConfig for an unexpected child block
pub fn unexpectedChildBlock(parser: *kdl.Parser) error{ InvalidConfig, OutOfMemory, KdlParseError }!void {
    _ = parser;
    log.err("Unexpected child block", .{});
    return error.InvalidConfig;
}

pub inline fn invalidNode(node_name: []const u8) error{InvalidConfig} {
    log.err("Invalid KDL node {s}", .{node_name});
    return error.InvalidConfig;
}

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const posix = std.posix;

const kdl = @import("kdl");

const utils = @import("../utils.zig");

const log = std.log.scoped(.config_helpers);

const testing = std.testing;

test "boolFromKdlStr" {
    // True valid
    try testing.expectEqual(true, try boolFromKdlStr("#true"));
    try testing.expectEqual(true, try boolFromKdlStr("true"));
    // False valid
    try testing.expectEqual(false, try boolFromKdlStr("#false"));
    try testing.expectEqual(false, try boolFromKdlStr("false"));
    // Invalid
    try testing.expectError(error.NotABool, boolFromKdlStr("yes"));
    try testing.expectError(error.NotABool, boolFromKdlStr("1"));
    try testing.expectError(error.NotABool, boolFromKdlStr(""));
    try testing.expectError(error.NotABool, boolFromKdlStr("TRUE"));
}

test "parseButton named buttons" {
    try testing.expectEqual(@as(?u32, 0x110), parseButton("btn_left"));
    try testing.expectEqual(@as(?u32, 0x110), parseButton("button1"));
    try testing.expectEqual(@as(?u32, 0x111), parseButton("btn_right"));
    try testing.expectEqual(@as(?u32, 0x111), parseButton("button3"));
    try testing.expectEqual(@as(?u32, 0x112), parseButton("btn_middle"));
    try testing.expectEqual(@as(?u32, 0x112), parseButton("button2"));
}

test "parseButton case insensitive" {
    try testing.expectEqual(@as(?u32, 0x110), parseButton("BTN_LEFT"));
    try testing.expectEqual(@as(?u32, 0x110), parseButton("Btn_Left"));
    try testing.expectEqual(@as(?u32, 0x110), parseButton("BUTTON1"));
}

test "parseButton numeric decimal" {
    try testing.expectEqual(@as(?u32, 272), parseButton("272"));
    try testing.expectEqual(@as(?u32, 0), parseButton("0"));
}

test "parseButton numeric hex" {
    try testing.expectEqual(@as(?u32, 0x110), parseButton("0x110"));
}

test "parseButton invalid" {
    try testing.expectEqual(@as(?u32, null), parseButton("bogus"));
    try testing.expectEqual(@as(?u32, null), parseButton(""));
}

test "expandTilde with tilde" {
    const result = try expandTilde("~/foo/bar");
    defer utils.gpa.free(result);
    const home = std.posix.getenv("HOME") orelse return;
    try testing.expect(mem.startsWith(u8, result, home));
    try testing.expect(mem.endsWith(u8, result, "/foo/bar"));
}

test "expandTilde without tilde" {
    const result = try expandTilde("/absolute/path");
    defer utils.gpa.free(result);
    try testing.expectEqualStrings("/absolute/path", result);
}
