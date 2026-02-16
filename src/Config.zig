// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Config = @This();

const CONFIG_FILE = "beansprout/config.kdl";

/// Width of window borders in pixels
border_width: u8 = 2,
/// Color of focused window's border in 0xRRGGBBAA or 0xRRGGBB form
border_color_focused: RiverColor = utils.parseRgbaComptime("0x89b4fa"),
/// Color of unfocused windows' borders in 0xRRGGBBAA or 0xRRGGBB form
border_color_unfocused: RiverColor = utils.parseRgbaComptime("0x1e1e2e"),

/// Number of windows in the primary stack
/// This is a global default, but each tagmask can have its own value
primary_count: u8 = 1,
/// Proportion of output width taken by the primary stack
/// This is a global default, but each tagmask can have its own value
primary_ratio: f32 = 0.55,

/// Where a new window should attach, top or bottom of the stack
attach_mode: AttachMode = .top,
/// Should focus change when the cursor moves onto a new window
focus_follows_pointer: bool = true,
/// Should the pointer warp to the center of newly-focused windows
pointer_warp_on_focus_change: bool = true,

// TODO: Implement a color when this is null
/// Path to the wallpaper image
wallpaper_image_path: ?[]const u8 = null,

/// Tag overlay configuration. If null, no overlay is created.
tag_overlay: ?TagOverlayConfig = null,

/// Tag bind entries parsed from config (tag_bind nodes in keybinds block)
tag_binds: std.ArrayList(Keybind) = .{},
keybinds: std.ArrayList(Keybind) = .{},
pointer_binds: std.ArrayList(PointerBind) = .{},
input_configs: std.ArrayList(InputConfig) = .{},

// Re-exports
pub const Keybind = keybind_helper.Keybind;
pub const PointerBind = pointer_bind_helper.PointerBind;

pub const TagOverlayConfig = tag_overlay_helper.TagOverlayConfig;
pub const InputConfig = input_helper.InputConfig;

pub const AttachMode = enum {
    top,
    bottom,
};

const NodeName = enum {
    attach_mode,
    primary_count,
    primary_ratio,
    focus_follows_pointer,
    pointer_warp_on_focus_change,
    wallpaper_image_path,
    // Sections with child blocks
    borders,
    keybinds,
    pointer_binds,
    input,
    tag_overlay,
};

pub fn create() !*Config {
    var config: *Config = try utils.gpa.create(Config);
    errdefer config.destroy();
    config.* = .{}; // create() gives us undefined memory

    if (try known_folders.getPath(utils.gpa, .local_configuration)) |config_dir| blk: {
        defer utils.gpa.free(config_dir);

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const config_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ config_dir, CONFIG_FILE }) catch return config;

        const file = fs.openFileAbsolute(config_path, .{}) catch break :blk;

        var read_buffer: [1024]u8 = undefined;
        var file_reader = file.reader(&read_buffer);

        config.load(&file_reader.interface) catch |err| {
            log.err("Error while loading config: {s}. Continuing with default config", .{@errorName(err)});
            // Free any partially-loaded state and reset to defaults
            for (config.keybinds.items) |keybind| {
                switch (keybind.command) {
                    .spawn => |argv| {
                        for (argv) |arg| utils.gpa.free(arg);
                        utils.gpa.free(argv);
                    },
                    else => {},
                }
            }
            config.keybinds.clearAndFree(utils.gpa);
            config.tag_binds.clearAndFree(utils.gpa);
            config.pointer_binds.clearAndFree(utils.gpa);
            for (config.input_configs.items) |ic| {
                if (ic.name) |name| utils.gpa.free(name);
            }
            config.input_configs.clearAndFree(utils.gpa);
            if (config.wallpaper_image_path) |path| {
                utils.gpa.free(path);
            }
            config.* = .{};
        };
    }

    return config;
}

pub fn destroy(config: *Config) void {
    for (config.keybinds.items) |keybind| {
        switch (keybind.command) {
            .spawn => |argv| {
                for (argv) |arg| utils.gpa.free(arg);
                utils.gpa.free(argv);
            },
            else => {},
        }
    }
    config.keybinds.deinit(utils.gpa);
    config.tag_binds.deinit(utils.gpa);
    config.pointer_binds.deinit(utils.gpa);
    for (config.input_configs.items) |ic| {
        if (ic.name) |name| utils.gpa.free(name);
    }
    config.input_configs.deinit(utils.gpa);
    if (config.wallpaper_image_path) |path| {
        utils.gpa.free(path);
    }
    utils.gpa.destroy(config);
}

