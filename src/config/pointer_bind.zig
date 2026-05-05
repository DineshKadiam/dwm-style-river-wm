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

pub fn load(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                const node_name = std.meta.stringToEnum(NodeName, node.name);
                if (node_name) |name| {
                    if (!helpers.hostMatches(node, parser, hostname)) {
                        log.debug("Skipping \"pointer_binds.{s}\" (host mismatch)", .{@tagName(name)});
                        continue;
                    }
                    // Parse modifiers (arg 0)
                    const mod_str = utils.stripQuotes(node.arg(parser, 0) orelse {
                        return errMissingArg(name, "modifier(s)");
                    });
                    const modifiers = try utils.parseModifiers(mod_str) orelse {
                        return errInvalidArg(name, mod_str);
                    };

                    // Parse button (arg 1)
                    const button_str = utils.stripQuotes(node.arg(parser, 1) orelse {
                        return errMissingArg(name, "button");
                    });
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
                } else {
                    return helpers.invalidNode(node.name);
                }
            },
            .child_block_begin => {
                try helpers.unexpectedChildBlock(parser);
            },
            .child_block_end => {
                return;
            },
        }
    }
}

fn errInvalidArg(node_name: NodeName, node_value: []const u8) error{InvalidConfig} {
    log.err("Invalid \"pointer_binds.{s}\" ({s})", .{ @tagName(node_name), node_value });
    return error.InvalidConfig;
}

fn errMissingArg(node_name: NodeName, comptime arg: []const u8) error{InvalidConfig} {
    log.err("\"pointer_binds.{s}\" missing " ++ arg ++ " argument", .{@tagName(node_name)});
    return error.InvalidConfig;
}

const std = @import("std");
const fmt = std.fmt;

const wayland = @import("wayland");
const river = wayland.client.river;
const kdl = @import("kdl");

const utils = @import("../utils.zig");
const Config = @import("../Config.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.config_pointer_bind);
