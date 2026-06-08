// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Config = @This();

const config_file = "beansprout/config.kdl";

pub const min_primary_ratio = 0.10;
pub const max_primary_ratio = 0.90;

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
/// Proportion of output width taken by a window if it's the only visible tiled window
/// This is intended to be useful for ultrawides where a very wide window might not look very nice
/// When this is < 1.0 and only one window is being tiled, the window will have width
/// output_width * single_window_ratio and be centered on the output
single_window_ratio: f32 = 1.0,

/// Side the primary should be on
primary_side: PrimarySide = .left,

/// Where a new window should attach, top or bottom of the stack
attach_mode: AttachMode = .top,
/// Should focus change when the cursor moves onto a new window
focus_follows_pointer: bool = true,
/// Should the output that windows spawn on change to follow the pointer
output_focus_follows_pointer: bool = true,
/// Should focus follow windows being sent to another output
focus_on_send: FocusOnSend = .if_visible,
/// Next focus direction after currently focused window is closed or hidden
focus_next_direction: FocusDirection = .next,
/// Should the pointer warp to the center of newly-focused windows
pointer_warp_on_focus_change: bool = true,
/// Should restore focus to the last focused visible window when switching tags or outputs
restore_focus: bool = false,

/// Path to the wallpaper image
wallpaper_image_path: ?[:0]const u8 = null,

cursor: ?struct {
    /// Name of the XCursor theme to use, e.g. "Adwaita" or "Bibata-Modern-Classic"
    theme: [:0]const u8,
    /// Cursor size in pixels
    size: u32,
} = null,

/// Tag overlay configuration. If null, no overlay is created.
tag_overlay_config: ?TagOverlayConfig = null,
/// Bar configuration. If null, no bar is created.
bar_config: ?BarConfig = null,

/// Keyboard layout configuration
keyboard_layout: KeyboardLayoutConfig = .{},

/// Tag bind entries parsed from config (tag_bind nodes in keybinds block)
tag_binds: std.ArrayList(Keybind) = .empty,
// We use a hash map so that duplicate keybinds can be easily de-duplicated
keybinds: keybind.Map = .{},
pointer_binds: std.ArrayList(PointerBind) = .empty,
input_configs: std.ArrayList(InputConfig) = .empty,
window_rules: std.ArrayList(WindowRule) = .empty,

// Re-exports
pub const Keybind = keybind.Keybind;
pub const PointerBind = pointer_bind.PointerBind;
pub const WindowRule = window_rule.Rule;
pub const WindowRuleAction = window_rule.Action;

pub const PrimarySide = enum { left, right };

pub const AttachMode = enum { top, bottom };

pub const FocusOnSend = enum {
    /// follow the window only if it's visible on the destination (current behaviour as of 510feb42)
    if_visible,
    /// focus stays on current output, falling back to next visible window or getting cleared
    never,
    /// follow unconditionally, OR the window's tags onto the destination if the window wouldn't be visible
    always,
    /// follow unconditionally AND always OR the window's tags onto the destination even if the
    /// window would be visible. This is only different than `always` in the case that the
    /// window has multiple tags
    always_or,
};

const FocusDirection = enum { next, prev };

const NodeName = enum {
    primary_count,
    primary_ratio,
    primary_side,
    single_window_ratio,
    attach_mode,
    focus_follows_pointer,
    output_focus_follows_pointer,
    focus_on_send,
    focus_next_direction,
    pointer_warp_on_focus_change,
    restore_focus,
    wallpaper_image_path,
    cursor_theme,
    // Sections with child blocks
    bar,
    borders,
    input,
    keyboard_layout,
    keybinds,
    pointer_binds,
    tag_overlay,
    window_rules,
};

