// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

// Allocator used by the program. We use the c_allocator since we interact with C code
// via zig-wayland (and, in the future as of 2026-01-26, other libraries, too).
pub const allocator = std.heap.c_allocator;

pub const RiverColor = struct {
    red: u32,
    green: u32,
    blue: u32,
    alpha: u32,
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
    return parseRgbaHelper(bytes);
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
    return parseRgbaHelper(bytes);
}

fn parseRgbaHelper(bytes: [4]u8) RiverColor {
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

/// Report that the given WaylandGlobal wasn't advertised and exit the program
pub fn interfaceNotAdvertised(comptime WaylandGlobal: type) noreturn {
    log.err("{s} not advertised. Exiting", .{WaylandGlobal.interface.name});
    std.posix.exit(1);
}

/// Report that the given WaylandGlobal was advertised but the support version was too low and exit the program
pub fn versionNotSupported(comptime WaylandGlobal: type, have_version: u32, need_version: u32) noreturn {
    log.err("The compositor only advertised {s} version {d} but version {d} is required. Exiting", .{ WaylandGlobal.interface.name, have_version, need_version });
    std.posix.exit(1);
}

const std = @import("std");
const fmt = std.fmt;

const log = std.log.scoped(.utils);
