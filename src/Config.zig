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

pub const Keybind = struct {
    modifiers: river.SeatV1.Modifiers,
    command: XkbBindings.Command,
    keysym: ?xkbcommon.Keysym,
};

pub const PointerBind = struct {
    modifiers: river.SeatV1.Modifiers,
    button: u32, // Linux button code (BTN_LEFT=0x110, BTN_RIGHT=0x111, BTN_MIDDLE=0x112)
    action: PointerAction,
};

pub const PointerAction = enum {
    move_window,
    resize_window,
};

pub const InputConfig = struct {
    /// Device name to match
    /// If this is null, applies to all devices
    name: ?[]const u8 = null,

    send_events: ?SendEventsModes.Enum = null,
    tap: ?TapState = null,
    tap_button_map: ?TapButtonMap = null,
    drag: ?DragState = null,
    drag_lock: ?DragLockState = null,
    three_finger_drag: ?ThreeFingerDragState = null,
    accel_profile: ?AccelProfile = null,
    accel_speed: ?f64 = null,
    natural_scroll: ?NaturalScrollState = null,
    left_handed: ?LeftHandedState = null,
    click_method: ?ClickMethod = null,
    clickfinger_button_map: ?ClickfingerButtonMap = null,
    middle_emulation: ?MiddleEmulationState = null,
    scroll_method: ?ScrollMethod = null,
    scroll_button: ?u32 = null,
    scroll_button_lock: ?ScrollButtonLockState = null,
    dwt: ?DwtState = null,
    dwtp: ?DwtpState = null,
    rotation: ?u32 = null,
};

pub const AttachMode = enum {
    top,
    bottom,
};

