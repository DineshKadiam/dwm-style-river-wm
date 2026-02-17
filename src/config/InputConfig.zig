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
    errdefer if (input_config.name) |n| utils.gpa.free(n);

    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                const node_name = std.meta.stringToEnum(NodeName, node.name);
                if (node_name) |tag| {
                    if (!helpers.hostMatches(node, parser, hostname)) {
                        log.debug("Skipping \"input.{s}\" (host mismatch)", .{@tagName(tag)});
                        continue;
                    }
                    const val_str = utils.stripQuotes(node.arg(parser, 0) orelse {
                        log.warn("\"input.{s}\" missing value argument. Ignoring", .{@tagName(tag)});
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
                            const button = helpers.parseButton(val_str) orelse {
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
                    helpers.logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => {
                try helpers.skipChildBlock(parser);
            },
            .child_block_end => {
                try config.input_configs.append(utils.gpa, input_config);
                return;
            },
        }
    }
}

inline fn logWarnInvalidNodeArg(node_name: NodeName, node_value: []const u8) void {
    log.warn("Invalid \"input.{s}\" ({s}). Ignoring", .{ @tagName(node_name), node_value });
}

const std = @import("std");
const fmt = std.fmt;

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
