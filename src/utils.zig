// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

// Allocator used by the program. We use the c_allocator since we interact with C code via our dependencies.
pub const gpa = std.heap.c_allocator;

pub const RiverColor = struct {
    red: u32,
    green: u32,
    blue: u32,
    alpha: u32,
};

pub const Rect = struct {
    width: u31 = 0,
    height: u31 = 0,
    x: i32 = 0,
    y: i32 = 0,
};

/// Parse a color in the format 0xRRGGBB or 0xRRGGBBAA and convert it to
/// 32-bit color values (used by Window.set_borders in rwm).
pub fn parseRgba(s: []const u8) !RiverColor {
    if (s.len != 8 and s.len != 10) return error.InvalidRgba;
    if (s[0] != '0' or s[1] != 'x') return error.InvalidRgba;

    // If the color is 0xRRGGBB, add FF for the alpha channel
    var color = try fmt.parseUnsigned(u32, s[2..], 16);
    if (s.len == 8) {
        color <<= 8;
        color |= 0xff;
    }

    const bytes: [4]u8 = @as([4]u8, @bitCast(color));
    return bytesToRiverColor(bytes);
}

/// Parse a color in the format 0xRRGGBB or 0xRRGGBBAA and convert it to
/// 32-bit color values (used by Window.set_borders in rwm) at comptime.
pub fn parseRgbaComptime(comptime s: []const u8) RiverColor {
    if (s.len != 8 and s.len != 10) @compileError("Invalid RGBA");
    if (s[0] != '0' or s[1] != 'x') @compileError("Invalid RGBA");

    // If the color is 0xRRGGBB, add FF for the alpha channel
    comptime var color = try fmt.parseUnsigned(u32, s[2..], 16);
    if (s.len == 8) {
        color <<= 8;
        color |= 0xff;
    }

    const bytes = @as([4]u8, @bitCast(color));
    return bytesToRiverColor(bytes);
}

/// Parse a color in the format 0xRRGGBB or 0xRRGGBBAA and convert it to
/// 16-bit color values.
pub fn parseRgbaPixman(s: []const u8) !pixman.Color {
    if (s.len != 8 and s.len != 10) return error.InvalidRgba;
    if (s[0] != '0' or s[1] != 'x') return error.InvalidRgba;

    var color = try fmt.parseUnsigned(u32, s[2..], 16);
    if (s.len == 8) {
        color <<= 8;
        color |= 0xff;
    }

    return bytesToPixmanColor(@bitCast(color));
}

/// Parse a color in the format 0xRRGGBB or 0xRRGGBBAA and convert it to
/// 16-bit color values at comptime.
pub fn parseRgbaPixmanComptime(comptime s: []const u8) pixman.Color {
    @setEvalBranchQuota(2000);
    if (s.len != 8 and s.len != 10) @compileError("Invalid RGBA");
    if (s[0] != '0' or s[1] != 'x') @compileError("Invalid RGBA");

    comptime var color = try fmt.parseUnsigned(u32, s[2..], 16);
    if (s.len == 8) {
        color <<= 8;
        color |= 0xff;
    }

    return bytesToPixmanColor(@bitCast(color));
}

fn bytesToPixmanColor(bytes: [4]u8) pixman.Color {
    return .{
        .red = @as(u16, bytes[3]) * 0x101,
        .green = @as(u16, bytes[2]) * 0x101,
        .blue = @as(u16, bytes[1]) * 0x101,
        .alpha = @as(u16, bytes[0]) * 0x101,
    };
}

fn bytesToRiverColor(bytes: [4]u8) RiverColor {
    const r: u32 = bytes[3];
    const g: u32 = bytes[2];
    const b: u32 = bytes[1];
    const a: u32 = bytes[0];

    // To convert from an 8-bit color to 32-bit color, we need to do
    //     color * 2^32 / 2^8
    // which is equivalent to
    //     color * 2^24
    // or, in other words,
    //     color << 24
    return .{
        .red = r << 24,
        .green = g << 24,
        .blue = b << 24,
        .alpha = a << 24,
    };
}

