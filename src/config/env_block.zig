// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
// SPDX-FileCopyrightText: 2026 Arsen Berezin <is.void.is.none@gmail.com>
//
// SPDX-License-Identifier: GPL-3.0-only

const NodeName = enum {
    set,
    unset,
};

/// State accumulated while parsing a KDL node
/// Each node gets its own parse state, i.e. state is reset between nodes
const ParseState = struct {
    /// Enum version of the current node
    cur_node: ?NodeName = null,

    /// The hostname that this node should apply to
    host: ?[]const u8 = null,

    /// Arguments to the current node: [0] = key, [1] = value (for set)
    args: [2][]const u8 = .{ "", "" },
    /// The number of arguments parsed so far on this node
    arg_count: usize = 0,
};

pub fn load(
    config: *Config, 
    parser: *kdl.Parser, 
    environ: *Environ.Map, 
    hostname: ?[]const u8,
) !void {
    var state: ParseState = .{};

    var event = try parser.next();
    while (true) : (event = try parser.next()) {
        switch (event) {
            .node => |node| {
                try flushNode(config, environ, hostname, state);
                state = .{
                    .cur_node = std.meta.stringToEnum(NodeName, node.val) orelse {
                        return helpers.invalidNode(node.val);
                    },
                };
            },
            .arg => |arg| {
                if (state.arg_count < 2) {
                    state.args[state.arg_count] = arg.val;
                }
                state.arg_count += 1;
            },
            .prop => |prop| {
                if (mem.eql(u8, prop.key, "host")) {
                    state.host = prop.val;
                }
            },
            .child_block_begin => return helpers.unexpectedChildBlock(),
            .child_block_end => {
                try flushNode(config, environ, hostname, state);
                return;
            },
            .invalid => return error.KdlInvalidConfig,
            .eof => return error.UnclosedBlock,
        }
    }
}

fn flushNode(config: *Config, environ: *Environ.Map, hostname: ?[]const u8, state: ParseState) !void {
    _ = config;
    const name = state.cur_node orelse return;
    if (!helpers.hostMatches(state.host, hostname)) {
        log.debug("Skipping \"env.{s}\" (host mismatch)", .{@tagName(name)});
        return;
    }
    if (state.arg_count < 1) {
        return errMissingArg(name, "env variable name");
    }

    const key_str = utils.stripQuotes(state.args[0]);
    const interpolated_key = try interpolateEnv(utils.gpa, name, environ, key_str);
    errdefer utils.gpa.free(interpolated_key);

    if (interpolated_key.len == 0) {
        utils.gpa.free(interpolated_key);
        log.err("env.{s}: env variable name cannot be empty", .{@tagName(name)});
        return;
    }
    if (mem.findScalar(u8, interpolated_key, '=') != null) {
        utils.gpa.free(interpolated_key);
        log.err("env.{s}: env variable name cannot contain an '=' character", .{@tagName(name)});
        return;
    }

    switch (name) {
        .set => {
            if (state.arg_count < 2) {
                return errMissingArg(name, "env variable value");
            }

            const value_str = utils.stripQuotes(state.args[1]);
            const interpolated_value = try interpolateEnv(utils.gpa, name, environ, value_str);
            errdefer utils.gpa.free(interpolated_value);

            try environ.putMove(interpolated_key, interpolated_value);

            log.debug("env.set \"{s}\" = \"{s}\"", .{ interpolated_key, interpolated_value, });
        },
        .unset => {
            const was_removed = environ.swapRemove(interpolated_key);
            if (was_removed) {
                log.debug("env.unset: removed \"{s}\" env variable", .{interpolated_key});
            } else {
                log.debug("env.unset: env variable \"{s}\" is not set", .{interpolated_key});
            }
        },
    }
}

