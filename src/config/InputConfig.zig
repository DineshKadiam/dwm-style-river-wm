// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const InputConfig = @This();

const NodeName = enum {
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

/// State accumulated while parsing a KDL node
/// Each node gets its own parse state, i.e. state is reset between nodes
const ParseState = struct {
    /// Enum version of the current node
    cur_node: ?NodeName = null,

    /// The hostname that this node should apply to
    host: ?[]const u8 = null,

    /// Argument to the current node
    arg: []const u8 = "",
    /// The number of arguments parsed so far on this node
    arg_count: usize = 0,
};

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

pub fn load(config: *Config, parser: *kdl.Parser, name: ?[]const u8, hostname: ?[]const u8) !void {
    var input_config: InputConfig = .{ .name = name };
    errdefer if (input_config.name) |input_name| {
        utils.gpa.free(input_name);
    };

    var state: ParseState = .{};

    var event = try parser.next();
    while (true) : (event = try parser.next()) {
        switch (event) {
            .node => |node| {
                try flushNode(&input_config, hostname, state);
                state = .{
                    .cur_node = std.meta.stringToEnum(NodeName, node.val) orelse {
                        return helpers.invalidNode(node.val);
                    },
                };
            },
            .arg => |arg| {
                state.arg = arg.val;
                state.arg_count += 1;
            },
            .prop => |prop| {
                if (mem.eql(u8, prop.key, "host")) {
                    state.host = prop.val;
                }
            },
            .child_block_begin => return helpers.unexpectedChildBlock(),
            .child_block_end => {
                try flushNode(&input_config, hostname, state);
                try config.input_configs.append(utils.gpa, input_config);
                return;
            },
            .invalid => return error.KdlInvalidConfig,
            .eof => return error.UnclosedBlock,
        }
    }
}

fn flushNode(input_config: *InputConfig, hostname: ?[]const u8, state: ParseState) !void {
    const name = state.cur_node orelse return;
    if (!helpers.hostMatches(state.host, hostname)) {
        log.debug("Skipping \"input.{s}\" (host mismatch)", .{@tagName(name)});
        return;
    }
    if (state.arg_count < 1) {
        return errMissingArg(name);
    }
    const val_str = utils.stripQuotes(state.arg);
    switch (name) {
        .accel_speed => {
            input_config.accel_speed = fmt.parseFloat(f64, val_str) catch {
                return errInvalidArg(name, val_str);
            };
            log.debug("input.accel_speed: {s}", .{val_str});
        },
        .scroll_button => {
            input_config.scroll_button = helpers.parseButton(val_str) orelse {
                return errInvalidArg(name, val_str);
            };
            log.debug("input.scroll_button: {s}", .{val_str});
        },
        .rotation => {
            input_config.rotation = fmt.parseInt(u32, val_str, 0) catch {
                return errInvalidArg(name, val_str);
            };
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
            // All these fields are optional enum types; use comptime to avoid repetition.
            // @typeInfo unwraps the optional to get the child enum type.
            const field_name = @tagName(cmd);
            const FieldType = @typeInfo(@TypeOf(@field(input_config.*, field_name))).optional.child;
            if (std.meta.stringToEnum(FieldType, val_str)) |val| {
                @field(input_config.*, field_name) = val;
                log.debug("input.{s}: {s}", .{ field_name, val_str });
            } else {
                return errInvalidArg(cmd, val_str);
            }
        },
    }
}

fn errInvalidArg(node_name: NodeName, node_value: []const u8) error{InvalidConfig} {
    log.err("Invalid \"input.{s}\" ({s})", .{ @tagName(node_name), node_value });
    return error.InvalidConfig;
}

fn errMissingArg(node_name: NodeName) error{InvalidConfig} {
    log.err("\"input.{s}\" missing argument", .{@tagName(node_name)});
    return error.InvalidConfig;
}

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

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

const utils = @import("../utils.zig");
const Config = @import("../Config.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.InputConfig);
