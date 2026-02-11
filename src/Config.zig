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

// TODO: Implement a color when this is null
/// Path to the wallpaper image
wallpaper_image_path: ?[]const u8 = null,

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

const NodeName = enum {
    attach_mode,
    focus_follows_pointer,
    pointer_warp_on_focus_change,
    wallpaper_image_path,
    // Sections with child blocks
    borders,
    keybinds,
    pointer_binds,
    input,
};

const BorderNodeName = enum {
    width,
    color_focused,
    color_unfocused,
};

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
            config.pointer_binds.clearAndFree(utils.allocator);
            for (config.input_configs.items) |ic| {
                if (ic.name) |name| utils.allocator.free(name);
            }
            config.input_configs.clearAndFree(utils.allocator);
            if (config.wallpaper_image_path) |path| {
                utils.allocator.free(path);
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
                for (argv) |arg| utils.allocator.free(arg);
                utils.allocator.free(argv);
            },
            else => {},
        }
    }
    config.keybinds.deinit(utils.allocator);
    config.tag_binds.deinit(utils.allocator);
    config.pointer_binds.deinit(utils.allocator);
    for (config.input_configs.items) |ic| {
        if (ic.name) |name| utils.allocator.free(name);
    }
    config.input_configs.deinit(utils.allocator);
    if (config.wallpaper_image_path) |path| {
        utils.allocator.free(path);
    }
    utils.allocator.destroy(config);
}

fn load(config: *Config, reader: *Io.Reader) !void {
    var parser = try kdl.Parser.init(utils.allocator, reader, .{});
    defer parser.deinit(utils.allocator);

    const hostname = blk: {
        var uname = std.posix.uname();
        const hostname = mem.sliceTo(&uname.nodename, 0);
        if (hostname.len == 0) break :blk null;
        break :blk hostname;
    };

    var next_child_block: ?NodeName = null;
    var pending_input_name: ?[]const u8 = null;
    defer if (pending_input_name) |n| utils.allocator.free(n);

    // Parse the KDL config
    while (try parser.next()) |event| {
        // First, we switch on the type of event
        switch (event) {
            .node => |node| {
                if (next_child_block) |child_block| {
                    logWarnMissingChildBlock(child_block);
                    next_child_block = null;
                    if (pending_input_name) |n| utils.allocator.free(n);
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
                                try utils.allocator.dupe(u8, utils.stripQuotes(n))
                            else
                                null;
                            next_child_block = .input;
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

fn loadKeybindsChildBlock(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                if (!hostMatches(node, parser, hostname)) {
                    logDebugHostMismatch(node.name);
                    continue;
                }
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

                    try config.pointer_binds.append(utils.allocator, .{
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
    errdefer if (input_config.name) |n| utils.allocator.free(n);

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
                try config.input_configs.append(utils.allocator, input_config);
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
        []const u8 => log.debug("Skipping \"keybind.{s}\" (host mismatch)", .{node_name}),
        else => @compileError("This function does not (yet) support type \"" ++ @typeName(node_name_type) ++ "\""),
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

fn expandTilde(path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '~') {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
        return std.fmt.allocPrint(utils.allocator, "{s}{s}", .{ home, path[1..] });
    }
    return utils.allocator.dupe(u8, path);
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
const xkbcommon = @import("xkbcommon");

const utils = @import("utils.zig");
const RiverColor = utils.RiverColor;
const XkbBindings = @import("XkbBindings.zig");

const log = std.log.scoped(.Config);