/// Parse the given string and interpolate all `${...}` captures.
fn interpolateEnv(
    allocator: mem.Allocator,
    node_name: NodeName, 
    environ: *Environ.Map, 
    str: []const u8,
) ![]u8 {
    var string_builder: std.ArrayList(u8) = try .initCapacity(allocator, str.len);
    errdefer string_builder.deinit(allocator);
    var i: usize = 0;
    while (i < str.len) {
        if (str[i] == '$') {
            i = try readOpenedInterpolation(
                allocator,
                node_name, 
                environ, 
                &string_builder, 
                str, 
                i,
            );
        } else {
            try string_builder.append(allocator, str[i]);
            i += 1;
        }
    }
    return try string_builder.toOwnedSlice(allocator);
}

/// Parse an `${...}` block or `$$` directly, or report an invalid combination.
fn readOpenedInterpolation(
    allocator: mem.Allocator,
    node_name: NodeName,
    environ: *const Environ.Map, 
    string_builder: *std.ArrayList(u8),
    str: []const u8, 
    offset: usize,
) !usize {
    var i = offset + 1; // skip `$`

    if (i == str.len) {
        log.err(
            "env.{s}: unterminated env interpolation at the end of the string", 
            .{@tagName(node_name)},
        );
        return offset;
    }
    if (str[i] == '$') {
        // Parse `$$` as regular `$`
        i += 1;
        try string_builder.append(allocator, '$');
        return i;
    }
    if (str[i] != '{') {
        // `$...` <- this is neither regular `$` (`$$`) nor interpolation `${...}`, 
        // so this is an error.
        // We shouldn't increment i, because str[i] will be added by interpolateEnv on the next iteration
        log.err(
            "env.{s}: invalid env interpolation (expected '{{', found '{c}')", 
            .{ @tagName(node_name), str[offset], },
        );
        // We should push the raw text without interpolation
        try string_builder.append(allocator, '$');
        return i;
    }

    i += 1; // skip `{`
    const name_start = i;
    var err_occured: bool = false;
    while (i < str.len) {
        switch (str[i]) {
            '=',
            ' ', '\n', '\r', '\t',
            0x08, // '\b'
            0x0b, // '\v'
            0x0c, // '\f'
            => {
                log.err(
                    "env.{s}: env variable name cannot contain an '{c}' character",
                    .{ @tagName(node_name), str[i], },
                );
                err_occured = true;
                i += 1;
                // str[name_start..i] includes bad character
                break;
            },
            '}' => {
                // End of interpolation `${...}`
                // str[name_start..i] does not include '}'
                break;
            },
            else => i += 1, // Allowed char
        }
    } else {
        err_occured = true;
        log.err(
            "env.{s}: unterminated env interpolation (missing closing '}}')", 
            .{@tagName(node_name)},
        );
        // [start, i): [name_start..i] is valid slice
    }

    if (err_occured) {
        // We should push the raw text `${...` without interpolation
        try string_builder.appendSlice(allocator, str[offset..i]);
    } else {
        const name = str[name_start..i];
        i += 1; // skip '}'
        if (environ.get(name)) |value| {
            try string_builder.appendSlice(allocator, value);
        }
    }

    return i;
}

fn errMissingArg(node_name: NodeName, comptime arg_name: []const u8) error{InvalidConfig} {
    log.err("env.{s}: missing " ++ arg_name, .{@tagName(node_name)});
    return error.InvalidConfig;
}

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;
const Environ = std.process.Environ;

const kdl = @import("kdl");

const utils = @import("../utils.zig");
const Config = @import("../Config.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.config_env);

test interpolateEnv {
    const dummy_name: NodeName = .set;

    var environ: Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    try environ.put("TEST", "(test_content)");
    try environ.put("empty123__", "");

    const raw = "${TEST} $$ ${empty123__} ${fhfhfhf1923ghd}";
    const expected = "(test_content) $  ";
    const interpolated = try interpolateEnv(testing.allocator, dummy_name, &environ, raw);
    defer testing.allocator.free(interpolated);

    try testing.expectEqualStrings(expected, interpolated);
}