/// State accumulated while parsing a KDL node
/// Each node gets its own parse state, i.e. state is reset between nodes
const ParseState = struct {
    /// Enum version of the current node
    cur_node: ?NodeName = null,

    /// The hostname that this node should apply to
    host: ?[]const u8 = null,

    /// The name of the input that this block should apply to
    /// This property is only valid on `input` nodes
    name: ?[]const u8 = null,

    /// Arguments to the current node
    /// This can be expanded if any node ends up needing more arguments.
    args: [2][]const u8 = .{ "", "" },
    /// The number of arguments parsed so far on this node
    arg_count: usize = 0,
};

pub fn init(environ: process.Environ.Map) !Config {
    var config: Config = .{};
    errdefer config.deinit();

    init: {
        var path_buf: [fs.max_path_bytes]u8 = undefined;
        const config_path = if (try known_folders.getPath(io, utils.gpa, environ, .local_configuration)) |config_dir| blk: {
            defer utils.gpa.free(config_dir);
            break :blk std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ config_dir, config_file }) catch break :init;
        } else break :init;

        const hostname = blk: {
            var uname = posix.uname();
            const hostname = mem.sliceTo(&uname.nodename, 0);
            if (hostname.len == 0) break :blk null;
            break :blk hostname;
        };

        const file = Io.Dir.openFileAbsolute(io, config_path, .{ .mode = .read_only }) catch break :init;
        defer file.close(io);

        const file_len = try file.length(io);

        // file_len+1 zero-fills the last byte so that; kdl.Parser.init
        // gets its [:0]const u8. The :0 below asserts that sentinel exists.
        var file_mmap = try file.createMemoryMap(io, .{ .len = file_len + 1, .protection = .{ .read = true } });
        defer file_mmap.destroy(io);

        var parser = kdl.Parser.init(file_mmap.memory[0..file_len :0]);

        var state: ParseState = .{};

        var event = try parser.next();
        while (event != .eof) : (event = try parser.next()) {
            switch (event) {
                .node => |node| {
                    if (state.cur_node) |cur_node| {
                        switch (cur_node) {
                            .primary_count,
                            .primary_ratio,
                            .primary_side,
                            .single_window_ratio,
                            .attach_mode,
                            .focus_follows_pointer,
                            .output_focus_follows_pointer,
                            .focus_on_send,
                            .focus_next_direction,
                            .pointer_warp_on_focus_change,
                            .restore_focus,
                            .wallpaper_image_path,
                            .cursor_theme,
                            => try config.flushTopLevelNode(environ, hostname, state),
                            else => {
                                log.err("Expected child block for \"{s}\"", .{@tagName(cur_node)});
                                return error.InvalidConfig;
                            },
                        }
                    }
                    state = .{};
                    state.cur_node = std.meta.stringToEnum(NodeName, node.val) orelse
                        return helpers.invalidNode(node.val);
                },
                .arg => |arg| {
                    if (state.arg_count >= state.args.len) {
                        log.err("Too many arguments to node \"{s}\"", .{@tagName(state.cur_node.?)});
                        return error.KdlTooManyArgs;
                    }
                    state.args[state.arg_count] = arg.val;
                    state.arg_count += 1;
                },
                .prop => |prop| {
                    if (mem.eql(u8, prop.key, "host")) {
                        state.host = prop.val;
                    } else if (state.cur_node == .input and mem.eql(u8, prop.key, "name")) {
                        state.name = prop.val;
                    } else {
                        log.warn("Unknown property \"{s}=\" for node \"{s}\"", .{
                            prop.key,
                            @tagName(state.cur_node.?),
                        });
                    }
                },
                .child_block_begin => {
                    const cur_node = state.cur_node orelse {
                        log.err("Unexpected child block", .{});
                        return error.InvalidConfig;
                    };
                    if (!helpers.hostMatches(state.host, hostname)) {
                        log.debug("Skipping \"{s}\" block (host mismatch)", .{@tagName(cur_node)});
                        try helpers.skipChildBlock(&parser);
                    } else {
                        switch (cur_node) {
                            .bar => try BarConfig.load(&config, &parser, hostname),
                            .borders => try border.load(&config, &parser, hostname),
                            .keyboard_layout => try KeyboardLayoutConfig.load(&config, &parser, hostname),
                            .keybinds => try keybind.load(&config, &parser, hostname),
                            .pointer_binds => try pointer_bind.load(&config, &parser, hostname),
                            .input => {
                                const input_name = if (state.name) |name|
                                    try utils.gpa.dupe(u8, utils.stripQuotes(name))
                                else
                                    null;
                                try InputConfig.load(&config, &parser, input_name, hostname);
                            },
                            .tag_overlay => try TagOverlayConfig.load(&config, &parser, hostname),
                            .window_rules => try window_rule.load(&config, &parser, hostname),
                            else => {
                                log.err("\"{s}\" does not take a child block", .{@tagName(cur_node)});
                                return error.InvalidConfig;
                            },
                        }
                    }
                    state = .{};
                },
                .child_block_end => {
                    log.err("Unexpected closing brace", .{});
                    return error.InvalidConfig;
                },
                .invalid => return error.KdlInvalidConfig,
                .eof => break,
            }
        }

        // Flush the last top-level node
        if (state.cur_node) |cur_node| {
            switch (cur_node) {
                .primary_count,
                .primary_ratio,
                .primary_side,
                .single_window_ratio,
                .attach_mode,
                .focus_follows_pointer,
                .output_focus_follows_pointer,
                .focus_on_send,
                .focus_next_direction,
                .pointer_warp_on_focus_change,
                .restore_focus,
                .wallpaper_image_path,
                .cursor_theme,
                => try config.flushTopLevelNode(environ, hostname, state),
                else => {
                    log.err("Expected child block for \"{s}\", got EOF", .{@tagName(cur_node)});
                    return error.InvalidConfig;
                },
            }
        }
    }

    if (config.keybinds.count() == 0) {
        log.warn(
            \\Loaded a config without keybinds. Falling back to defaults:
            \\  Mod4+T        - spawn `foot`
            \\  Mod4+Shift+R  - reload config
            \\  Ctrl+Alt+Del  - exit River
        , .{});
        config.addFallbackKeybinds();
    }

    return config;
}

