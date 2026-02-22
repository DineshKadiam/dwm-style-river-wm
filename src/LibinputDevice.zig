// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

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

capabilities: Capabilities = .{},
state: CurrentState = .{},

link: wl.list.Link,

pub const Capabilities = struct {
    send_events: SendEventsModes = .{},
    /// The number of fingers supported for tap-to-click/drag.
    /// If finger_count is 0, tap-to-click and drag are unsupported.
    tap: u31 = 0,
    /// The number of fingers supported for three/four finger drag.
    /// If finger_count is less than 3, three finger drag is unsupported.
    three_finger_drag: u31 = 0,
    /// A calibration matrix is supported if the supported argument is non-zero.
    calibration_matrix: bool = false,
    accel_profiles: ?AccelProfiles = null,
    natural_scroll: bool = false,
    left_handed: bool = false,
    click_methods: ?ClickMethods = null,
    middle_emulation: bool = false,
    scroll_methods: ?ScrollMethods = null,
    dwt: bool = false,
    dwtp: bool = false,
    rotation: bool = false,
};

pub const CurrentState = struct {
    send_events: ?SendEventsModes = null,
    tap: ?TapState = null,
    tap_button_map: ?TapButtonMap = null,
    drag: ?DragState = null,
    drag_lock: ?DragLockState = null,
    three_finger_drag: ?ThreeFingerDragState = null,
    calibration_matrix: ?[]f32 = null,
    accel_profile: ?AccelProfile = null,
    accel_speed: ?f64 = null,
    natural_scroll: ?NaturalScrollState = null,
    left_handed: ?LeftHandedState = null,
    click_method: ?ClickMethod = null,
    clickfinger_button_map: ?ClickfingerButtonMap = null,
    middle_emulation: ?MiddleEmulationState = null,
    scroll_method: ?ScrollMethod = null,
    /// Supported if scroll_methods.on_button_down is supported.
    scroll_button: ?u32 = null,
    /// Supported if scroll_methods.on_button_down is supported.
    scroll_button_lock: ?ScrollButtonLockState = null,
    dwt: ?DwtState = null,
    dwtp: ?DwtpState = null,
    rotation: ?u32 = null,
};

pub fn create(context: *Context, river_libinput_device_v1: *river.LibinputDeviceV1) !*LibinputDevice {
    const libinput_device = try utils.gpa.create(LibinputDevice);
    errdefer utils.gpa.destroy(libinput_device);

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
    utils.gpa.destroy(libinput_device);
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
                    input_device.libinput_device = libinput_device;
                    libinput_device.input_device = input_device;
                    log.info("input dev {} is associated to libinput {}", .{ river_libinput_device_v1.getId(), river_input_device_v1.getId() });
                }
            }
        },
        .send_events_support => |ev| libinput_device.capabilities.send_events = ev.modes,
        .send_events_current => |ev| libinput_device.state.send_events = ev.mode,
        .tap_support => |ev| libinput_device.capabilities.tap = @intCast(ev.finger_count),
        .tap_current => |ev| libinput_device.state.tap = ev.state,
        .tap_button_map_current => |ev| libinput_device.state.tap_button_map = ev.button_map,
        .drag_current => |ev| libinput_device.state.drag = ev.state,
        .drag_lock_current => |ev| libinput_device.state.drag_lock = ev.state,
        .three_finger_drag_support => |ev| libinput_device.capabilities.three_finger_drag = @intCast(ev.finger_count),
        .three_finger_drag_current => |ev| libinput_device.state.three_finger_drag = ev.state,
        .calibration_matrix_support => |ev| libinput_device.capabilities.calibration_matrix = ev.supported != 0,
        .calibration_matrix_current => |ev| libinput_device.state.calibration_matrix = ev.matrix.slice(f32),
        .accel_profiles_support => |ev| libinput_device.capabilities.accel_profiles = ev.profiles,
        .accel_profile_current => |ev| libinput_device.state.accel_profile = ev.profile,
        .accel_speed_current => |ev| libinput_device.state.accel_speed = ev.speed.slice(f64)[0],
        .natural_scroll_support => |ev| libinput_device.capabilities.natural_scroll = ev.supported != 0,
        .natural_scroll_current => |ev| libinput_device.state.natural_scroll = ev.state,
        .left_handed_support => |ev| libinput_device.capabilities.left_handed = ev.supported != 0,
        .left_handed_current => |ev| libinput_device.state.left_handed = ev.state,
        .click_method_support => |ev| libinput_device.capabilities.click_methods = ev.methods,
        .click_method_current => |ev| libinput_device.state.click_method = ev.method,
        .clickfinger_button_map_current => |ev| libinput_device.state.clickfinger_button_map = ev.button_map,
        .middle_emulation_support => |ev| libinput_device.capabilities.middle_emulation = ev.supported != 0,
        .middle_emulation_current => |ev| libinput_device.state.middle_emulation = ev.state,
        .scroll_method_support => |ev| libinput_device.capabilities.scroll_methods = ev.methods,
        .scroll_method_current => |ev| libinput_device.state.scroll_method = ev.method,
        .scroll_button_current => |ev| libinput_device.state.scroll_button = ev.button,
        .scroll_button_lock_current => |ev| libinput_device.state.scroll_button_lock = ev.state,
        .dwt_support => |ev| libinput_device.capabilities.dwt = ev.supported != 0,
        .dwt_current => |ev| libinput_device.state.dwt = ev.state,
        .dwtp_support => |ev| libinput_device.capabilities.dwtp = ev.supported != 0,
        .dwtp_current => |ev| libinput_device.state.dwtp = ev.state,
        .rotation_support => |ev| libinput_device.capabilities.rotation = ev.supported != 0,
        .rotation_current => |ev| libinput_device.state.rotation = ev.angle,
        else => |ev| {
            // We don't keep track of any default states right now
            log.debug("unhandled event: {s}", .{@tagName(ev)});
        },
    }
}

