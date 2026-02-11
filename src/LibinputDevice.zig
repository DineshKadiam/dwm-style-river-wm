// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const LibinputDevice = @This();

context: *Context,

river_libinput_device_v1: *river.LibinputDeviceV1,

/// The river_input_device_v1 associated with this Libinput device.
input_device: ?*InputDevice = null,

/// Set to true whenever we want to apply input configurations.
/// At first, we wait for the first manage_start because it's after all of the
/// _support events. After that, it's set to true whenever the config is
/// reloaded.
should_manage: bool = true,

send_events_support: SendEventsModes = .{},
send_events_current: ?SendEventsModes = null,

/// The number of fingers supported for tap-to-click/drag.
/// If finger_count is 0, tap-to-click and drag are unsupported.
tap_support: u31 = 0,
tap_current: ?TapState = null,

tap_button_map_current: ?TapButtonMap = null,

drag_current: ?DragState = null,

drag_lock_current: ?DragLockState = null,

/// The number of fingers supported for three/four finger drag.
/// If finger_count is less than 3, three finger drag is unsupported.
three_finger_drag_support: u31 = 0,
three_finger_drag_current: ?ThreeFingerDragState = null,

/// A calibration matrix is supported if the supported argument is non-zero.
calibration_matrix_support: bool = false,
calibration_matrix_current: ?[]f32 = null,

accel_profiles_support: ?AccelProfiles = null,
accel_profile_current: ?AccelProfile = null,

accel_speed_current: ?f64 = null,

natural_scroll_support: bool = false,
natural_scroll_current: ?NaturalScrollState = null,

left_handed_support: bool = false,
left_handed_current: ?LeftHandedState = null,

click_method_support: ?ClickMethods = null,
click_method_current: ?ClickMethod = null,

clickfinger_button_map_current: ?ClickfingerButtonMap = null,

middle_emulation_support: bool = false,
middle_emulation_current: ?MiddleEmulationState = null,

scroll_method_support: ?ScrollMethods = null,
scroll_method_current: ?ScrollMethod = null,
/// Supported if scroll_methods.on_button_down is supported.
scroll_button_current: ?u32 = null,
/// Supported if scroll_methods.on_button_down is supported.
scroll_button_lock_current: ?ScrollButtonLockState = null,

dwt_support: bool = false,
dwt_current: ?DwtState = null,

dwtp_support: bool = false,
dwtp_current: ?DwtpState = null,

rotation_support: bool = false,
rotation_current: ?u32 = null,

link: wl.list.Link,

pub fn create(context: *Context, river_libinput_device_v1: *river.LibinputDeviceV1) !*LibinputDevice {
    const libinput_device = try utils.allocator.create(LibinputDevice);
    errdefer libinput_device.destroy();

    libinput_device.* = .{
        .context = context,
        .river_libinput_device_v1 = river_libinput_device_v1,
        .link = undefined, // handled by the wl.List
    };

    libinput_device.river_libinput_device_v1.setListener(
        *LibinputDevice,
        riverLibinputDeviceV1Listener,
        libinput_device,
    );

    return libinput_device;
}

pub fn destroy(libinput_device: *LibinputDevice) void {
    if (libinput_device.input_device) |input_device| {
        input_device.libinput_device = null;
    }
    libinput_device.link.remove();
    utils.allocator.destroy(libinput_device);
}