pub fn deinit(config: *Config) void {
    for (config.keybinds.values()) |value| {
        value.command.deinit();
    }
    config.keybinds.deinit(utils.gpa);
    config.tag_binds.deinit(utils.gpa);
    config.pointer_binds.deinit(utils.gpa);
    for (config.input_configs.items) |ic| {
        if (ic.name) |name| {
            utils.gpa.free(name);
        }
    }
    config.input_configs.deinit(utils.gpa);
    for (config.window_rules.items) |rule| {
        if (rule.app_id_glob) |app_id_glob| {
            utils.gpa.free(app_id_glob);
        }
        if (rule.title_glob) |title_glob| {
            utils.gpa.free(title_glob);
        }
    }
    config.window_rules.deinit(utils.gpa);
    if (config.bar_config) |bar_config| {
        if (bar_config.fonts) |fonts| {
            utils.gpa.free(fonts);
        }
        if (bar_config.time_format) |time_format| {
            utils.gpa.free(time_format);
        }
    }
    if (config.keyboard_layout.rules) |rules| {
        utils.gpa.free(rules);
    }
    if (config.keyboard_layout.model) |model| {
        utils.gpa.free(model);
    }
    if (config.keyboard_layout.layout) |layout| {
        utils.gpa.free(layout);
    }
    if (config.keyboard_layout.variant) |variant| {
        utils.gpa.free(variant);
    }
    if (config.keyboard_layout.options) |options| {
        utils.gpa.free(options);
    }
    if (config.wallpaper_image_path) |wallpaper_image_path| {
        utils.gpa.free(wallpaper_image_path);
    }
    if (config.cursor) |cursor| {
        utils.gpa.free(cursor.theme);
    }
}

