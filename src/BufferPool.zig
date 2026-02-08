// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

// Borrowed and adapted from https://git.sr.ht/~leon_plickat/wayprompt
const BufferPool = @This();

/// The amount of buffers per surface we consider the reasonable upper limit.
/// Some compositors sometimes tripple-buffer, so three seems to be ok.
/// Note that we can absolutely work with higher buffer numbers if needed,
/// however we consider that to be an anomaly and therefore do not want to
/// keep all those extra buffers around if we can avoid it, as to not have
/// unecessary memory overhead.
const max_buffer_multiplicity = 3;

/// The buffers. This is a linked list and not an array list, because we
/// need stable pointers for the listener of the wl_buffer object.
buffers: DoublyLinkedList = .{},
len: usize = 0,

/// Number of surfaces sharing this pool, used to determine when to cull extra buffers.
/// Each surface is allowed up to max_buffer_multiplicity buffers.
surface_count: usize = 0,

/// Deinit the buffer pool, destroying all buffers and freeing all memory.
pub fn deinit(buffer_pool: *BufferPool) void {
    var it = buffer_pool.buffers.first;
    while (it) |node| {
        // Advance before destroying, since node is embedded in buffer
        it = node.next;
        const buffer: *Buffer = @fieldParentPtr("node", node);
        buffer.deinit();
        utils.allocator.destroy(buffer);
    }
}

/// Get a buffer with the specified dimensions. If possible, an idle buffer is
/// reused, otherwise a new one is created.
pub fn nextBuffer(buffer_pool: *BufferPool, wl_shm: *wl.Shm, width: u31, height: u31) !*Buffer {
    log.debug("looking for buffer with dimensions {}x{}, total existing buffers: {}", .{ width, height, buffer_pool.len });
    defer {
        // Clear up extra buffers
        if (buffer_pool.len > max_buffer_multiplicity * buffer_pool.surface_count) {
            buffer_pool.cullBuffers();
        }
    }
    if (try buffer_pool.findSuitableBuffer(wl_shm, width, height)) |buffer| {
        return buffer;
    } else {
        return try buffer_pool.newBuffer(wl_shm, width, height);
    }
}

/// Get the first free buffer with the specified dimensions.
/// If there are no free buffers with the right dimensions, re-init a free buffer that
/// has other dimensions. If no free buffer exists at all, return null.
fn findSuitableBuffer(buffer_pool: *BufferPool, wl_shm: *wl.Shm, width: u31, height: u31) !?*Buffer {
    var it = buffer_pool.buffers.first;
    var first_unbusy_buffer: ?*Buffer = null;
    while (it) |node| : (it = node.next) {
        const buffer: *Buffer = @fieldParentPtr("node", node);
        if (buffer.busy) continue;
        if (buffer.width == width and buffer.height == height) {
            buffer.busy = true;
            return buffer;
        } else {
            first_unbusy_buffer = buffer;
        }
    }

    // No buffer has matching dimensions, however we do have an unbusy
    // buffer which we can just re-init.
    if (first_unbusy_buffer) |buffer| {
        buffer.deinit();
        buffer.* = try Buffer.init(wl_shm, width, height);
        buffer.setListener();
        return buffer;
    }

    return null;
}

fn newBuffer(buffer_pool: *BufferPool, wl_shm: *wl.Shm, width: u31, height: u31) !*Buffer {
    log.debug("creating new buffer {}x{}", .{ width, height });
    const buffer = try utils.allocator.create(Buffer);
    errdefer utils.allocator.destroy(buffer);
    buffer.* = try Buffer.init(wl_shm, width, height);
    buffer.setListener();
    buffer_pool.buffers.append(&buffer.node);
    buffer_pool.len += 1;
    return buffer;
}

fn cullBuffers(buffer_pool: *BufferPool) void {
    log.debug("culling extra buffers", .{});
    var overhead = buffer_pool.len - max_buffer_multiplicity * buffer_pool.surface_count;
    var it = buffer_pool.buffers.first;
    while (it) |node| {
        if (overhead == 0) break;
        // Advance before destroying, since node is embedded in buffer
        it = node.next;
        const buffer: *Buffer = @fieldParentPtr("node", node);
        if (!buffer.busy) {
            buffer.deinit();
            buffer_pool.buffers.remove(node);
            utils.allocator.destroy(buffer);
            buffer_pool.len -= 1;
            overhead -= 1;
        }
    }
    log.debug(" -> new buffer count: {}", .{buffer_pool.len});
}

const std = @import("std");
const DoublyLinkedList = std.DoublyLinkedList;

const wayland = @import("wayland");
const wl = wayland.client.wl;

const Buffer = @import("Buffer.zig");

const utils = @import("utils.zig");

const log = std.log.scoped(.BufferPool);
