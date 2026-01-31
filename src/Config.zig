// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Config = @This();

const CONFIG_FILE = "beansprout/config.kdl";

/// Width of window borders in pixels
border_width: u8 = 2,
/// Color of focused window's border in 0xRRGGBBAA or 0xRRGGBB form
border_color_focused: RiverColor = utils.parseRgbaComptime("0x89b4fa"),
/// Color of unfocused windows' borders in 0xRRGGBBAA or 0xRRGGBB form
border_color_unfocused: RiverColor = utils.parseRgbaComptime("0x1e1e2e"),

/// Where a new window should attach, top or bottom of the stack
attach_mode: AttachMode = .top,
/// Should focus change when the cursor moves onto a new window
focus_follows_pointer: bool = true,
/// Should the pointer warp to the center of newly-focused windows
pointer_warp_on_focus_change: bool = true,

/// Tag bind entries parsed from config (tag_bind nodes in keybinds block)
tag_binds: std.ArrayListUnmanaged(Keybind) = .{},
keybinds: std.ArrayListUnmanaged(Keybind) = .{},

pub const Keybind = struct {
    modifiers: river.SeatV1.Modifiers,
    command: XkbBindings.Command,
    keysym: ?xkbcommon.Keysym,
};

pub const AttachMode = enum {
    top,
    bottom,
};

const NodeName = enum {
    attach_mode,
    focus_follows_pointer,
    pointer_warp_on_focus_change,
    borders,
    keybinds,
};

const BorderNodeName = enum {
    width,
    color_focused,
    color_unfocused,
};

// We can just directly use the tag type from Command as our node name
const KeybindNodeName = @typeInfo(XkbBindings.Command).@"union".tag_type.?;

pub fn create() !*Config {
    var config: *Config = try utils.allocator.create(Config);
    errdefer config.destroy();
    config.* = .{}; // create() gives us undefined memory

    if (try known_folders.getPath(utils.allocator, .local_configuration)) |config_dir| blk: {
        defer utils.allocator.free(config_dir);

        const config_path = try std.fmt.allocPrint(utils.allocator, "{s}/{s}", .{ config_dir, CONFIG_FILE });
        defer utils.allocator.free(config_path);

        const file = fs.openFileAbsolute(config_path, .{}) catch break :blk;

        var read_buffer: [1024]u8 = undefined;
        var file_reader = file.reader(&read_buffer);

        config.load(&file_reader.interface) catch |err| {
            log.err("Error while loading config: {s}. Continuing with default config", .{@errorName(err)});
            // Free any partially-loaded state and reset to defaults
            for (config.keybinds.items) |keybind| {
                switch (keybind.command) {
                    .spawn => |argv| {
                        for (argv) |arg| utils.allocator.free(arg);
                        utils.allocator.free(argv);
                    },
                    else => {},
                }
            }
            config.keybinds.clearAndFree(utils.allocator);
            config.tag_binds.clearAndFree(utils.allocator);
            config.* = .{};
        };
    }

    return config;
}

pub fn destroy(config: *Config) void {
    for (config.keybinds.items) |keybind| {
        switch (keybind.command) {
            .spawn => |argv| {
                for (argv) |arg| utils.allocator.free(arg);
                utils.allocator.free(argv);
            },
            else => {},
        }
    }
    config.keybinds.deinit(utils.allocator);
    config.tag_binds.deinit(utils.allocator);
    utils.allocator.destroy(config);
}

