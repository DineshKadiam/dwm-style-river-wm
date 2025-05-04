// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: EUPL-1.2

pub fn main() !void {
    std.debug.print("All your {s} are belong to us.\n", .{"protocol"});
}

const std = @import("std");
