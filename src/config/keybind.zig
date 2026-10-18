// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

// We can just directly use the tag type from Command as our node name
const NodeName = @typeInfo(XkbBindings.Command).@"union".tag_type.?;

pub const Keybind = struct {
    modifiers: river.SeatV1.Modifiers,
    command: XkbBindings.Command,
    keysym: ?xkbcommon.Keysym,
    allow_locked: bool,
};

pub const Key = struct {
    modifiers: river.SeatV1.Modifiers,
    keysym: xkbcommon.Keysym,
};

pub const Value = struct {
    command: XkbBindings.Command,
    allow_locked: bool,
};

pub const Map = std.AutoArrayHashMapUnmanaged(Key, Value);

/// State accumulated while parsing a KDL node
/// Each node gets its own parse state, i.e. state is reset between nodes
const ParseState = struct {
    /// Raw node name string
    /// Not parsed to NodeName because tag_bind is a special case not in NodeName
    node_name: ?[]const u8 = null,

    /// The hostname that this node should apply to
    host: ?[]const u8 = null,
    /// Should this keybind be allowed to execute while the session is locked
    allow_locked: bool = false,

    /// Arguments: [0] = modifiers, [1] = keysym/command, [2] = extra arg (spawn cmd, diff, tags, etc.)
    args: [3][]const u8 = .{ "", "", "" },
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
                state = .{ .node_name = node.val };
            },
            .arg => |arg| {
                if (state.arg_count < 3) {
                    state.args[state.arg_count] = arg.val;
                }
                state.arg_count += 1;
            },
            .prop => |prop| {
                if (mem.eql(u8, prop.key, "host")) {
                    state.host = prop.val;
                } else if (mem.eql(u8, prop.key, "allow_locked")) {
                    if (helpers.boolFromKdlStr(prop.val)) |allow_locked| {
                        state.allow_locked = allow_locked;
                    } else |_| {
                        return errInvalidProp("allow_locked", prop.val);
                    }
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
    const raw_name = state.node_name orelse return;
    if (!helpers.hostMatches(state.host, hostname)) {
        log.debug("Skipping \"keybinds.{s}\" (host mismatch)", .{raw_name});
        return;
    }

    if (mem.eql(u8, raw_name, "tag_bind")) {
        if (state.arg_count < 1) {
            log.err("tag_bind: missing modifier argument", .{});
            return error.InvalidConfig;
        }
        if (state.arg_count < 2) {
            log.err("tag_bind: missing command argument", .{});
            return error.InvalidConfig;
        }
        const mod_str = utils.stripQuotes(state.args[0]);
        const cmd_str = utils.stripQuotes(state.args[1]);
        const modifiers = try utils.parseModifiers(mod_str) orelse {
            log.err("tag_bind: invalid modifiers \"{s}\"", .{mod_str});
            return error.InvalidConfig;
        };
        const command_tag = std.meta.stringToEnum(NodeName, cmd_str) orelse {
            log.err("tag_bind: invalid command \"{s}\"", .{cmd_str});
            return error.InvalidConfig;
        };
        const command: XkbBindings.Command = switch (command_tag) {
            // We can set these to "0" since they're not used (when in the tag_bind node)
            .set_output_tags => .{ .set_output_tags = 0 },
            .set_window_tags => .{ .set_window_tags = 0 },
            .toggle_output_tags => .{ .toggle_output_tags = 0 },
            .toggle_window_tags => .{ .toggle_window_tags = 0 },
            else => {
                log.err("tag_bind: invalid command \"{s}\". Only tag-keybinds can be used with tag_binds", .{cmd_str});
                return error.InvalidConfig;
            },
        };
        try config.tag_binds.append(utils.gpa, .{
            .modifiers = modifiers,
            .command = command,
            .keysym = null, // Tag binds don't need a keysym (automatically 1-9)
            .allow_locked = state.allow_locked,
        });
        log.debug("tag_bind: {s} {s}", .{ mod_str, cmd_str });
        return;
    }

    const name = std.meta.stringToEnum(NodeName, raw_name) orelse {
        return helpers.invalidNode(raw_name);
    };

    if (state.arg_count < 1) {
        return errMissingArg(name, "modifier(s)");
    }
    if (state.arg_count < 2) {
        return errMissingArg(name, "keysym");
    }

    const mod_str = utils.stripQuotes(state.args[0]);
    const modifiers = try utils.parseModifiers(mod_str) orelse {
        log.err("keybinds: invalid modifiers \"{s}\"", .{mod_str});
        return error.InvalidConfig;
    };

    const key_str = utils.stripQuotes(state.args[1]);
    // Keysym.fromName() needs a [*:0]const u8
    const z = try utils.gpa.dupeZ(u8, key_str);
    defer utils.gpa.free(z);
    const keysym = xkbcommon.Keysym.fromName(z, .case_insensitive);

    const command: XkbBindings.Command = sw: switch (name) {
        .spawn => {
            if (state.arg_count < 3) {
                return errMissingArg(name, "command");
            }
            const exec_str = utils.stripQuotes(state.args[2]);
            break :sw .{ .spawn = try utils.gpa.dupeZ(u8, exec_str) };
        },
        inline .change_primary_ratio, .change_single_window_ratio => |cmd| {
            if (state.arg_count < 3) {
                return errMissingArg(name, "diff");
            }
            const diff_str = utils.stripQuotes(state.args[2]);
            const diff = fmt.parseFloat(f32, diff_str) catch {
                return errInvalidArg(name, diff_str);
            };
            break :sw @unionInit(XkbBindings.Command, @tagName(cmd), diff);
        },
        inline .focus_next_window,
        .focus_prev_window,
        .focus_next_output,
        .focus_prev_output,
        .send_to_next_output,
        .send_to_prev_output,
        .toggle_float,
        .zoom,
        .reload_config,
        .toggle_fullscreen,
        .next_primary_side,
        .prev_primary_side,
        .close_window,
        .exit_river,
        .increment_primary_count,
        .decrement_primary_count,
        .swap_next,
        .swap_prev,
        .center_float,
        .toggle_passthrough,
        => |cmd| {
            // None of these have arguments, just create the union and give it back
            break :sw @unionInit(XkbBindings.Command, @tagName(cmd), {});
        },
        inline .move_up,
        .move_down,
        .move_left,
        .move_right,
        .resize_width,
        .resize_height,
        => |cmd| {
            if (state.arg_count < 3) {
                return errMissingArg(name, "amount");
            }
            const amount_str = utils.stripQuotes(state.args[2]);
            const amount = fmt.parseInt(i32, amount_str, 0) catch {
                return errInvalidArg(name, amount_str);
            };
            break :sw @unionInit(XkbBindings.Command, @tagName(cmd), amount);
        },
        inline .set_output_tags, .set_window_tags, .toggle_output_tags, .toggle_window_tags => |cmd| {
            if (state.arg_count < 3) {
                return errMissingArg(name, "tags");
            }
            const tags_str = utils.stripQuotes(state.args[2]);
            const tags = fmt.parseInt(u32, tags_str, 0) catch {
                return errInvalidArg(name, tags_str);
            };
            break :sw @unionInit(XkbBindings.Command, @tagName(cmd), tags);
        },
    };

    const gop = try config.keybinds.getOrPut(utils.gpa, .{
        .modifiers = modifiers,
        .keysym = keysym,
    });
    if (gop.found_existing) {
        gop.value_ptr.command.deinit();
    }
    gop.value_ptr.* = .{ .command = command, .allow_locked = state.allow_locked };
    log.debug("keybind: {s} {s}", .{ mod_str, key_str });
}

fn errMissingArg(node_name: NodeName, comptime arg_name: []const u8) error{InvalidConfig} {
    log.err("\"keybind.{s}\" missing " ++ arg_name ++ " argument", .{@tagName(node_name)});
    return error.InvalidConfig;
}

fn errInvalidArg(node_name: NodeName, node_value: []const u8) error{InvalidConfig} {
    log.err("Invalid \"keybind.{s}\" ({s})", .{ @tagName(node_name), node_value });
    return error.InvalidConfig;
}

fn errInvalidProp(
    comptime prop_key: []const u8,
    prop_value: []const u8,
) error{InvalidConfig} {
    log.err("\"keybind:\" invalid " ++ prop_key ++ " value \"{s}\"", .{prop_value});
    return error.InvalidConfig;
}

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const wayland = @import("wayland");
const river = wayland.client.river;
const kdl = @import("kdl");
const xkbcommon = @import("xkbcommon");

const utils = @import("../utils.zig");
const Config = @import("../Config.zig");
const XkbBindings = @import("../XkbBindings.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.config_keybind);
