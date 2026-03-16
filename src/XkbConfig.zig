// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const XkbConfig = @This();

context: *Context,

xkb_config_v1: *river.XkbConfigV1,

/// The keymap object sent to the compositor, if any.
/// Only valid to use with set_keymap once xkb_keymap_confirmed is true.
xkb_keymap_v1: ?*river.XkbKeymapV1 = null,
/// True once xkb_keymap_v1 has received the success event.
xkb_keymap_confirmed: bool = false,

/// Tracked keyboards so we can apply keymaps to all of them.
keyboards: wl.list.Head(Keyboard, .link),

const Keyboard = struct {
    xkb_keyboard_v1: *river.XkbKeyboardV1,
    xkb_config: *XkbConfig,
    link: wl.list.Link,

    fn create(xkb_keyboard_v1: *river.XkbKeyboardV1, xkb_config: *XkbConfig) !*Keyboard {
        const keyboard = try utils.gpa.create(Keyboard);
        keyboard.* = .{
            .xkb_keyboard_v1 = xkb_keyboard_v1,
            .xkb_config = xkb_config,
            .link = undefined,
        };
        xkb_keyboard_v1.setListener(*Keyboard, keyboardListener, keyboard);
        xkb_config.keyboards.append(keyboard);

        // Only apply if the keymap has been confirmed via the success event.
        // Applying an unconfirmed keymap is a protocol error.
        if (xkb_config.xkb_keymap_confirmed) {
            xkb_keyboard_v1.setKeymap(xkb_config.xkb_keymap_v1.?);
        }

        return keyboard;
    }

    fn destroy(keyboard: *Keyboard) void {
        keyboard.link.remove();
        keyboard.xkb_keyboard_v1.destroy();
        utils.gpa.destroy(keyboard);
    }

    fn keyboardListener(_: *river.XkbKeyboardV1, event: river.XkbKeyboardV1.Event, keyboard: *Keyboard) void {
        switch (event) {
            .removed => keyboard.destroy(),
            .input_device, .layout, .capslock_enabled, .capslock_disabled, .numlock_enabled, .numlock_disabled => {},
        }
    }
};

pub fn create(context: *Context, xkb_config_v1: *river.XkbConfigV1) !*XkbConfig {
    const xkb_config = try utils.gpa.create(XkbConfig);
    errdefer utils.gpa.destroy(xkb_config);

    xkb_config.* = .{
        .context = context,
        .xkb_config_v1 = xkb_config_v1,
        .keyboards = undefined, // we will initialize this shortly
    };
    xkb_config.keyboards.init();

    xkb_config_v1.setListener(*XkbConfig, riverXkbConfigV1Listener, xkb_config);

    return xkb_config;
}

pub fn destroy(xkb_config: *XkbConfig) void {
    var it = xkb_config.keyboards.safeIterator(.forward);
    while (it.next()) |keyboard| {
        keyboard.destroy();
    }
    if (xkb_config.xkb_keymap_v1) |keymap_v1| {
        keymap_v1.destroy();
    }
    xkb_config.xkb_config_v1.destroy();
    utils.gpa.destroy(xkb_config);
}

fn riverXkbConfigV1Listener(xkb_config_v1: *river.XkbConfigV1, event: river.XkbConfigV1.Event, xkb_config: *XkbConfig) void {
    assert(xkb_config.xkb_config_v1 == xkb_config_v1);
    switch (event) {
        .finished => {
            xkb_config.context.xkb_config = null;
            xkb_config.destroy();
        },
        .xkb_keyboard => |ev| {
            _ = Keyboard.create(ev.id, xkb_config) catch |e| {
                log.err("Failed to create keyboard: {}", .{e});
                return;
            };
        },
    }
}