// TODO: Support kdl properties to specific the hostname the config should affect
fn load(config: *Config, reader: *Io.Reader) !void {
    var parser = try kdl.Parser.init(utils.allocator, reader, .{});
    defer parser.deinit(utils.allocator);

    var next_child_block: ?NodeName = null;

    // Parse the KDL config
    while (try parser.next()) |event| {
        // First, we switch on the type of event
        switch (event) {
            .node => |node| {
                if (next_child_block) |child_block| {
                    logWarnMissingChildBlock(child_block);
                    next_child_block = null;
                }
                // If it's a node, we check if it's a valid NodeName
                const node_name = std.meta.stringToEnum(NodeName, node.name);
                if (node_name) |name| {
                    // Next, we have to check the specifics for the NodeName
                    switch (name) {
                        .attach_mode => {
                            const attach_mode_str = utils.stripQuotes(node.arg(&parser, 0) orelse "");
                            if (std.meta.stringToEnum(AttachMode, attach_mode_str)) |mode| {
                                config.attach_mode = mode;
                                logDebugSettingNode(name, attach_mode_str);
                            } else {
                                logWarnInvalidNodeArg(name, attach_mode_str);
                                continue;
                            }
                        },
                        .focus_follows_pointer => {
                            const focus_follows_pointer_str = utils.stripQuotes(node.arg(&parser, 0) orelse "");
                            if (boolFromKdlStr(focus_follows_pointer_str)) |focus_follows_pointer| {
                                config.focus_follows_pointer = focus_follows_pointer;
                                logDebugSettingNode(name, focus_follows_pointer_str);
                            } else {
                                logWarnInvalidNodeArg(name, focus_follows_pointer_str);
                                continue;
                            }
                        },
                        .pointer_warp_on_focus_change => {
                            const pointer_warp_on_focus_change_str = utils.stripQuotes(node.arg(&parser, 0) orelse "");
                            if (boolFromKdlStr(pointer_warp_on_focus_change_str)) |pointer_warp_on_focus_change| {
                                config.pointer_warp_on_focus_change = pointer_warp_on_focus_change;
                                logDebugSettingNode(name, pointer_warp_on_focus_change_str);
                            } else {
                                logWarnInvalidNodeArg(name, pointer_warp_on_focus_change_str);
                                continue;
                            }
                        },
                        .borders => {
                            next_child_block = .borders;
                        },
                        .keybinds => {
                            next_child_block = .keybinds;
                        },
                    }
                } else {
                    logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => {
                if (next_child_block) |child_block| {
                    switch (child_block) {
                        .borders => try config.loadBordersChildBlock(&parser),
                        .keybinds => try config.loadKeybindsChildBlock(&parser),
                        else => {
                            // Nothing else should ever be marked as a next_child_block
                            unreachable;
                        },
                    }
                    next_child_block = null;
                } else {
                    try config.skipChildBlock(&parser);
                }
            },
            .child_block_end => log.err("Reached unexpected .child_block_end. Ignoring it", .{}),
        }
    }
}

fn loadBordersChildBlock(config: *Config, parser: *kdl.Parser) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                // If it's a node, we check if it's a valid NodeName
                const node_name = std.meta.stringToEnum(BorderNodeName, node.name);
                if (node_name) |name| {
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
                    logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => {
                // borders should never have a nested child block
                try config.skipChildBlock(parser);
            },
            .child_block_end => {
                // Done parsing the borders block; return
                return;
            },
        }
    }
}

