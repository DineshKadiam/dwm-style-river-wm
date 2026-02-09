// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const LibinputDevice = @This();

context: *Context,

river_libinput_device_v1: *river.LibinputDeviceV1,

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

pub fn destroy(input_device: *LibinputDevice) void {
    input_device.link.remove();
    utils.allocator.destroy(input_device);
}

fn riverLibinputDeviceV1Listener(river_libinput_device_v1: *river.LibinputDeviceV1, event: river.LibinputDeviceV1.Event, libinput_device: *LibinputDevice) void {
    assert(libinput_device.river_libinput_device_v1 == river_libinput_device_v1);
    const im = libinput_device.context.im;
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
                    // This event is only sent once when the object is created
                    assert(input_device.libinput_device == null);
                    input_device.libinput_device = libinput_device;
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

const std = @import("std");
const assert = std.debug.assert;

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

const log = std.log.scoped(.InputDevice);