/// Parse a modifier string like "mod4+shift+ctrl" into river.SeatV1.Modifiers.
/// Modifier names are case-insensitive. Returns null if any modifier is unrecognized.
pub fn parseModifiers(s: []const u8) !?river.SeatV1.Modifiers {
    var modifiers: river.SeatV1.Modifiers = .{};

    var it = mem.splitScalar(u8, s, '+');
    while (it.next()) |part| {
        // Modifier names are 3 (alt) to 5 (shift/super) characters long,
        // other length can't be correctly formatted.
        if (part.len < 3 or part.len > 5) return null;

        // Case-insensitive comparison by lowercasing
        var lower_buf: [5]u8 = undefined;
        const lower = std.ascii.lowerString(lower_buf[0..part.len], part);

        if (mem.eql(u8, lower, "none")) {
            // No modifier bits to set
        } else if (mem.eql(u8, lower, "mod4") or mem.eql(u8, lower, "super")) {
            modifiers.mod4 = true;
        } else if (mem.eql(u8, lower, "shift")) {
            modifiers.shift = true;
        } else if (mem.eql(u8, lower, "ctrl")) {
            modifiers.ctrl = true;
        } else if (mem.eql(u8, lower, "mod1") or mem.eql(u8, lower, "alt")) {
            modifiers.mod1 = true;
        } else if (mem.eql(u8, lower, "mod3")) {
            modifiers.mod3 = true;
        } else if (mem.eql(u8, lower, "mod5")) {
            modifiers.mod5 = true;
        } else {
            return null;
        }
    }

    return modifiers;
}

pub fn tokenizeToOwnedSlices(input: []const u8, delimiter: u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, input, delimiter);
    while (it.next()) |part| {
        const duped = try gpa.dupe(u8, part);
        try list.append(utils.gpa, duped);
    }
    return list.toOwnedSlice(utils.gpa);
}

pub fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

/// Report that the given WaylandGlobal wasn't advertised and exit the program
pub fn interfaceNotAdvertised(comptime WaylandGlobal: type) noreturn {
    fatal("{s} not advertised. Exiting", .{WaylandGlobal.interface.name});
}

/// Report that the given WaylandGlobal was advertised but the support version was too low and exit the program
pub fn versionNotSupported(comptime WaylandGlobal: type, have_version: u32, need_version: u32) noreturn {
    fatal("The compositor only advertised {s} version {d} but version {d} is required. Exiting", .{ WaylandGlobal.interface.name, have_version, need_version });
}

const std = @import("std");
const fatal = std.process.fatal;
const fmt = std.fmt;
const mem = std.mem;

const wayland = @import("wayland");
const river = wayland.client.river;
const pixman = @import("pixman");

const log = std.log.scoped(.utils);

const testing = std.testing;

test "parseRgba 0xRRGGBB" {
    const color = try parseRgba("0x89b4fa");
    try testing.expectEqual(@as(u32, 0x89 << 24), color.red);
    try testing.expectEqual(@as(u32, 0xb4 << 24), color.green);
    try testing.expectEqual(@as(u32, 0xfa << 24), color.blue);
    try testing.expectEqual(@as(u32, 0xff << 24), color.alpha);
}

test "parseRgba 0xRRGGBBAA" {
    const color = try parseRgba("0x1e1e2eff");
    try testing.expectEqual(@as(u32, 0x1e << 24), color.red);
    try testing.expectEqual(@as(u32, 0x1e << 24), color.green);
    try testing.expectEqual(@as(u32, 0x2e << 24), color.blue);
    try testing.expectEqual(@as(u32, 0xff << 24), color.alpha);
}

test "parseRgba invalid length" {
    try testing.expectError(error.InvalidRgba, parseRgba("0x123"));
    try testing.expectError(error.InvalidRgba, parseRgba("0x12345678a"));
    try testing.expectError(error.InvalidRgba, parseRgba(""));
}

test "parseRgba missing 0x prefix" {
    try testing.expectError(error.InvalidRgba, parseRgba("xx123456"));
    try testing.expectError(error.InvalidRgba, parseRgba("12345678"));
}

test "parseRgba invalid hex characters" {
    try testing.expectError(error.InvalidCharacter, parseRgba("0xGGGGGG"));
}

test "parseRgbaComptime" {
    const color = parseRgbaComptime("0x89b4fa");
    try testing.expectEqual(@as(u32, 0x89 << 24), color.red);
    try testing.expectEqual(@as(u32, 0xb4 << 24), color.green);
    try testing.expectEqual(@as(u32, 0xfa << 24), color.blue);
    try testing.expectEqual(@as(u32, 0xff << 24), color.alpha);
}

test "parseRgbaComptime with alpha" {
    const color = parseRgbaComptime("0x1e1e2eff");
    try testing.expectEqual(@as(u32, 0x1e << 24), color.red);
    try testing.expectEqual(@as(u32, 0x1e << 24), color.green);
    try testing.expectEqual(@as(u32, 0x2e << 24), color.blue);
    try testing.expectEqual(@as(u32, 0xff << 24), color.alpha);
}

