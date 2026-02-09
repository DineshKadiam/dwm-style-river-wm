// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const InputDevice = @This();

river_input_device_v1: *river.InputDeviceV1,

/// The LibinputDevice that corresponds to this same InputDevice.
/// This comes later (and from a separate river protocol) and
/// not all InputDevices are necessarily LibinputDevices, too,
/// so it's optional.
libinput_device: ?*LibinputDevice = null,

type: ?Type = null,
name: ?[]const u8 = null,

link: wl.list.Link,

pub fn create(river_input_device_v1: *river.InputDeviceV1) !*InputDevice {
    const input_device = try utils.allocator.create(InputDevice);
    errdefer input_device.destroy();

    input_device.* = .{
        .river_input_device_v1 = river_input_device_v1,
        .link = undefined, // handled by the wl.List
    };

    input_device.river_input_device_v1.setListener(
        *InputDevice,
        riverInputDeviceV1Listener,
        input_device,
    );

    return input_device;
}

pub fn destroy(input_device: *InputDevice) void {
    input_device.link.remove();
    utils.allocator.destroy(input_device);
}

fn riverInputDeviceV1Listener(river_input_device_v1: *river.InputDeviceV1, event: river.InputDeviceV1.Event, input_device: *InputDevice) void {
    assert(input_device.river_input_device_v1 == river_input_device_v1);
    switch (event) {
        .removed => {
            river_input_device_v1.destroy();
            input_device.destroy();
        },
        .type => |ev| {
            // This event is only sent once when the object is created
            assert(input_device.type == null);
            input_device.type = ev.type;
        },
        .name => |ev| {
            // This event is only sent once when the object is created
            assert(input_device.name == null);
            input_device.name = mem.span(ev.name);
        },
    }
}

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const Type = river.InputDeviceV1.Type;

const utils = @import("utils.zig");
const Context = @import("Context.zig");
const LibinputDevice = @import("LibinputDevice.zig");

const log = std.log.scoped(.InputDevice);