/// Set up a top-level config value based on the accumulated state in `state`
/// This method only parses nodes with a single argument
pub fn flushTopLevelNode(
    config: *Config,
    environ: process.Environ.Map,
    hostname: ?[:0]u8,
    state: ParseState,
) !void {
    if (state.cur_node == null) {
        return error.UnfinishedState;
    }
    const cur_node = state.cur_node.?;
    if (!helpers.hostMatches(state.host, hostname)) {
        log.info("Skipping config \"{s}\" (host mismatch)", .{@tagName(cur_node)});
        return;
    }
    // Every top-level config needs at least 1 argument
    if (state.arg_count < 1) {
        log.err("Config \"{s}\" has an invalid number of arguments (got {d})", .{
            @tagName(cur_node),
            state.arg_count,
        });
        return error.InvalidNumberOfArguments;
    }
    const arg_str = utils.stripQuotes(state.args[0]);
    switch (cur_node) {
        .primary_count => |tag| {
            const count_str = utils.stripQuotes(arg_str);
            config.primary_count = @max(1, fmt.parseInt(u8, count_str, 10) catch {
                return errInvalidArg(tag, count_str);
            });
            logDebugSettingNode(tag, count_str);
        },
        .primary_ratio => |tag| {
            const ratio = fmt.parseFloat(f32, arg_str) catch {
                return errInvalidArg(tag, arg_str);
            };
            config.primary_ratio = std.math.clamp(ratio, min_primary_ratio, max_primary_ratio);
            if (ratio != config.primary_ratio) {
                log.warn("primary_ratio outside of valid range ({d} to {d}); clamping it", .{ min_primary_ratio, max_primary_ratio });
            }
            logDebugSettingNode(tag, arg_str);
        },
        .primary_side => |tag| {
            if (std.meta.stringToEnum(PrimarySide, arg_str)) |mode| {
                config.primary_side = mode;
                logDebugSettingNode(tag, arg_str);
            } else {
                return errInvalidArg(tag, arg_str);
            }
        },
        .single_window_ratio => |tag| {
            const ratio = fmt.parseFloat(f32, arg_str) catch {
                return errInvalidArg(tag, arg_str);
            };
            // We use 1.00 here because it doesn't make sense for a window to have a ratio > 1,
            // i.e. for it to be wider than the output
            config.single_window_ratio = std.math.clamp(ratio, min_primary_ratio, 1.00);
            if (ratio != config.single_window_ratio) {
                log.info("single_window_ratio outside of valid range ({d} to {d}); clamping it", .{ min_primary_ratio, 1.00 });
            }
            logDebugSettingNode(tag, arg_str);
        },
        .attach_mode => |tag| {
            if (std.meta.stringToEnum(AttachMode, arg_str)) |mode| {
                config.attach_mode = mode;
                logDebugSettingNode(tag, arg_str);
            } else {
                return errInvalidArg(tag, arg_str);
            }
        },
        .focus_follows_pointer => |tag| {
            if (helpers.boolFromKdlStr(arg_str)) |focus_follows_pointer| {
                config.focus_follows_pointer = focus_follows_pointer;
                logDebugSettingNode(tag, arg_str);
            } else |_| {
                return errInvalidArg(tag, arg_str);
            }
        },
        .output_focus_follows_pointer => |tag| {
            if (helpers.boolFromKdlStr(arg_str)) |output_focus_follows_pointer| {
                config.output_focus_follows_pointer = output_focus_follows_pointer;
                logDebugSettingNode(tag, arg_str);
            } else |_| {
                return errInvalidArg(tag, arg_str);
            }
        },
        .focus_on_send => |tag| {
            if (std.meta.stringToEnum(FocusOnSend, arg_str)) |focus_on_send| {
                config.focus_on_send = focus_on_send;
                logDebugSettingNode(tag, arg_str);
            } else {
                return errInvalidArg(tag, arg_str);
            }
        },
        .focus_next_direction => |tag| {
            if (std.meta.stringToEnum(FocusDirection, arg_str)) |focus_next_direction| {
                config.focus_next_direction = focus_next_direction;
                logDebugSettingNode(tag, arg_str);
            } else {
                return errInvalidArg(tag, arg_str);
            }
        },
        .pointer_warp_on_focus_change => |tag| {
            if (helpers.boolFromKdlStr(arg_str)) |pointer_warp_on_focus_change| {
                config.pointer_warp_on_focus_change = pointer_warp_on_focus_change;
                logDebugSettingNode(tag, arg_str);
            } else |_| {
                return errInvalidArg(tag, arg_str);
            }
        },
        .restore_focus => |tag| {
            if (helpers.boolFromKdlStr(arg_str)) |restore_focus| {
                config.restore_focus = restore_focus;
                logDebugSettingNode(tag, arg_str);
            } else |_| {
                return errInvalidArg(tag, arg_str);
            }
        },
        .wallpaper_image_path => |tag| {
            const new_path = helpers.expandTilde(environ, arg_str) catch {
                return errInvalidArg(tag, arg_str);
            };
            if (config.wallpaper_image_path) |old| utils.gpa.free(old);
            config.wallpaper_image_path = new_path;
            logDebugSettingNode(tag, arg_str);
        },
        .cursor_theme => |tag| {
            const theme = try utils.gpa.dupeZ(u8, arg_str);
            const size: u32 = if (state.arg_count > 1) blk: {
                const size_str = utils.stripQuotes(state.args[1]);
                break :blk fmt.parseInt(u32, size_str, 10) catch {
                    utils.gpa.free(theme);
                    log.err("Invalid \"cursor_theme\" size ({s})", .{size_str});
                    return error.InvalidConfig;
                };
            } else 24;
            logDebugSettingNode(tag, arg_str);
            if (config.cursor) |old| {
                utils.gpa.free(old.theme);
            }
            config.cursor = .{ .theme = theme, .size = size };
        },
        else => unreachable,
    }
}