fn load(config: *Config, reader: *Io.Reader) !void {
    var parser = try kdl.Parser.init(utils.gpa, reader, .{});
    defer parser.deinit(utils.gpa);

    const hostname = blk: {
        var uname = std.posix.uname();
        const hostname = mem.sliceTo(&uname.nodename, 0);
        if (hostname.len == 0) break :blk null;
        break :blk hostname;
    };

    var next_child_block: ?NodeName = null;
    var pending_input_name: ?[]const u8 = null;
    defer if (pending_input_name) |n| utils.gpa.free(n);

    // Parse the KDL config
    while (try parser.next()) |event| {
        // First, we switch on the type of event
        switch (event) {
            .node => |node| {
                if (next_child_block) |child_block| {
                    logWarnMissingChildBlock(child_block);
                    next_child_block = null;
                    if (pending_input_name) |n| utils.gpa.free(n);
                    pending_input_name = null;
                }
                // If it's a node, we check if it's a valid NodeName
                const node_name = std.meta.stringToEnum(NodeName, node.name);
                if (node_name) |name| {
                    if (!helpers.hostMatches(node, &parser, hostname)) {
                        log.debug("Skipping \"{s}\" (host mismatch)", .{@tagName(name)});
                        continue;
                    }
                    // Next, we have to check the specifics for the NodeName
                    switch (name) {
                        .primary_count => {
                            const count_str = utils.stripQuotes(node.arg(&parser, 0) orelse "");
                            // Use @max to ensure a minimum of 1
                            config.primary_count = @max(1, fmt.parseInt(u8, count_str, 10) catch {
                                logWarnInvalidNodeArg(name, count_str);
                                continue;
                            });
                            logDebugSettingNode(name, count_str);
                        },
                        .primary_ratio => {
                            const ratio_str = utils.stripQuotes(node.arg(&parser, 0) orelse "");
                            const ratio = fmt.parseFloat(f32, ratio_str) catch {
                                logWarnInvalidNodeArg(name, ratio_str);
                                continue;
                            };
                            config.primary_ratio = std.math.clamp(ratio, 0.10, 0.90);
                            logDebugSettingNode(name, ratio_str);
                        },
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
                            if (helpers.boolFromKdlStr(focus_follows_pointer_str)) |focus_follows_pointer| {
                                config.focus_follows_pointer = focus_follows_pointer;
                                logDebugSettingNode(name, focus_follows_pointer_str);
                            } else {
                                logWarnInvalidNodeArg(name, focus_follows_pointer_str);
                                continue;
                            }
                        },
                        .pointer_warp_on_focus_change => {
                            const pointer_warp_on_focus_change_str = utils.stripQuotes(node.arg(&parser, 0) orelse "");
                            if (helpers.boolFromKdlStr(pointer_warp_on_focus_change_str)) |pointer_warp_on_focus_change| {
                                config.pointer_warp_on_focus_change = pointer_warp_on_focus_change;
                                logDebugSettingNode(name, pointer_warp_on_focus_change_str);
                            } else {
                                logWarnInvalidNodeArg(name, pointer_warp_on_focus_change_str);
                                continue;
                            }
                        },
                        .wallpaper_image_path => {
                            if (node.argcount() < 1) {
                                logWarnMissingNodeArg(name, "image path");
                                continue;
                            }

                            const path_str = utils.stripQuotes(node.arg(&parser, 0).?);
                            config.wallpaper_image_path = helpers.expandTilde(path_str) catch {
                                logWarnInvalidNodeArg(name, path_str);
                                continue;
                            };
                            logDebugSettingNode(name, path_str);
                        },
                        .borders => {
                            next_child_block = .borders;
                        },
                        .keybinds => {
                            next_child_block = .keybinds;
                        },
                        .pointer_binds => {
                            next_child_block = .pointer_binds;
                        },
                        .input => {
                            pending_input_name = if (node.prop(&parser, "name")) |n|
                                try utils.gpa.dupe(u8, utils.stripQuotes(n))
                            else
                                null;
                            next_child_block = .input;
                        },
                        .tag_overlay => {
                            next_child_block = .tag_overlay;
                        },
                    }
                } else {
                    helpers.logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => {
                if (next_child_block) |child_block| {
                    switch (child_block) {
                        .borders => try borders_helper.load(config, &parser, hostname),
                        .keybinds => try keybind_helper.load(config, &parser, hostname),
                        .pointer_binds => try pointer_bind_helper.load(config, &parser, hostname),
                        .input => {
                            try input_helper.load(config, &parser, pending_input_name, hostname);
                            pending_input_name = null; // ownership transferred
                        },
                        .tag_overlay => try tag_overlay_helper.load(config, &parser, hostname),
                        else => {
                            // Nothing else should ever be marked as a next_child_block
                            unreachable;
                        },
                    }
                    next_child_block = null;
                } else {
                    try helpers.skipChildBlock(&parser);
                }
            },
            .child_block_end => log.err("Reached unexpected .child_block_end. Ignoring it", .{}),
        }
    }
}

inline fn logWarnInvalidNodeArg(node_name: NodeName, node_value: []const u8) void {
    log.warn("Invalid \"{s}\" ({s}). Using default value", .{ @tagName(node_name), node_value });
}

inline fn logWarnMissingNodeArg(node_name: NodeName, comptime arg: []const u8) void {
    log.warn("\"{s}\" missing " ++ arg ++ " argument. Ignoring", .{@tagName(node_name)});
}

inline fn logWarnMissingChildBlock(child_block: NodeName) void {
    log.warn("Expected child block for {s}, but got another node instead. Continuing but ignoring {s}", .{ @tagName(child_block), @tagName(child_block) });
}

inline fn logDebugSettingNode(node_name: NodeName, node_value: []const u8) void {
    log.debug("Setting {s} to {s}", .{ @tagName(node_name), node_value });
}

const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const Io = std.Io;

const kdl = @import("kdl");
const known_folders = @import("known_folders");
const xkbcommon = @import("xkbcommon");

const utils = @import("utils.zig");
const RiverColor = utils.RiverColor;
const XkbBindings = @import("XkbBindings.zig");

const borders_helper = @import("config/borders.zig");
const input_helper = @import("config/input.zig");
const keybind_helper = @import("config/keybinds.zig");
const pointer_bind_helper = @import("config/pointer_binds.zig");
const tag_overlay_helper = @import("config/tag_overlay.zig");
const helpers = @import("config/helpers.zig");

const log = std.log.scoped(.Config);

const testing = std.testing;

test {
    _ = helpers;
}
