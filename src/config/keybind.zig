// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

// We can just directly use the tag type from Command as our node name
const NodeName = @typeInfo(XkbBindings.Command).@"union".tag_type.?;

pub const Keybind = struct {
    modifiers: river.SeatV1.Modifiers,
    command: XkbBindings.Command,
    keysym: ?xkbcommon.Keysym,
};

pub const Key = struct {
    modifiers: river.SeatV1.Modifiers,
    keysym: xkbcommon.Keysym,
};

pub const Map = std.AutoArrayHashMapUnmanaged(Key, XkbBindings.Command);

pub fn load(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                // tag_bind is a special case node name not in KeybindNodeName
                if (mem.eql(u8, node.name, "tag_bind")) {
                    if (!helpers.hostMatches(node, parser, hostname)) {
                        log.debug("Skipping \"keybind.tag_bind\" (host mismatch)", .{});
                        continue;
                    }
                    const mod_str = utils.stripQuotes(node.arg(parser, 0) orelse {
                        log.warn("tag_bind: missing modifier argument. Ignoring", .{});
                        continue;
                    });
                    const cmd_str = utils.stripQuotes(node.arg(parser, 1) orelse {
                        log.warn("tag_bind: missing command argument. Ignoring", .{});
                        continue;
                    });
                    const modifiers = try utils.parseModifiers(mod_str) orelse {
                        log.warn("tag_bind: invalid modifiers \"{s}\". Ignoring", .{mod_str});
                        continue;
                    };

                    const command_tag_type = std.meta.stringToEnum(NodeName, cmd_str) orelse {
                        log.warn("tag_bind: invalid command \"{s}\". Ignoring", .{cmd_str});
                        continue;
                    };
                    const command: XkbBindings.Command = switch (command_tag_type) {
                        // We can set these to "0" since they're not used (when in the tag_bind node)
                        .set_output_tags => .{ .set_output_tags = 0 },
                        .set_window_tags => .{ .set_window_tags = 0 },
                        .toggle_output_tags => .{ .toggle_output_tags = 0 },
                        .toggle_window_tags => .{ .toggle_window_tags = 0 },
                        else => {
                            log.warn("tag_bind: invalid command \"{s}\". Only tag-keybinds can be used with tag_binds. Ignoring", .{cmd_str});
                            continue;
                        },
                    };

                    try config.tag_binds.append(utils.gpa, .{
                        .modifiers = modifiers,
                        .command = command,
                        .keysym = null, // Tag binds don't need a keysym (automatically 1-9)
                    });

                    log.debug("tag_bind: {s} {s}", .{ mod_str, cmd_str });
                    continue;
                }
                // Handle the rest of the possibilities like all the other types of block
                const node_name = std.meta.stringToEnum(NodeName, node.name);
                if (node_name) |name| {
                    if (!helpers.hostMatches(node, parser, hostname)) {
                        log.debug("Skipping \"keybind.{s}\" (host mismatch)", .{@tagName(name)});
                        continue;
                    }
                    // All nodes should have at least a command, modifiers, and a keysym
                    // Some may have more arguments handled in the switch
                    const mod_str = utils.stripQuotes(node.arg(parser, 0) orelse {
                        logWarnMissingNodeArg(name, "modifier(s)");
                        continue;
                    });
                    const modifiers = try utils.parseModifiers(mod_str) orelse {
                        log.warn("keybinds: invalid modifiers \"{s}\". Ignoring", .{mod_str});
                        continue;
                    };

                    const key_str = utils.stripQuotes(node.arg(parser, 1) orelse {
                        logWarnMissingNodeArg(name, "keysym");
                        continue;
                    });
                    // Keysym.fromName() needs a [*:0]const u8
                    const z = try utils.gpa.dupeZ(u8, key_str);
                    defer utils.gpa.free(z);
                    const keysym = xkbcommon.Keysym.fromName(z, .case_insensitive);

                    const command: XkbBindings.Command = sw: switch (name) {
                        .spawn => {
                            // TODO: Add properties to support ENV vars
                            const exec_str = utils.stripQuotes(node.arg(parser, 2) orelse {
                                logWarnMissingNodeArg(name, "command");
                                continue;
                            });
                            var split_exec = try utils.tokenizeShell(exec_str);
                            if (split_exec.len > 0) {
                                // Expand ~ in executable paths
                                const expanded = helpers.expandTilde(split_exec[0]) catch |e| {
                                    if (e == error.HomeNotSet) {
                                        // No ~, just return what we had.
                                        break :sw .{ .spawn = split_exec };
                                    } else {
                                        return e;
                                    }
                                };
                                // tokenizeShell dupes each token, so we have to
                                // free the original value before replacing it.
                                utils.gpa.free(split_exec[0]);
                                split_exec[0] = expanded;
                            }
                            break :sw .{ .spawn = split_exec };
                        },
                        .change_ratio => {
                            const diff_str = utils.stripQuotes(node.arg(parser, 2) orelse {
                                logWarnMissingNodeArg(name, "diff");
                                continue;
                            });
                            const diff = fmt.parseFloat(f32, diff_str) catch {
                                logWarnInvalidNodeArg(name, diff_str);
                                continue;
                            };
                            break :sw .{ .change_ratio = diff };
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
                        .close_window,
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
                            const amount_str = utils.stripQuotes(node.arg(parser, 2) orelse {
                                logWarnMissingNodeArg(name, "amount");
                                continue;
                            });
                            const amount = fmt.parseInt(i32, amount_str, 0) catch {
                                logWarnInvalidNodeArg(name, amount_str);
                                continue;
                            };
                            break :sw @unionInit(XkbBindings.Command, @tagName(cmd), amount);
                        },
                        inline .set_output_tags, .set_window_tags, .toggle_output_tags, .toggle_window_tags => |cmd| {
                            const tags_str = utils.stripQuotes(node.arg(parser, 2) orelse {
                                logWarnMissingNodeArg(name, "tags");
                                continue;
                            });
                            const tags = fmt.parseInt(u32, tags_str, 0) catch {
                                logWarnInvalidNodeArg(name, tags_str);
                                continue;
                            };
                            break :sw @unionInit(XkbBindings.Command, @tagName(cmd), tags);
                        },
                    };

                    const gop = try config.keybinds.getOrPut(utils.gpa, .{
                        .modifiers = modifiers,
                        .keysym = keysym,
                    });
                    if (gop.found_existing) {
                        gop.value_ptr.deinit();
                    }
                    gop.value_ptr.* = command;
                } else {
                    helpers.logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => {
                // keybinds should never have a nested child block
                try helpers.skipChildBlock(parser);
            },
            .child_block_end => {
                // Done parsing the keybinds block; return
                return;
            },
        }
    }
}

inline fn logWarnMissingNodeArg(node_name: NodeName, comptime arg: []const u8) void {
    log.warn("\"keybind.{s}\" missing " ++ arg ++ " argument. Ignoring", .{@tagName(node_name)});
}

inline fn logWarnInvalidNodeArg(node_name: NodeName, node_value: []const u8) void {
    log.warn("Invalid \"keybind.{s}\" ({s}). Ignoring", .{ @tagName(node_name), node_value });
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
