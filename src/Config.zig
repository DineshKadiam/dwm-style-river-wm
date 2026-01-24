// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const Config = @This();

border_width: u3,
border_color_focused: RiverColor,
border_color_unfocused: RiverColor,

const std = @import("std");

const RiverColor = @import("utils.zig").RiverColor;
