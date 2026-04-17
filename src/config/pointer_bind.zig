// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

pub const PointerBind = struct {
    modifiers: river.SeatV1.Modifiers,
    button: u32, // Linux button code (BTN_LEFT=0x110, BTN_RIGHT=0x111, BTN_MIDDLE=0x112)
    action: PointerAction,
};

pub const PointerAction = enum {
    move_window,
    resize_window,
};

const NodeName = enum {
    move_window,
    resize_window,
};

/// State accumulated while parsing a KDL node
/// Each node gets its own parse state, i.e. state is reset between nodes
const ParseState = struct {
    /// Enum version of the current node
    cur_node: ?NodeName = null,

    /// The hostname that this node should apply to
    host: ?[]const u8 = null,

    /// Arguments to the current node: [0] = modifiers, [1] = button
    args: [2][]const u8 = .{ "", "" },
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
        log.debug("Skipping \"pointer_binds.{s}\" (host mismatch)", .{@tagName(name)});
        return;
    }
    if (state.arg_count < 1) {
        return errMissingArg(name, "modifier(s)");
    }
    if (state.arg_count < 2) {
        return errMissingArg(name, "button");
    }
    const mod_str = utils.stripQuotes(state.args[0]);
    const button_str = utils.stripQuotes(state.args[1]);
    const modifiers = try utils.parseModifiers(mod_str) orelse {
        return errInvalidArg(name, mod_str);
    };
    const button = helpers.parseButton(button_str) orelse {
        return errInvalidArg(name, button_str);
    };
    const action: PointerAction = switch (name) {
        .move_window => .move_window,
        .resize_window => .resize_window,
    };
    try config.pointer_binds.append(utils.gpa, .{
        .modifiers = modifiers,
        .button = button,
        .action = action,
    });
    log.debug("pointer_binds.{s}: {s} {s}", .{ @tagName(name), mod_str, button_str });
}

fn errInvalidArg(node_name: NodeName, node_value: []const u8) error{InvalidConfig} {
    log.err("Invalid \"pointer_binds.{s}\" ({s})", .{ @tagName(node_name), node_value });
    return error.InvalidConfig;
}

fn errMissingArg(node_name: NodeName, comptime arg_name: []const u8) error{InvalidConfig} {
    log.err("\"pointer_binds.{s}\" missing " ++ arg_name ++ " argument", .{@tagName(node_name)});
    return error.InvalidConfig;
}

const std = @import("std");
const mem = std.mem;

const wayland = @import("wayland");
const river = wayland.client.river;
const kdl = @import("kdl");

const utils = @import("../utils.zig");
const Config = @import("../Config.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.config_pointer_bind);
