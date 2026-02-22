// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const InputManager = @This();

context: *Context,

river_input_manager_v1: *river.InputManagerV1,
river_libinput_config_v1: *river.LibinputConfigV1,

/// All input devices that we've been advertised
input_devices: wl.list.Head(InputDevice, .link),
/// All libinput devices that we've been advertised
/// Not necessarily the same length as input_devices
libinput_devices: wl.list.Head(LibinputDevice, .link),

pub fn create(context: *Context, river_input_manager_v1: *river.InputManagerV1, river_libinput_config_v1: *river.LibinputConfigV1) !*InputManager {
    log.debug("Creating new InputManager", .{});
    const im = try utils.gpa.create(InputManager);
    errdefer utils.gpa.destroy(im);

    im.* = .{
        .context = context,
        .river_input_manager_v1 = river_input_manager_v1,
        .river_libinput_config_v1 = river_libinput_config_v1,
        .input_devices = undefined, // we will initialize these shortly
        .libinput_devices = undefined,
    };

    im.input_devices.init();
    im.libinput_devices.init();

    im.river_input_manager_v1.setListener(*InputManager, inputManagerV1Listener, im);
    im.river_libinput_config_v1.setListener(*InputManager, libinputConfigV1Listener, im);

    return im;
}

pub fn destroy(im: *InputManager) void {
    im.river_input_manager_v1.destroy();
    im.river_libinput_config_v1.destroy();
    utils.gpa.destroy(im);
}

pub fn inputManagerV1Listener(river_input_manager_v1: *river.InputManagerV1, event: river.InputManagerV1.Event, im: *InputManager) void {
    assert(im.river_input_manager_v1 == river_input_manager_v1);
    switch (event) {
        .input_device => |ev| {
            const input_device = InputDevice.create(ev.id) catch @panic("Out of memory");
            im.input_devices.append(input_device);
        },
        .finished => {
            // TODO: Should call destroy on the river_input_manager_v1 and on this device,
            // but might need to make the globals optional so that we know when we can destroy this
            // object.
            log.debug("unhandled event: finished", .{});
        },
    }
}
pub fn libinputConfigV1Listener(river_libinput_config_v1: *river.LibinputConfigV1, event: river.LibinputConfigV1.Event, im: *InputManager) void {
    assert(im.river_libinput_config_v1 == river_libinput_config_v1);
    switch (event) {
        .libinput_device => |ev| {
            const libinput_device = LibinputDevice.create(im.context, ev.id) catch @panic("Out of memory");
            im.libinput_devices.append(libinput_device);
        },
        .finished => {
            // TODO: Should call destroy on the river_libinput_config_v1 and on this device,
            // but might need to make the globals optional so that we know when we can destroy this
            // object.
            log.debug("unhandled event: finished", .{});
        },
    }
}

const std = @import("std");
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("Context.zig");
const InputDevice = @import("InputDevice.zig");
const LibinputDevice = @import("LibinputDevice.zig");

const log = std.log.scoped(.InputManager);
