// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

pub fn run(backend: Backend) !void {
    var mask = posix.empty_sigset;

    // TODO: Try to make this work on freebsd
    os.linux.sigaddset(&mask, posix.SIG.INT);
    os.linux.sigaddset(&mask, posix.SIG.QUIT);

    posix.sigprocmask(posix.SIG.BLOCK, &mask, null);

    const sig_fd = try posix.signalfd(-1, &mask, 0);

    const poll_wayland = 0;
    const poll_sig = 1;

    var pollfds: [2]posix.pollfd = undefined;

    pollfds[poll_wayland] = .{
        .fd = backend.display.getFd(),
        .events = posix.POLL.IN,
        .revents = 0,
    };
    pollfds[poll_sig] = .{
        .fd = sig_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    };

    while (backend.initialized) {
        {
            const errno = backend.display.flush();
            if (errno != .SUCCESS) {
                log.err("wl_display_dispatch failed: {}", .{errno});
                posix.exit(1);
            }
        }

        if (pollfds[poll_wayland].revents & posix.POLL.HUP != 0) {
            log.warn("disconnected by compositor", .{});
            break;
        }
        if (pollfds[poll_wayland].revents & posix.POLL.IN != 0) {
            const errno = backend.display.dispatch();
            if (errno != .SUCCESS) {
                log.err("failed to dispatch Wayland events", .{});
                break;
            }
        }

        if (pollfds[poll_sig].revents & posix.POLL.HUP != 0) {
            log.err("received SIGHUP", .{});
            posix.exit(1);
        }
        if (pollfds[poll_sig].revents & posix.POLL.IN != 0) {
            var buf: [128]u8 = [_]u8{0} ** 128;
            _ = posix.read(sig_fd, &buf) catch |err| {
                log.err("failed to read from the signalfd {s}", .{@errorName(err)});
                break;
            };

            const info: std.os.linux.signalfd_siginfo = @bitCast(buf);

            // the mask should only catch these
            std.debug.assert(info.signo == posix.SIG.INT or info.signo == posix.SIG.QUIT);

            log.info("beanclock is exiting", .{});
            break;
        }

        _ = backend.display.flush();
    }
}

const std = @import("std");
const os = std.os;
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;

const Backend = @import("Backend.zig");

const log = std.log.scoped(.event_loop);