fn loadKeybindsChildBlock(config: *Config, parser: *kdl.Parser) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                // tag_bind is a special case node name
                if (mem.eql(u8, node.name, "tag_bind")) {
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

                    const command_tag_type = std.meta.stringToEnum(KeybindNodeName, cmd_str) orelse {
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

                    try config.tag_binds.append(utils.allocator, .{
                        .modifiers = modifiers,
                        .command = command,
                        .keysym = null, // Tag binds don't need a keysym (automatically 1-9)
                    });

                    // TODO: Make a logger for keybind settings
                    log.debug("tag_bind: {s} {s}", .{ mod_str, cmd_str });
                    continue;
                }
                // Handle the rest of the possiblities like all the other types of block
                const node_name = std.meta.stringToEnum(KeybindNodeName, node.name);
                if (node_name) |name| {
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
                    const z = try utils.allocator.dupeZ(u8, key_str);
                    defer utils.allocator.free(z);
                    const keysym = xkbcommon.Keysym.fromName(z, .case_insensitive);

                    const command: XkbBindings.Command = sw: switch (name) {
                        .spawn => {
                            // TODO: Add propert(ies) to support ENV vars
                            const exec_str = utils.stripQuotes(node.arg(parser, 2) orelse {
                                logWarnMissingNodeArg(name, "command");
                                continue;
                            });
                            const split_exec = try utils.tokenizeToOwnedSlices(exec_str, ' ');
                            break :sw .{ .spawn = split_exec };
                        },
                        .focus_next => {
                            break :sw .focus_next;
                        },
                        .focus_prev => {
                            break :sw .focus_prev;
                        },
                        .toggle_fullscreen => {
                            break :sw .toggle_fullscreen;
                        },
                        .close_window => {
                            break :sw .close_window;
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

                    try config.keybinds.append(utils.allocator, .{
                        .modifiers = modifiers,
                        .command = command,
                        .keysym = keysym,
                    });
                } else {
                    logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => {
                // keybinds should never have a nested child block
                try config.skipChildBlock(parser);
            },
            .child_block_end => {
                // Done parsing the keybinds block; return
                return;
            },
        }
    }
}

/// Skips an entire child block including any nested child blocks
fn skipChildBlock(_: *Config, parser: *kdl.Parser) !void {
    log.warn("Unexpected child block. Skipping it", .{});

    var depth: usize = 0;
    while (try parser.next()) |event| {
        switch (event) {
            // Nested child block
            .child_block_begin => depth += 1,
            .child_block_end => {
                if (depth == 0) {
                    return;
                } else {
                    depth -= 1;
                }
            },
            else => {
                // We don't care about any nodes in here
            },
        }
    }
}

/// Convert a KDL argument into a bool
///
/// if arg_str in ["#true", "true"], return true
/// if arg_str in ["#false", "false"], return false
/// else, return null
fn boolFromKdlStr(arg_str: []const u8) ?bool {
    if (mem.eql(u8, arg_str, "#true") or
        mem.eql(u8, arg_str, "true"))
    {
        return true;
    } else if (mem.eql(u8, arg_str, "#false") or
        mem.eql(u8, arg_str, "false"))
    {
        return false;
    }
    return null;
}

fn logWarnInvalidNodeArg(node_name: anytype, node_value: []const u8) void {
    const node_name_type = @TypeOf(node_name);
    switch (node_name_type) {
        NodeName => log.warn("Invalid \"{s}\" ({s}). Using default value", .{ @tagName(node_name), node_value }),
        BorderNodeName => log.warn("Invalid \"border.{s}\" ({s}). Using default value", .{ @tagName(node_name), node_value }),
        KeybindNodeName => log.warn("Invalid \"keybind.{s}\" ({s}). Ignoring", .{ @tagName(node_name), node_value }),
        else => @compileError("This function does not (yet) support type \"" ++ @typeName(node_name_type) ++ "\""),
    }
}

fn logWarnMissingNodeArg(node_name: anytype, comptime arg: []const u8) void {
    const node_name_type = @TypeOf(node_name);
    switch (node_name_type) {
        KeybindNodeName => log.warn("\"keybind.{s}\" missing " ++ arg ++ " argument. Ignoring", .{@tagName(node_name)}),
        else => @compileError("This function does not (yet) support type \"" ++ @typeName(node_name_type) ++ "\""),
    }
}

fn logWarnInvalidNode(node_name: []const u8) void {
    log.warn("Invalid KDL node {s}. Ignoring it and carrying on", .{node_name});
}

fn logWarnMissingChildBlock(child_block: anytype) void {
    const child_block_type = @TypeOf(child_block);
    switch (child_block_type) {
        NodeName => log.warn("Expected child block for {s}, but got another node instead. Continuing but ignoring {s}", .{ @tagName(child_block), @tagName(child_block) }),
        else => @compileError("This function does not (yet) support type \"" ++ @typeName(child_block_type) ++ "\""),
    }
}

fn logDebugSettingNode(node_name: anytype, node_value: []const u8) void {
    const node_name_type = @TypeOf(node_name);
    switch (node_name_type) {
        NodeName => log.debug("Setting {s} to {s}", .{ @tagName(node_name), node_value }),
        BorderNodeName => log.debug("Setting border.{s} to {s}", .{ @tagName(node_name), node_value }),
        else => @compileError("This function does not (yet) support type \"" ++ @typeName(@TypeOf(node_name)) ++ "\""),
    }
}

const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const Io = std.Io;

const wayland = @import("wayland");
const river = wayland.client.river;

const kdl = @import("kdl");
const known_folders = @import("known_folders");
const xkbcommon = @import("xkbcommon");

const utils = @import("utils.zig");
const RiverColor = utils.RiverColor;
const XkbBindings = @import("XkbBindings.zig");

const log = std.log.scoped(.Config);
