// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");

const event_loop = @import("event_loop.zig");
const Backend = @import("Backend.zig");

const log = std.log.scoped(.main);

const usage: []const u8 =
    \\usage: beansprout [options]
    \\
    \\  -i, --image <PATH>  TODO TODO TODO TODO
    \\  -h, --help          TODO TODO TODO TODO
    \\  -V, --version       TODO TODO TODO TODO
    \\
;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Set up Wayland stuff
    var backend = try Backend.init(allocator);
    defer backend.deinit();

    event_loop.run();

    // TODO: REMOVEME
    log.debug("Exiting...", .{});
}