fn addFallbackKeybinds(config: *Config) void {
    const Entry = struct { keybind.Key, keybind.Value };
    const fallbacks = [_]Entry{
        .{ .{ .modifiers = .{ .ctrl = true, .mod1 = true }, .keysym = .Delete }, .{ .command = @unionInit(XkbBindings.Command, "exit_river", {}), .allow_locked = false } },
        .{ .{ .modifiers = .{ .mod4 = true, .shift = true }, .keysym = .r }, .{ .command = @unionInit(XkbBindings.Command, "reload_config", {}), .allow_locked = false } },
        .{ .{ .modifiers = .{ .mod4 = true }, .keysym = .t }, .{ .command = .{ .spawn = utils.gpa.dupeZ(u8, "foot") catch @panic("Out of memory") }, .allow_locked = false } },
    };
    for (&fallbacks) |*entry| {
        config.keybinds.put(utils.gpa, entry[0], entry[1]) catch @panic("Out of memory");
    }
}

fn errInvalidArg(node_name: NodeName, node_value: []const u8) error{InvalidConfig} {
    log.err("Invalid \"{s}\" ({s})", .{ @tagName(node_name), node_value });
    return error.InvalidConfig;
}

inline fn logDebugSettingNode(node_name: NodeName, node_value: []const u8) void {
    log.debug("Setting {s} to {s}", .{ @tagName(node_name), node_value });
}

const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const process = std.process;
const Io = std.Io;
const io = Io.Threaded.global_single_threaded.io();

const kdl = @import("kdl");
const known_folders = @import("known_folders");
const xkbcommon = @import("xkbcommon");

const utils = @import("utils.zig");
const RiverColor = utils.RiverColor;
const XkbBindings = @import("XkbBindings.zig");

const border = @import("config/border.zig");
const helpers = @import("config/helpers.zig");
const KeyboardLayoutConfig = @import("config/KeyboardLayoutConfig.zig");
const keybind = @import("config/keybind.zig");
const pointer_bind = @import("config/pointer_bind.zig");
const window_rule = @import("config/window_rule.zig");
const BarConfig = @import("config/BarConfig.zig");
const InputConfig = @import("config/InputConfig.zig");
const TagOverlayConfig = @import("config/TagOverlayConfig.zig");

const log = std.log.scoped(.Config);

test {
    _ = helpers;
}