/// Build a keymap from the config's keyboard_layout settings and send it
/// to the compositor. On success, apply it to all tracked keyboards.
pub fn applyKeyboardLayout(xkb_config: *XkbConfig) void {
    const layout_config = xkb_config.context.config.keyboard_layout;

    // If nothing is configured and we haven't previously applied a custom keymap,
    // there's nothing to do. If we did previously apply one, fall through to apply
    // the system default, reverting the custom keymap.
    if (layout_config.rules == null and
        layout_config.model == null and
        layout_config.layout == null and
        layout_config.variant == null and
        layout_config.options == null and
        !xkb_config.xkb_keymap_confirmed)
    {
        return;
    }

    // Convert ?[]const u8 to ?[*:0]const u8 for xkbcommon
    const rules_z = dupeZOrNull(layout_config.rules);
    defer if (rules_z) |s| utils.gpa.free(s);
    const model_z = dupeZOrNull(layout_config.model);
    defer if (model_z) |s| utils.gpa.free(s);
    const layout_z = dupeZOrNull(layout_config.layout);
    defer if (layout_z) |s| utils.gpa.free(s);
    const variant_z = dupeZOrNull(layout_config.variant);
    defer if (variant_z) |s| utils.gpa.free(s);
    const options_z = dupeZOrNull(layout_config.options);
    defer if (options_z) |s| utils.gpa.free(s);

    const names = xkbcommon.RuleNames{
        .rules = if (rules_z) |s| s.ptr else null,
        .model = if (model_z) |s| s.ptr else null,
        .layout = if (layout_z) |s| s.ptr else null,
        .variant = if (variant_z) |s| s.ptr else null,
        .options = if (options_z) |s| s.ptr else null,
    };

    // Create xkb context and keymap
    const xkb_context = xkbcommon.Context.new(.no_flags) orelse {
        log.err("Failed to create XKB context", .{});
        return;
    };
    defer xkb_context.unref();

    const keymap = xkbcommon.Keymap.newFromNames(xkb_context, &names, .no_flags) orelse {
        log.err("Invalid keyboard layout configuration", .{});
        return;
    };
    defer keymap.unref();

    // Serialize keymap to string
    const keymap_str = keymap.getAsString(.text_v1) orelse {
        log.err("Failed to serialize keymap", .{});
        return;
    };
    const keymap_len = mem.len(keymap_str);
    // Include the null terminator in the buffer sent to the compositor
    const keymap_buf = keymap_str[0 .. keymap_len + 1];
    defer utils.gpa.free(keymap_buf);

    // Create memfd and write keymap
    const fd = switch (builtin.target.os.tag) {
        .linux => posix.memfd_createZ("beansprout-xkb-keymap", os.linux.MFD.CLOEXEC | os.linux.MFD.ALLOW_SEALING),
        .freebsd => posix.memfd_createZ("beansprout-xkb-keymap", std.c.MFD.CLOEXEC | std.c.MFD.ALLOW_SEALING),
        else => @compileError("target OS not supported"),
    } catch |err| {
        log.err("Failed to create memfd: {}", .{err});
        return;
    };
    defer posix.close(fd);

    _ = posix.write(fd, keymap_buf) catch |err| {
        log.err("Failed to write keymap to fd: {}", .{err});
        return;
    };

    // Send to compositor
    const keymap_v1 = xkb_config.xkb_config_v1.createKeymap(fd, .text_v1) catch |err| {
        log.err("Failed to create keymap object: {}", .{err});
        return;
    };

    // Destroy old keymap if any
    if (xkb_config.xkb_keymap_v1) |old| {
        old.destroy();
    }

    xkb_config.xkb_keymap_confirmed = false;
    keymap_v1.setListener(*XkbConfig, keymapListener, xkb_config);
    xkb_config.xkb_keymap_v1 = keymap_v1;
}

fn keymapListener(_: *river.XkbKeymapV1, event: river.XkbKeymapV1.Event, xkb_config: *XkbConfig) void {
    switch (event) {
        .success => {
            log.info("Keyboard layout applied successfully", .{});
            xkb_config.xkb_keymap_confirmed = true;
            // Apply to all tracked keyboards
            var it = xkb_config.keyboards.iterator(.forward);
            while (it.next()) |keyboard| {
                keyboard.xkb_keyboard_v1.setKeymap(xkb_config.xkb_keymap_v1.?);
            }
        },
        .failure => |ev| {
            log.err("Failed to apply keyboard layout: {s}", .{ev.error_msg});
            xkb_config.xkb_keymap_confirmed = false;
            if (xkb_config.xkb_keymap_v1) |keymap| {
                keymap.destroy();
                xkb_config.xkb_keymap_v1 = null;
            }
        },
    }
}

fn dupeZOrNull(opt: ?[]const u8) ?[:0]u8 {
    const slice = opt orelse return null;
    return utils.gpa.dupeZ(u8, slice) catch {
        log.err("Out of memory", .{});
        return null;
    };
}

const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;
const os = std.os;
const posix = std.posix;
const assert = std.debug.assert;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const xkbcommon = @import("xkbcommon");

const utils = @import("utils.zig");
const Context = @import("Context.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.XkbConfig);
