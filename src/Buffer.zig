// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const Buffer = @This();

width: u31,
height: u31,
stride: u31,

busy: bool,
size: u31,
data: ?[]align(std.heap.page_size_min) u8,

wl_buffer: *wl.Buffer,
pixman_image: *pixman.Image,

/// Used to add Buffers to a BufferPool
node: std.DoublyLinkedList.Node = .{},

pub fn init(shm: *wl.Shm, width: u31, height: u31) !Buffer {
    // We use argb8888
    const stride = width * 4;
    const size: u31 = height * stride;

    log.debug("initializing a new buffer with size {d}", .{size});

    // Open a memory-backed file with sealing enabled
    const fd = switch (builtin.target.os.tag) {
        .linux => try posix.memfd_createZ("beansprout-shm-buffer", os.linux.MFD.CLOEXEC | os.linux.MFD.ALLOW_SEALING),
        .freebsd => try posix.memfd_createZ("beansprout-shm-buffer", std.c.MFD.CLOEXEC | std.c.MFD.ALLOW_SEALING),
        else => @compileError("target OS not supported"),
    };
    defer posix.close(fd);

    // Try to allocate it to the desired size
    try posix.ftruncate(fd, size);

    // mmap the memory file for the pixman image
    const data = mem.bytesAsSlice(
        u8,
        try posix.mmap(null, size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0),
    );
    errdefer posix.munmap(data);

    // Seal the fd to prevent size changes. The compositor maps the same fd,
    // so without sealing it could access invalid memory if the client resized it.
    _ = try posix.fcntl(fd, seal.F_ADD_SEALS, seal.SEAL_GROW | seal.SEAL_SHRINK | seal.SEAL_SEAL);

    // Create a Wayland shm buffer for the same memory file.
    const pool = try shm.createPool(fd, size);
    defer pool.destroy();

    const wl_buffer = try pool.createBuffer(0, width, height, stride, .argb8888);
    errdefer wl_buffer.destroy();

    // Create the pixman image.
    const pixman_image = pixman.Image.createBitsNoClear(
        .a8r8g8b8,
        @as(c_int, @intCast(width)),
        @as(c_int, @intCast(height)),
        @as([*c]u32, @ptrCast(data)),
        @as(c_int, @intCast(stride)),
    ) orelse return error.NoPixmanImage;

    // The pixman image and the Wayland buffer now share the same memory.
    return .{
        .width = width,
        .height = height,
        .stride = stride,
        .busy = true,
        .size = size,
        .wl_buffer = wl_buffer,
        .data = data,
        .pixman_image = pixman_image,
    };
}

pub fn deinit(buffer: *Buffer) void {
    _ = buffer.pixman_image.unref();
    buffer.wl_buffer.destroy();
    if (buffer.data) |data| posix.munmap(data);
}

// We have to do this later because of the way init() works
pub fn setListener(buffer: *Buffer) void {
    buffer.wl_buffer.setListener(*Buffer, buffer_listener, buffer);
}

fn buffer_listener(_: *wl.Buffer, event: wl.Buffer.Event, buffer: *Buffer) void {
    switch (event) {
        .release => buffer.busy = false,
    }
}

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const os = std.os;
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const pixman = @import("pixman");

const utils = @import("utils.zig");

/// Sealing constants for memfd. Prevents the compositor from accessing
/// invalid memory by locking the fd's size after setup.
const seal = switch (builtin.target.os.tag) {
    .linux => struct {
        // Linux values are missing from stdlib right now,
        // just take the values from fcntl.h
        const F_ADD_SEALS: i32 = 1033;
        const SEAL_SEAL: usize = 0x0001;
        const SEAL_SHRINK: usize = 0x0002;
        const SEAL_GROW: usize = 0x0004;
    },
    .freebsd => struct {
        const F_ADD_SEALS = std.c.F.ADD_SEALS;
        const SEAL_SEAL = std.c.F.SEAL_SEAL;
        const SEAL_SHRINK = std.c.F.SEAL_SHRINK;
        const SEAL_GROW = std.c.F.SEAL_GROW;
    },
    else => @compileError("target OS not supported"),
};

const log = std.log.scoped(.Buffer);