test "parseRgbaPixman 0xRRGGBB" {
    const color = try parseRgbaPixman("0x89b4fa");
    try testing.expectEqual(@as(u16, 0x8989), color.red);
    try testing.expectEqual(@as(u16, 0xb4b4), color.green);
    try testing.expectEqual(@as(u16, 0xfafa), color.blue);
    try testing.expectEqual(@as(u16, 0xffff), color.alpha);
}

test "parseRgbaPixman 0xRRGGBBAA" {
    const color = try parseRgbaPixman("0x1e1e2e80");
    try testing.expectEqual(@as(u16, 0x1e1e), color.red);
    try testing.expectEqual(@as(u16, 0x1e1e), color.green);
    try testing.expectEqual(@as(u16, 0x2e2e), color.blue);
    try testing.expectEqual(@as(u16, 0x8080), color.alpha);
}

test "parseRgbaPixman invalid" {
    try testing.expectError(error.InvalidRgba, parseRgbaPixman("0x123"));
    try testing.expectError(error.InvalidRgba, parseRgbaPixman("xx123456"));
    try testing.expectError(error.InvalidCharacter, parseRgbaPixman("0xGGGGGG"));
}

test "parseRgbaPixmanComptime" {
    const color = parseRgbaPixmanComptime("0x89b4fa");
    try testing.expectEqual(@as(u16, 0x8989), color.red);
    try testing.expectEqual(@as(u16, 0xb4b4), color.green);
    try testing.expectEqual(@as(u16, 0xfafa), color.blue);
    try testing.expectEqual(@as(u16, 0xffff), color.alpha);
}

test "parseRgbaPixmanComptime with alpha" {
    const color = parseRgbaPixmanComptime("0x1e1e2e80");
    try testing.expectEqual(@as(u16, 0x1e1e), color.red);
    try testing.expectEqual(@as(u16, 0x1e1e), color.green);
    try testing.expectEqual(@as(u16, 0x2e2e), color.blue);
    try testing.expectEqual(@as(u16, 0x8080), color.alpha);
}

test "stripQuotes removes surrounding quotes" {
    try testing.expectEqualStrings("hello", stripQuotes("\"hello\""));
}

test "stripQuotes no quotes" {
    try testing.expectEqualStrings("hello", stripQuotes("hello"));
}

test "stripQuotes empty string" {
    try testing.expectEqualStrings("", stripQuotes(""));
}

test "stripQuotes single char" {
    try testing.expectEqualStrings("\"", stripQuotes("\""));
}

test "stripQuotes only quotes" {
    try testing.expectEqualStrings("", stripQuotes("\"\""));
}

test "stripQuotes mismatched quotes" {
    try testing.expectEqualStrings("\"hello", stripQuotes("\"hello"));
    try testing.expectEqualStrings("hello\"", stripQuotes("hello\""));
}

test "parseModifiers single modifier" {
    const mods = (try parseModifiers("shift")).?;
    try testing.expect(mods.shift);
    try testing.expect(!mods.mod4);
    try testing.expect(!mods.ctrl);
    try testing.expect(!mods.mod1);
}

test "parseModifiers combined" {
    const mods = (try parseModifiers("mod4+shift+ctrl")).?;
    try testing.expect(mods.mod4);
    try testing.expect(mods.shift);
    try testing.expect(mods.ctrl);
    try testing.expect(!mods.mod1);
}

test "parseModifiers super alias" {
    const mods = (try parseModifiers("super")).?;
    try testing.expect(mods.mod4);
}

test "parseModifiers alt alias" {
    const mods = (try parseModifiers("alt")).?;
    try testing.expect(mods.mod1);
}

test "parseModifiers none" {
    const mods = (try parseModifiers("none")).?;
    try testing.expect(!mods.shift);
    try testing.expect(!mods.mod4);
    try testing.expect(!mods.ctrl);
    try testing.expect(!mods.mod1);
}

test "parseModifiers case insensitive" {
    const mods = (try parseModifiers("SHIFT")).?;
    try testing.expect(mods.shift);

    const mods2 = (try parseModifiers("Mod4")).?;
    try testing.expect(mods2.mod4);
}

test "parseModifiers unrecognized" {
    try testing.expectEqual(@as(?river.SeatV1.Modifiers, null), try parseModifiers("bogus"));
}

test "parseModifiers invalid length" {
    try testing.expectEqual(@as(?river.SeatV1.Modifiers, null), try parseModifiers("ab"));
    try testing.expectEqual(@as(?river.SeatV1.Modifiers, null), try parseModifiers("toolong"));
}

test "parseModifiers mod3 and mod5" {
    const mods = (try parseModifiers("mod3+mod5")).?;
    try testing.expect(mods.mod3);
    try testing.expect(mods.mod5);
}