pub fn manage(libinput_device: *LibinputDevice) void {
    if (libinput_device.should_manage) {
        if (libinput_device.input_device) |input_device| {
            if (input_device.name) |_| {
                libinput_device.should_manage = false;
                libinput_device.applyInputConfigs();
            }
        }
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

        if (@as(u32, @bitCast(libinput_device.capabilities.send_events)) != 0) {
            log.debug("Applying send events config to {s}", .{device_name});
            if (input_config.send_events) |val| {
                const mode: SendEventsModes = @bitCast(@as(u32, @intCast(@intFromEnum(val))));
                const mode_bits: u32 = @bitCast(mode);
                const support_bits: u32 = @bitCast(libinput_device.capabilities.send_events);
                if (mode_bits == 0 or mode_bits & support_bits == mode_bits) {
                    applyResult(dev.setSendEvents(mode));
                }
            }
        }

        if (libinput_device.capabilities.tap > 0) {
            log.debug("Applying tap config to {s}", .{device_name});
            if (input_config.tap) |val| applyResult(dev.setTap(val));
            if (input_config.tap_button_map) |val| applyResult(dev.setTapButtonMap(val));
            if (input_config.drag) |val| applyResult(dev.setDrag(val));
            if (input_config.drag_lock) |val| applyResult(dev.setDragLock(val));
        }

        if (libinput_device.capabilities.three_finger_drag >= 3) {
            log.debug("Applying tfd config to {s}", .{device_name});
            if (input_config.three_finger_drag) |val| applyResult(dev.setThreeFingerDrag(val));
        }

        if (libinput_device.capabilities.accel_profiles) |support| {
            log.debug("Applying accel profile config to {s}", .{device_name});
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

        if (libinput_device.capabilities.natural_scroll) {
            log.debug("Applying natural scroll config to {s}", .{device_name});
            if (input_config.natural_scroll) |val| applyResult(dev.setNaturalScroll(val));
        }

        if (libinput_device.capabilities.left_handed) {
            log.debug("Applying left handed config to {s}", .{device_name});
            if (input_config.left_handed) |val| applyResult(dev.setLeftHanded(val));
        }

        if (libinput_device.capabilities.click_methods) |support| {
            log.debug("Applying click methods config to {s}", .{device_name});
            if (input_config.click_method) |val| {
                if (isSupported(ClickMethod, ClickMethods, val, support)) {
                    applyResult(dev.setClickMethod(val));
                }
            }
            if (input_config.clickfinger_button_map) |val| applyResult(dev.setClickfingerButtonMap(val));
        }

        if (libinput_device.capabilities.middle_emulation) {
            log.debug("Applying middle emulation config to {s}", .{device_name});
            if (input_config.middle_emulation) |val| applyResult(dev.setMiddleEmulation(val));
        }

        if (libinput_device.capabilities.scroll_methods) |support| {
            log.debug("Applying scroll methods config to {s}", .{device_name});
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

        if (libinput_device.capabilities.dwt) {
            log.debug("Applying dwt config to {s}", .{device_name});
            if (input_config.dwt) |val| applyResult(dev.setDwt(val));
        }

        if (libinput_device.capabilities.dwtp) {
            log.debug("Applying dwtp config to {s}", .{device_name});
            if (input_config.dwtp) |val| applyResult(dev.setDwtp(val));
        }

        if (libinput_device.capabilities.rotation) {
            log.debug("Applying rotation config to {s}", .{device_name});
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
        fn resultListener(libinput_result: *river.LibinputResultV1, event: river.LibinputResultV1.Event, _: ?*anyopaque) void {
            switch (event) {
                .success => {},
                .unsupported => log.debug("Config option unsupported by device", .{}),
                .invalid => log.warn("Invalid config value for device", .{}),
            }
            libinput_result.destroy();
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