fn riverLibinputDeviceV1Listener(river_libinput_device_v1: *river.LibinputDeviceV1, event: river.LibinputDeviceV1.Event, libinput_device: *LibinputDevice) void {
    assert(libinput_device.river_libinput_device_v1 == river_libinput_device_v1);
    const im = libinput_device.context.im;
    log.debug("bwbuhse: {s} for {d}", .{ @tagName(event), river_libinput_device_v1.getId() });
    switch (event) {
        .removed => {
            river_libinput_device_v1.destroy();
            libinput_device.destroy();
        },
        .input_device => |ev| {
            const river_input_device_v1 = ev.device.?;
            var it = im.input_devices.iterator(.forward);
            while (it.next()) |input_device| {
                if (input_device.river_input_device_v1 == river_input_device_v1) {
                    input_device.libinput_device = libinput_device;
                    libinput_device.input_device = input_device;
                    log.info("input dev {} is associated to libinput {}", .{ river_libinput_device_v1.getId(), river_input_device_v1.getId() });
                }
            }
        },
        .send_events_support => |ev| libinput_device.send_events_support = ev.modes,
        .send_events_current => |ev| libinput_device.send_events_current = ev.mode,
        .tap_support => |ev| libinput_device.tap_support = @intCast(ev.finger_count),
        .tap_current => |ev| libinput_device.tap_current = ev.state,
        .tap_button_map_current => |ev| libinput_device.tap_button_map_current = ev.button_map,
        .drag_current => |ev| libinput_device.drag_current = ev.state,
        .drag_lock_current => |ev| libinput_device.drag_lock_current = ev.state,
        .three_finger_drag_support => |ev| libinput_device.three_finger_drag_support = @intCast(ev.finger_count),
        .three_finger_drag_current => |ev| libinput_device.three_finger_drag_current = ev.state,
        .calibration_matrix_support => |ev| libinput_device.calibration_matrix_support = ev.supported != 0,
        .calibration_matrix_current => |ev| libinput_device.calibration_matrix_current = ev.matrix.slice(f32),
        .accel_profiles_support => |ev| libinput_device.accel_profiles_support = ev.profiles,
        .accel_profile_current => |ev| libinput_device.accel_profile_current = ev.profile,
        .accel_speed_current => |ev| libinput_device.accel_speed_current = ev.speed.slice(f64)[0],
        .natural_scroll_support => |ev| libinput_device.natural_scroll_support = ev.supported != 0,
        .natural_scroll_current => |ev| libinput_device.natural_scroll_current = ev.state,
        .left_handed_support => |ev| libinput_device.left_handed_support = ev.supported != 0,
        .left_handed_current => |ev| libinput_device.left_handed_current = ev.state,
        .click_method_support => |ev| libinput_device.click_method_support = ev.methods,
        .click_method_current => |ev| libinput_device.click_method_current = ev.method,
        .clickfinger_button_map_current => |ev| libinput_device.clickfinger_button_map_current = ev.button_map,
        .middle_emulation_support => |ev| libinput_device.middle_emulation_support = ev.supported != 0,
        .middle_emulation_current => |ev| libinput_device.middle_emulation_current = ev.state,
        .scroll_method_support => |ev| libinput_device.scroll_method_support = ev.methods,
        .scroll_method_current => |ev| libinput_device.scroll_method_current = ev.method,
        .scroll_button_current => |ev| libinput_device.scroll_button_current = ev.button,
        .scroll_button_lock_current => |ev| libinput_device.scroll_button_lock_current = ev.state,
        .dwt_support => |ev| libinput_device.dwt_support = ev.supported != 0,
        .dwt_current => |ev| libinput_device.dwt_current = ev.state,
        .dwtp_support => |ev| libinput_device.dwtp_support = ev.supported != 0,
        .dwtp_current => |ev| libinput_device.dwtp_current = ev.state,
        .rotation_support => |ev| libinput_device.rotation_support = ev.supported != 0,
        .rotation_current => |ev| libinput_device.rotation_current = ev.angle,
        else => |ev| {
            // We don't keep track of any default states right now
            log.debug("unhandled event: {s}", .{@tagName(ev)});
        },
    }
}

pub fn manage(libinput_device: *LibinputDevice) void {
    if (libinput_device.should_manage) {
        libinput_device.should_manage = false;
        libinput_device.applyInputConfigs();
    }
}