pub const TagOverlayConfig = struct {
    border_width: u8 = 2,
    tag_amount: u8 = 9,
    tags_per_row: u8 = 32,
    square_size: u8 = 40,
    square_inner_padding: u8 = 10,
    square_padding: u8 = 15,
    square_border_width: u8 = 1,
    background_color: pixman.Color = utils.parseRgbaPixmanComptime("0x1e1e2e"),
    border_color: pixman.Color = utils.parseRgbaPixmanComptime("0x6c7086"),
    square_active_background_color: pixman.Color = utils.parseRgbaPixmanComptime("0x89b4fa"),
    square_active_border_color: pixman.Color = utils.parseRgbaPixmanComptime("0x6c7086"),
    square_active_occupied_color: pixman.Color = utils.parseRgbaPixmanComptime("0xcdd6f4"),
    square_inactive_background_color: pixman.Color = utils.parseRgbaPixmanComptime("0x585b70"),
    square_inactive_border_color: pixman.Color = utils.parseRgbaPixmanComptime("0x6c7086"),
    square_inactive_occupied_color: pixman.Color = utils.parseRgbaPixmanComptime("0xcdd6f4"),
    timeout: u32 = 500,
    anchor_top: bool = false,
    anchor_right: bool = false,
    anchor_bottom: bool = false,
    anchor_left: bool = false,
    margin_top: i32 = 0,
    margin_right: i32 = 0,
    margin_bottom: i32 = 0,
    margin_left: i32 = 0,

    pub fn toTagOverlayOptions(self: TagOverlayConfig) TagOverlay.Options {
        return .{
            .border_width = self.border_width,
            .tag_amount = @intCast(std.math.clamp(@as(u32, self.tag_amount), 1, 32)),
            .tags_per_row = @intCast(std.math.clamp(@as(u32, self.tags_per_row), 1, 32)),
            .square_size = self.square_size,
            .square_inner_padding = self.square_inner_padding,
            .square_padding = self.square_padding,
            .square_border_width = self.square_border_width,
            .background_color = self.background_color,
            .border_color = self.border_color,
            .square_active_background_color = self.square_active_background_color,
            .square_active_border_color = self.square_active_border_color,
            .square_active_occupied_color = self.square_active_occupied_color,
            .square_inactive_background_color = self.square_inactive_background_color,
            .square_inactive_border_color = self.square_inactive_border_color,
            .square_inactive_occupied_color = self.square_inactive_occupied_color,
            .anchors = .{
                .top = self.anchor_top,
                .right = self.anchor_right,
                .bottom = self.anchor_bottom,
                .left = self.anchor_left,
            },
            .margins = .{
                .top = self.margin_top,
                .right = self.margin_right,
                .bottom = self.margin_bottom,
                .left = self.margin_left,
            },
            .timeout = self.timeout,
        };
    }
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

const BorderNodeName = enum {
    width,
    color_focused,
    color_unfocused,
};

const TagOverlayNodeName = enum {
    border_width,
    tag_amount,
    tags_per_row,
    square_size,
    square_inner_padding,
    square_padding,
    square_border_width,
    background_color,
    border_color,
    square_active_background_color,
    square_active_border_color,
    square_active_occupied_color,
    square_inactive_background_color,
    square_inactive_border_color,
    square_inactive_occupied_color,
    timeout,
    anchors,
    margins,
};

const TagOverlayAnchorsNodeName = enum { top, right, bottom, left };
const TagOverlayMarginsNodeName = enum { top, right, bottom, left };

const PointerBindNodeName = enum {
    move_window,
    resize_window,
};

const InputConfigNodeName = enum {
    send_events,
    tap,
    tap_button_map,
    drag,
    drag_lock,
    three_finger_drag,
    accel_profile,
    accel_speed,
    natural_scroll,
    left_handed,
    click_method,
    clickfinger_button_map,
    middle_emulation,
    scroll_method,
    scroll_button,
    scroll_button_lock,
    dwt,
    dwtp,
    rotation,
};

// We can just directly use the tag type from Command as our node name
const KeybindNodeName = @typeInfo(XkbBindings.Command).@"union".tag_type.?;

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
                    if (!hostMatches(node, &parser, hostname)) {
                        logDebugHostMismatch(name);
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
                        .wallpaper_image_path => {
                            if (node.argcount() < 1) {
                                logWarnMissingNodeArg(name, "image path");
                                continue;
                            }

                            const path_str = utils.stripQuotes(node.arg(&parser, 0).?);
                            config.wallpaper_image_path = expandTilde(path_str) catch {
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
                    logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => {
                if (next_child_block) |child_block| {
                    switch (child_block) {
                        .borders => try config.loadBordersChildBlock(&parser, hostname),
                        .keybinds => try config.loadKeybindsChildBlock(&parser, hostname),
                        .pointer_binds => try config.loadPointerBindsChildBlock(&parser, hostname),
                        .input => {
                            try config.loadInputChildBlock(&parser, pending_input_name, hostname);
                            pending_input_name = null; // ownership transferred
                        },
                        .tag_overlay => try config.loadTagOverlayChildBlock(&parser, hostname),
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

fn loadBordersChildBlock(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                // If it's a node, we check if it's a valid NodeName
                const node_name = std.meta.stringToEnum(BorderNodeName, node.name);
                if (node_name) |name| {
                    if (!hostMatches(node, parser, hostname)) {
                        logDebugHostMismatch(name);
                        continue;
                    }
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

fn loadTagOverlayChildBlock(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    config.tag_overlay = .{}; // Presence of block = enabled; initialize with defaults

    const TagOverlayChild = enum { anchors, margins };
    var next_child_block: ?TagOverlayChild = null;

    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                if (next_child_block) |child| {
                    log.warn("Expected child block for tag_overlay.{s}, got node instead. Ignoring", .{@tagName(child)});
                    next_child_block = null;
                }
                const node_name = std.meta.stringToEnum(TagOverlayNodeName, node.name);
                if (node_name) |name| {
                    if (!hostMatches(node, parser, hostname)) {
                        logDebugHostMismatch(name);
                        continue;
                    }
                    const val_str = utils.stripQuotes(node.arg(parser, 0) orelse "");
                    switch (name) {
                        .anchors => next_child_block = .anchors,
                        .margins => next_child_block = .margins,
                        // These are all u8s, so we can inline the branch
                        inline .border_width,
                        .tag_amount,
                        .tags_per_row,
                        .square_size,
                        .square_inner_padding,
                        .square_padding,
                        .square_border_width,
                        => |tag| {
                            const val = fmt.parseInt(u8, val_str, 10) catch {
                                logWarnInvalidNodeArg(name, val_str);
                                continue;
                            };
                            @field(config.tag_overlay.?, @tagName(tag)) = val;
                            logDebugSettingNode(name, val_str);
                        },
                        .timeout => {
                            config.tag_overlay.?.timeout = fmt.parseInt(u32, val_str, 10) catch {
                                logWarnInvalidNodeArg(name, val_str);
                                continue;
                            };
                            logDebugSettingNode(name, val_str);
                        },
                        inline .background_color,
                        .border_color,
                        .square_active_background_color,
                        .square_active_border_color,
                        .square_active_occupied_color,
                        .square_inactive_background_color,
                        .square_inactive_border_color,
                        .square_inactive_occupied_color,
                        => |tag| {
                            @field(config.tag_overlay.?, @tagName(tag)) = utils.parseRgbaPixman(val_str) catch {
                                logWarnInvalidNodeArg(name, val_str);
                                continue;
                            };
                            logDebugSettingNode(name, val_str);
                        },
                    }
                } else {
                    logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => {
                if (next_child_block) |child| {
                    switch (child) {
                        .anchors => try config.loadTagOverlayAnchorsBlock(parser, hostname),
                        .margins => try config.loadTagOverlayMarginsBlock(parser, hostname),
                    }
                    next_child_block = null;
                } else {
                    try config.skipChildBlock(parser);
                }
            },
            .child_block_end => return,
        }
    }
}

fn loadTagOverlayAnchorsBlock(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                const node_name = std.meta.stringToEnum(TagOverlayAnchorsNodeName, node.name);
                if (node_name) |name| {
                    if (!hostMatches(node, parser, hostname)) {
                        logDebugHostMismatch(name);
                        continue;
                    }
                    const val_str = utils.stripQuotes(node.arg(parser, 0) orelse "");
                    if (boolFromKdlStr(val_str)) |val| {
                        switch (name) {
                            .top => config.tag_overlay.?.anchor_top = val,
                            .right => config.tag_overlay.?.anchor_right = val,
                            .bottom => config.tag_overlay.?.anchor_bottom = val,
                            .left => config.tag_overlay.?.anchor_left = val,
                        }
                        logDebugSettingNode(name, val_str);
                    } else {
                        logWarnInvalidNodeArg(name, val_str);
                    }
                } else {
                    logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => try config.skipChildBlock(parser),
            .child_block_end => return,
        }
    }
}

fn loadTagOverlayMarginsBlock(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                const node_name = std.meta.stringToEnum(TagOverlayMarginsNodeName, node.name);
                if (node_name) |name| {
                    if (!hostMatches(node, parser, hostname)) {
                        logDebugHostMismatch(name);
                        continue;
                    }
                    const val_str = utils.stripQuotes(node.arg(parser, 0) orelse "");
                    const val = fmt.parseInt(i32, val_str, 10) catch {
                        logWarnInvalidNodeArg(name, val_str);
                        continue;
                    };
                    switch (name) {
                        .top => config.tag_overlay.?.margin_top = val,
                        .right => config.tag_overlay.?.margin_right = val,
                        .bottom => config.tag_overlay.?.margin_bottom = val,
                        .left => config.tag_overlay.?.margin_left = val,
                    }
                    logDebugSettingNode(name, val_str);
                } else {
                    logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => try config.skipChildBlock(parser),
            .child_block_end => return,
        }
    }
}

fn loadKeybindsChildBlock(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                // tag_bind is a special case node name not in KeybindNodeName
                if (mem.eql(u8, node.name, "tag_bind")) {
                    if (!hostMatches(node, parser, hostname)) {
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

                    try config.tag_binds.append(utils.gpa, .{
                        .modifiers = modifiers,
                        .command = command,
                        .keysym = null, // Tag binds don't need a keysym (automatically 1-9)
                    });

                    log.debug("tag_bind: {s} {s}", .{ mod_str, cmd_str });
                    continue;
                }
                // Handle the rest of the possibilities like all the other types of block
                const node_name = std.meta.stringToEnum(KeybindNodeName, node.name);
                if (node_name) |name| {
                    if (!hostMatches(node, parser, hostname)) {
                        logDebugHostMismatch(name);
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
                            // TODO: Add propert(ies) to support ENV vars
                            const exec_str = utils.stripQuotes(node.arg(parser, 2) orelse {
                                logWarnMissingNodeArg(name, "command");
                                continue;
                            });
                            var split_exec = try utils.tokenizeToOwnedSlices(exec_str, ' ');
                            if (split_exec.len > 0) {
                                // Expand ~ in executable paths
                                const expanded = expandTilde(split_exec[0]) catch |e| {
                                    if (e == error.HomeNotSet) {
                                        // No ~, just return what we had.
                                        break :sw .{ .spawn = split_exec };
                                    } else {
                                        return e;
                                    }
                                };
                                // tokenizeToOwnedSlices dupes each token, so we have to
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

                    try config.keybinds.append(utils.gpa, .{
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

fn loadPointerBindsChildBlock(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                const node_name = std.meta.stringToEnum(PointerBindNodeName, node.name);
                if (node_name) |name| {
                    if (!hostMatches(node, parser, hostname)) {
                        logDebugHostMismatch(name);
                        continue;
                    }
                    // Parse modifiers (arg 0)
                    const mod_str = utils.stripQuotes(node.arg(parser, 0) orelse {
                        logWarnMissingNodeArg(name, "modifier(s)");
                        continue;
                    });
                    const modifiers = try utils.parseModifiers(mod_str) orelse {
                        logWarnInvalidNodeArg(name, mod_str);
                        continue;
                    };

                    // Parse button (arg 1)
                    const button_str = utils.stripQuotes(node.arg(parser, 1) orelse {
                        logWarnMissingNodeArg(name, "button");
                        continue;
                    });
                    const button = parseButton(button_str) orelse {
                        logWarnInvalidNodeArg(name, button_str);
                        continue;
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
                    logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => {
                try config.skipChildBlock(parser);
            },
            .child_block_end => {
                return;
            },
        }
    }
}

fn loadInputChildBlock(config: *Config, parser: *kdl.Parser, name: ?[]const u8, hostname: ?[]const u8) !void {
    var input_config: InputConfig = .{ .name = name };
    errdefer if (input_config.name) |n| utils.gpa.free(n);

    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                const node_name = std.meta.stringToEnum(InputConfigNodeName, node.name);
                if (node_name) |tag| {
                    if (!hostMatches(node, parser, hostname)) {
                        logDebugHostMismatch(tag);
                        continue;
                    }
                    const val_str = utils.stripQuotes(node.arg(parser, 0) orelse {
                        logWarnMissingNodeArg(tag, "value");
                        continue;
                    });
                    switch (tag) {
                        .accel_speed => {
                            const speed = fmt.parseFloat(f64, val_str) catch {
                                logWarnInvalidNodeArg(tag, val_str);
                                continue;
                            };
                            input_config.accel_speed = speed;
                            log.debug("input.accel_speed: {s}", .{val_str});
                        },
                        .scroll_button => {
                            const button = parseButton(val_str) orelse {
                                logWarnInvalidNodeArg(tag, val_str);
                                continue;
                            };
                            input_config.scroll_button = button;
                            log.debug("input.scroll_button: {s}", .{val_str});
                        },
                        .rotation => {
                            const angle = fmt.parseInt(u32, val_str, 0) catch {
                                logWarnInvalidNodeArg(tag, val_str);
                                continue;
                            };
                            input_config.rotation = angle;
                            log.debug("input.rotation: {s}", .{val_str});
                        },
                        inline .send_events,
                        .tap,
                        .tap_button_map,
                        .drag,
                        .drag_lock,
                        .three_finger_drag,
                        .accel_profile,
                        .natural_scroll,
                        .left_handed,
                        .click_method,
                        .clickfinger_button_map,
                        .middle_emulation,
                        .scroll_method,
                        .scroll_button_lock,
                        .dwt,
                        .dwtp,
                        => |cmd| {
                            // These all have arguments, but we can use compile time constructs to reduce
                            // code re-use here.
                            // Because all the fields are optional, we have to use @typeInfo and get the optional's child type.
                            const field_name = @tagName(cmd);
                            const FieldType = @typeInfo(@TypeOf(@field(input_config, field_name))).optional.child;
                            if (std.meta.stringToEnum(FieldType, val_str)) |val| {
                                @field(input_config, field_name) = val;
                                log.debug("input.{s}: {s}", .{ field_name, val_str });
                            } else {
                                logWarnInvalidNodeArg(cmd, val_str);
                            }
                        },
                    }
                } else {
                    logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => {
                try config.skipChildBlock(parser);
            },
            .child_block_end => {
                try config.input_configs.append(utils.gpa, input_config);
                return;
            },
        }
    }
}

fn parseButton(s: []const u8) ?u32 {
    // Support both numeric and named buttons
    var lower_buf: [16]u8 = undefined;
    const len = @min(s.len, 16);
    const lower = std.ascii.lowerString(lower_buf[0..len], s[0..len]);

    if (mem.eql(u8, lower, "btn_left") or mem.eql(u8, lower, "button1")) {
        return 0x110; // BTN_LEFT = 272
    } else if (mem.eql(u8, lower, "btn_right") or mem.eql(u8, lower, "button3")) {
        return 0x111; // BTN_RIGHT = 273
    } else if (mem.eql(u8, lower, "btn_middle") or mem.eql(u8, lower, "button2")) {
        return 0x112; // BTN_MIDDLE = 274
    }

    // Try parsing as hex or decimal
    return fmt.parseInt(u32, s, 0) catch null;
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
        PointerBindNodeName => log.warn("Invalid \"pointer_binds.{s}\" ({s}). Ignoring", .{ @tagName(node_name), node_value }),
        InputConfigNodeName => log.warn("Invalid \"input.{s}\" ({s}). Ignoring", .{ @tagName(node_name), node_value }),
        TagOverlayNodeName => log.warn("Invalid \"tag_overlay.{s}\" ({s}). Using default value", .{ @tagName(node_name), node_value }),
        TagOverlayAnchorsNodeName => log.warn("Invalid \"tag_overlay.anchors.{s}\" ({s}). Using default value", .{ @tagName(node_name), node_value }),
        TagOverlayMarginsNodeName => log.warn("Invalid \"tag_overlay.margins.{s}\" ({s}). Using default value", .{ @tagName(node_name), node_value }),
        else => @compileError("This function does not (yet) support type \"" ++ @typeName(node_name_type) ++ "\""),
    }
}

fn logWarnMissingNodeArg(node_name: anytype, comptime arg: []const u8) void {
    const node_name_type = @TypeOf(node_name);
    switch (node_name_type) {
        NodeName => log.warn("\"{s}\" missing " ++ arg ++ " argument. Ignoring", .{@tagName(node_name)}),
        KeybindNodeName => log.warn("\"keybind.{s}\" missing " ++ arg ++ " argument. Ignoring", .{@tagName(node_name)}),
        PointerBindNodeName => log.warn("\"pointer_binds.{s}\" missing " ++ arg ++ " argument. Ignoring", .{@tagName(node_name)}),
        InputConfigNodeName => log.warn("\"input.{s}\" missing " ++ arg ++ " argument. Ignoring", .{@tagName(node_name)}),
        TagOverlayNodeName => log.warn("\"tag_overlay.{s}\" missing " ++ arg ++ " argument. Ignoring", .{@tagName(node_name)}),
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

fn logDebugHostMismatch(node_name: anytype) void {
    const node_name_type = @TypeOf(node_name);
    switch (node_name_type) {
        NodeName => log.debug("Skipping \"{s}\" (host mismatch)", .{@tagName(node_name)}),
        BorderNodeName => log.debug("Skipping \"border.{s}\" (host mismatch)", .{@tagName(node_name)}),
        PointerBindNodeName => log.debug("Skipping \"pointer_binds.{s}\" (host mismatch)", .{@tagName(node_name)}),
        InputConfigNodeName => log.debug("Skipping \"input.{s}\" (host mismatch)", .{@tagName(node_name)}),
        TagOverlayNodeName => log.debug("Skipping \"tag_overlay.{s}\" (host mismatch)", .{@tagName(node_name)}),
        TagOverlayAnchorsNodeName => log.debug("Skipping \"tag_overlay.anchors.{s}\" (host mismatch)", .{@tagName(node_name)}),
        TagOverlayMarginsNodeName => log.debug("Skipping \"tag_overlay.margins.{s}\" (host mismatch)", .{@tagName(node_name)}),
        KeybindNodeName => log.debug("Skipping \"keybind.{s}\" (host mismatch)", .{@tagName(node_name)}),
        else => @compileError("This function does not (yet) support type \"" ++ @typeName(node_name_type) ++ "\""),
    }
}

fn logDebugSettingNode(node_name: anytype, node_value: []const u8) void {
    const node_name_type = @TypeOf(node_name);
    switch (node_name_type) {
        NodeName => log.debug("Setting {s} to {s}", .{ @tagName(node_name), node_value }),
        BorderNodeName => log.debug("Setting border.{s} to {s}", .{ @tagName(node_name), node_value }),
        TagOverlayNodeName => log.debug("Setting tag_overlay.{s} to {s}", .{ @tagName(node_name), node_value }),
        TagOverlayAnchorsNodeName => log.debug("Setting tag_overlay.anchors.{s} to {s}", .{ @tagName(node_name), node_value }),
        TagOverlayMarginsNodeName => log.debug("Setting tag_overlay.margins.{s} to {s}", .{ @tagName(node_name), node_value }),
        else => @compileError("This function does not (yet) support type \"" ++ @typeName(@TypeOf(node_name)) ++ "\""),
    }
}

fn expandTilde(path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '~') {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
        return std.fmt.allocPrint(utils.gpa, "{s}{s}", .{ home, path[1..] });
    }
    return utils.gpa.dupe(u8, path);
}

/// Check whether this machine's hostname matches the hostname property
/// Always returns true if the "host" property is missing (no host = config applies to
/// all hosts). Returns false if the hostname argument is null or does not match.
fn hostMatches(node: kdl.Parser.Node, parser: *kdl.Parser, hostname: ?[]const u8) bool {
    const host_property = utils.stripQuotes(node.prop(parser, "host") orelse return true);
    const hostname_str = hostname orelse return false;
    return mem.eql(u8, host_property, hostname_str);
}

const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const Io = std.Io;

const wayland = @import("wayland");
const river = wayland.client.river;
const AccelProfile = river.LibinputDeviceV1.AccelProfile;
const ClickfingerButtonMap = river.LibinputDeviceV1.ClickfingerButtonMap;
const ClickMethod = river.LibinputDeviceV1.ClickMethod;
const DragLockState = river.LibinputDeviceV1.DragLockState;
const DragState = river.LibinputDeviceV1.DragState;
const DwtState = river.LibinputDeviceV1.DwtState;
const DwtpState = river.LibinputDeviceV1.DwtpState;
const LeftHandedState = river.LibinputDeviceV1.LeftHandedState;
const MiddleEmulationState = river.LibinputDeviceV1.MiddleEmulationState;
const NaturalScrollState = river.LibinputDeviceV1.NaturalScrollState;
const ScrollButtonLockState = river.LibinputDeviceV1.ScrollButtonLockState;
const ScrollMethod = river.LibinputDeviceV1.ScrollMethod;
const SendEventsModes = river.LibinputDeviceV1.SendEventsModes;
const TapButtonMap = river.LibinputDeviceV1.TapButtonMap;
const TapState = river.LibinputDeviceV1.TapState;
const ThreeFingerDragState = river.LibinputDeviceV1.ThreeFingerDragState;

const kdl = @import("kdl");
const known_folders = @import("known_folders");
const pixman = @import("pixman");
const xkbcommon = @import("xkbcommon");

const utils = @import("utils.zig");
const RiverColor = utils.RiverColor;
const TagOverlay = @import("TagOverlay.zig");
const XkbBindings = @import("XkbBindings.zig");

const log = std.log.scoped(.Config);

const testing = std.testing;

test "boolFromKdlStr" {
    // True valid
    try testing.expectEqual(@as(?bool, true), boolFromKdlStr("#true"));
    try testing.expectEqual(@as(?bool, true), boolFromKdlStr("true"));
    // False valid
    try testing.expectEqual(@as(?bool, false), boolFromKdlStr("#false"));
    try testing.expectEqual(@as(?bool, false), boolFromKdlStr("false"));
    // Invalid
    try testing.expectEqual(@as(?bool, null), boolFromKdlStr("yes"));
    try testing.expectEqual(@as(?bool, null), boolFromKdlStr("1"));
    try testing.expectEqual(@as(?bool, null), boolFromKdlStr(""));
    try testing.expectEqual(@as(?bool, null), boolFromKdlStr("TRUE"));
}

test "parseButton named buttons" {
    try testing.expectEqual(@as(?u32, 0x110), parseButton("btn_left"));
    try testing.expectEqual(@as(?u32, 0x110), parseButton("button1"));
    try testing.expectEqual(@as(?u32, 0x111), parseButton("btn_right"));
    try testing.expectEqual(@as(?u32, 0x111), parseButton("button3"));
    try testing.expectEqual(@as(?u32, 0x112), parseButton("btn_middle"));
    try testing.expectEqual(@as(?u32, 0x112), parseButton("button2"));
}

test "parseButton case insensitive" {
    try testing.expectEqual(@as(?u32, 0x110), parseButton("BTN_LEFT"));
    try testing.expectEqual(@as(?u32, 0x110), parseButton("Btn_Left"));
    try testing.expectEqual(@as(?u32, 0x110), parseButton("BUTTON1"));
}

test "parseButton numeric decimal" {
    try testing.expectEqual(@as(?u32, 272), parseButton("272"));
    try testing.expectEqual(@as(?u32, 0), parseButton("0"));
}

test "parseButton numeric hex" {
    try testing.expectEqual(@as(?u32, 0x110), parseButton("0x110"));
}

test "parseButton invalid" {
    try testing.expectEqual(@as(?u32, null), parseButton("bogus"));
    try testing.expectEqual(@as(?u32, null), parseButton(""));
}

test "expandTilde with tilde" {
    const result = try expandTilde("~/foo/bar");
    defer utils.gpa.free(result);
    const home = std.posix.getenv("HOME") orelse return;
    try testing.expect(mem.startsWith(u8, result, home));
    try testing.expect(mem.endsWith(u8, result, "/foo/bar"));
}

test "expandTilde without tilde" {
    const result = try expandTilde("/absolute/path");
    defer utils.gpa.free(result);
    try testing.expectEqualStrings("/absolute/path", result);
}