pub fn applyInputConfigs(libinput_device: *LibinputDevice) void {
    const input_device = libinput_device.input_device orelse return;
    const device_name = input_device.name orelse return;
    const config = libinput_device.context.config;
    const dev = libinput_device.river_libinput_device_v1;

    for (config.input_configs.items) |input_config| {
        if (input_config.name) |config_name| {
            if (!mem.eql(u8, config_name, device_name)) continue;
        }

        log.debug("Applying input config to {s}", .{device_name});

        if (@as(u32, @bitCast(libinput_device.send_events_support)) != 0) {
            if (input_config.send_events) |val| {
                const mode: SendEventsModes = @bitCast(@as(u32, @intCast(@intFromEnum(val))));
                const mode_bits: u32 = @bitCast(mode);
                const support_bits: u32 = @bitCast(libinput_device.send_events_support);
                if (mode_bits == 0 or mode_bits & support_bits == mode_bits) {
                    applyResult(dev.setSendEvents(mode));
                }
            }
        }

        if (libinput_device.tap_support > 0) {
            if (input_config.tap) |val| applyResult(dev.setTap(val));
            if (input_config.tap_button_map) |val| applyResult(dev.setTapButtonMap(val));
            if (input_config.drag) |val| applyResult(dev.setDrag(val));
            if (input_config.drag_lock) |val| applyResult(dev.setDragLock(val));
        }

        if (libinput_device.three_finger_drag_support >= 3) {
            if (input_config.three_finger_drag) |val| applyResult(dev.setThreeFingerDrag(val));
        }

        if (libinput_device.accel_profiles_support) |support| {
            if (input_config.accel_profile) |val| {
                if (isSupported(AccelProfile, AccelProfiles, val, support)) {
                    applyResult(dev.setAccelProfile(val));
                }
            }
            if (input_config.accel_speed) |speed| {
                var speed_val: f64 = speed;
                var speed_array: wl.Array = .{
                    .size = @sizeOf(f64),
                    .alloc = @sizeOf(f64),
                    .data = @ptrCast(&speed_val),
                };
                applyResult(dev.setAccelSpeed(&speed_array));
            }
        }

        if (libinput_device.natural_scroll_support) {
            if (input_config.natural_scroll) |val| applyResult(dev.setNaturalScroll(val));
        }

        if (libinput_device.left_handed_support) {
            if (input_config.left_handed) |val| applyResult(dev.setLeftHanded(val));
        }

        if (libinput_device.click_method_support) |support| {
            if (input_config.click_method) |val| {
                if (isSupported(ClickMethod, ClickMethods, val, support)) {
                    applyResult(dev.setClickMethod(val));
                }
            }
            if (input_config.clickfinger_button_map) |val| applyResult(dev.setClickfingerButtonMap(val));
        }

        if (libinput_device.middle_emulation_support) {
            if (input_config.middle_emulation) |val| applyResult(dev.setMiddleEmulation(val));
        }

        if (libinput_device.scroll_method_support) |support| {
            if (input_config.scroll_method) |val| {
                if (isSupported(ScrollMethod, ScrollMethods, val, support)) {
                    applyResult(dev.setScrollMethod(val));
                }
            }
            if (support.on_button_down) {
                if (input_config.scroll_button) |val| applyResult(dev.setScrollButton(val));
                if (input_config.scroll_button_lock) |val| applyResult(dev.setScrollButtonLock(val));
            }
        }

        if (libinput_device.dwt_support) {
            if (input_config.dwt) |val| applyResult(dev.setDwt(val));
        }

        if (libinput_device.dwtp_support) {
            if (input_config.dwtp) |val| applyResult(dev.setDwtp(val));
        }

        if (libinput_device.rotation_support) {
            if (input_config.rotation) |val| applyResult(dev.setRotation(val));
        }
    }
}

fn isSupported(comptime E: type, comptime S: type, val: E, support: S) bool {
    const int_val: u32 = @intCast(@intFromEnum(val));
    if (int_val == 0) return true;
    const support_bits: u32 = @bitCast(support);
    return int_val & support_bits == int_val;
}

/// Handles the result of a set_* request by setting a listener to
/// log any unsupported or invalid config responses from the compositor.
fn applyResult(result: anyerror!*river.LibinputResultV1) void {
    const Listener = struct {
        fn resultListener(_: *river.LibinputResultV1, event: river.LibinputResultV1.Event, _: ?*anyopaque) void {
            switch (event) {
                .success => {},
                .unsupported => log.debug("Config option unsupported by device", .{}),
                .invalid => log.warn("Invalid config value for device", .{}),
            }
        }
    };

    const r = result catch |err| {
        log.err("Failed to send input config request: {}", .{err});
        return;
    };
    // We don't need any userdata in this listener
    r.setListener(?*anyopaque, Listener.resultListener, null);
}

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const AccelProfile = river.LibinputDeviceV1.AccelProfile;
const AccelProfiles = river.LibinputDeviceV1.AccelProfiles;
const ClickfingerButtonMap = river.LibinputDeviceV1.ClickfingerButtonMap;
const ClickMethod = river.LibinputDeviceV1.ClickMethod;
const ClickMethods = river.LibinputDeviceV1.ClickMethods;
const DragLockState = river.LibinputDeviceV1.DragLockState;
const DragState = river.LibinputDeviceV1.DragState;
const DwtState = river.LibinputDeviceV1.DwtState;
const DwtpState = river.LibinputDeviceV1.DwtpState;
const LeftHandedState = river.LibinputDeviceV1.LeftHandedState;
const MiddleEmulationState = river.LibinputDeviceV1.MiddleEmulationState;
const NaturalScrollState = river.LibinputDeviceV1.NaturalScrollState;
const ScrollButtonLockState = river.LibinputDeviceV1.ScrollButtonLockState;
const ScrollMethod = river.LibinputDeviceV1.ScrollMethod;
const ScrollMethods = river.LibinputDeviceV1.ScrollMethods;
const SendEventsModes = river.LibinputDeviceV1.SendEventsModes;
const TapButtonMap = river.LibinputDeviceV1.TapButtonMap;
const TapState = river.LibinputDeviceV1.TapState;
const ThreeFingerDragState = river.LibinputDeviceV1.ThreeFingerDragState;

const utils = @import("utils.zig");
const Context = @import("Context.zig");
const InputDevice = @import("InputDevice.zig");

const log = std.log.scoped(.InputDevice);
