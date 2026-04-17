// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const BarConfig = @This();

const NodeName = enum {
    fonts,
    text_color,
    background_color,
    position,
    left,
    center,
    right,
    vertical_padding,
    horizontal_padding,
    margins,
    time_format,
};
const MarginsNodeName = enum { top, right, bottom, left };

/// State accumulated while parsing a KDL node
/// Each node gets its own parse state, i.e. state is reset between nodes
const ParseState = struct {
    /// Enum version of the current node
    cur_node: ?NodeName = null,

    /// The hostname that this node should apply to
    host: ?[]const u8 = null,

    /// Argument to the current node
    arg: []const u8 = "",
    /// The number of arguments parsed so far on this node
    arg_count: usize = 0,
};

/// State accumulated while parsing a KDL node inside the margins block
const MarginsParseState = struct {
    /// Enum version of the current node
    cur_node: ?MarginsNodeName = null,

    /// The hostname that this node should apply to
    host: ?[]const u8 = null,

    /// Argument to the current node
    arg: []const u8 = "",
    /// The number of arguments parsed so far on this node
    arg_count: usize = 0,
};

// Comma separated list of FontConfig formatted font specifications.
// null means use the default ("monospace:size=14").
fonts: ?[]const u8 = null,
text_color: pixman.Color = utils.parseRgbaPixmanComptime("0xcdd6f4"),
background_color: pixman.Color = utils.parseRgbaPixmanComptime("0x1e1e2e"),

/// Whether the bar is at the top or bottom of the screen
position: Bar.Position = .top,

/// Which component to show on the left side of the bar
left: Bar.Component = .title,
/// Which component to show in the center of the bar
center: Bar.Component = .clock,
/// Which component to show on the right side of the bar
right: Bar.Component = .wm_info,

/// Margin above the top of the bar and another element (a window or the top of the output)
margin_top: u8 = 0,
/// Margin above the right of the bar and another element (a window or the top of the output)
margin_right: u8 = 0,
/// Margin above bottom top of the bar and another element (a window or the top of the output)
margin_bottom: u8 = 0,
/// Margin above left top of the bar and another element (a window or the top of the output)
margin_left: u8 = 0,

/// Vertical padding between bar edges and content, in pixels
vertical_padding: u8 = 5,
/// Horizontal padding between bar edges and content, in pixels
horizontal_padding: u8 = 5,

/// strftime format string for the clock display.
/// null means use the default.
time_format: ?[]const u8 = null,

pub fn toBarOptions(config: BarConfig) Bar.Options {
    return .{
        .fonts = config.fonts orelse "monospace:size=14",
        .text_color = config.text_color,
        .background_color = config.background_color,
        .position = config.position,
        .left = config.left,
        .center = config.center,
        .right = config.right,
        .margins = .{
            .top = config.margin_top,
            .right = config.margin_right,
            .bottom = config.margin_bottom,
            .left = config.margin_left,
        },
        .vertical_padding = config.vertical_padding,
        .horizontal_padding = config.horizontal_padding,
        .time_format = config.time_format orelse Bar.default_time_format,
    };
}

pub fn load(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    config.bar_config = .{}; // Presence of block = enabled; initialize with defaults

    var state: ParseState = .{};

    var event = try parser.next();
    while (true) : (event = try parser.next()) {
        switch (event) {
            .node => |node| {
                try flushNode(config, hostname, state);
                state = .{
                    .cur_node = std.meta.stringToEnum(NodeName, node.val) orelse {
                        return helpers.invalidNode(node.val);
                    },
                };
            },
            .arg => |arg| {
                state.arg = arg.val;
                state.arg_count += 1;
            },
            .prop => |prop| {
                if (mem.eql(u8, prop.key, "host")) {
                    state.host = prop.val;
                }
            },
            .child_block_begin => {
                const cur_node = state.cur_node orelse {
                    return helpers.unexpectedChildBlock();
                };
                switch (cur_node) {
                    .margins => {
                        if (!helpers.hostMatches(state.host, hostname)) {
                            log.debug("Skipping \"bar.margins\" block (host mismatch)", .{});
                            try helpers.skipChildBlock(parser);
                        } else {
                            try loadMarginsBlock(config, parser, hostname);
                        }
                    },
                    else => {
                        log.err("\"bar.{s}\" does not take a child block", .{@tagName(cur_node)});
                        return error.InvalidConfig;
                    },
                }
                state = .{};
            },
            .child_block_end => {
                try flushNode(config, hostname, state);
                return;
            },
            .invalid => return error.KdlInvalidConfig,
            .eof => return error.UnclosedBlock,
        }
    }
}

fn flushNode(config: *Config, hostname: ?[]const u8, state: ParseState) !void {
    const name = state.cur_node orelse return;
    if (!helpers.hostMatches(state.host, hostname)) {
        logDebugHostMismatch(name);
        return;
    }
    switch (name) {
        .margins => {
            // margins requires a child block; if we reach flushNode it means
            // no child block followed the node
            log.err("\"bar.margins\" requires a child block", .{});
            return error.InvalidConfig;
        },
        .fonts => {
            if (state.arg_count < 1) {
                return errMissingArg(name);
            }
            const val_str = utils.stripQuotes(state.arg);
            config.bar_config.?.fonts = try utils.gpa.dupe(u8, val_str);
            logDebugSettingNode(name, val_str);
        },
        .time_format => {
            if (state.arg_count < 1) {
                return errMissingArg(name);
            }
            const val_str = utils.stripQuotes(state.arg);
            if (!validateTimeFormat(val_str)) {
                return errInvalidArg(name, val_str);
            }
            config.bar_config.?.time_format = try utils.gpa.dupe(u8, val_str);
            logDebugSettingNode(name, val_str);
        },
        .position => {
            if (state.arg_count < 1) {
                return errMissingArg(name);
            }
            const val_str = utils.stripQuotes(state.arg);
            config.bar_config.?.position = std.meta.stringToEnum(Bar.Position, val_str) orelse {
                return errInvalidArg(name, val_str);
            };
            logDebugSettingNode(name, val_str);
        },
        inline .background_color, .text_color => |tag| {
            if (state.arg_count < 1) {
                return errMissingArg(name);
            }
            const val_str = utils.stripQuotes(state.arg);
            @field(config.bar_config.?, @tagName(tag)) = utils.parseRgbaPixman(val_str) catch {
                return errInvalidArg(name, val_str);
            };
            logDebugSettingNode(name, val_str);
        },
        inline .vertical_padding, .horizontal_padding => |tag| {
            if (state.arg_count < 1) {
                return errMissingArg(name);
            }
            const val_str = utils.stripQuotes(state.arg);
            @field(config.bar_config.?, @tagName(tag)) = fmt.parseInt(u8, val_str, 10) catch {
                return errInvalidArg(name, val_str);
            };
            logDebugSettingNode(name, val_str);
        },
        inline .left, .center, .right => |tag| {
            if (state.arg_count < 1) {
                return errMissingArg(name);
            }
            const val_str = utils.stripQuotes(state.arg);
            @field(config.bar_config.?, @tagName(tag)) = std.meta.stringToEnum(Bar.Component, val_str) orelse {
                return errInvalidArg(name, val_str);
            };
            logDebugSettingNode(name, val_str);
        },
    }
}

fn loadMarginsBlock(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    var state: MarginsParseState = .{};

    var event = try parser.next();
    while (true) : (event = try parser.next()) {
        switch (event) {
            .node => |node| {
                try flushMarginsNode(config, hostname, state);
                state = .{
                    .cur_node = std.meta.stringToEnum(MarginsNodeName, node.val) orelse {
                        return helpers.invalidNode(node.val);
                    },
                };
            },
            .arg => |arg| {
                state.arg = arg.val;
                state.arg_count += 1;
            },
            .prop => |prop| {
                if (mem.eql(u8, prop.key, "host")) {
                    state.host = prop.val;
                }
            },
            .child_block_begin => return helpers.unexpectedChildBlock(),
            .child_block_end => {
                try flushMarginsNode(config, hostname, state);
                return;
            },
            .invalid => return error.KdlInvalidConfig,
            .eof => return error.UnclosedBlock,
        }
    }
}

fn flushMarginsNode(config: *Config, hostname: ?[]const u8, state: MarginsParseState) !void {
    const name = state.cur_node orelse return;
    if (!helpers.hostMatches(state.host, hostname)) {
        logDebugHostMismatch(name);
        return;
    }
    if (state.arg_count < 1) {
        return errMissingMarginArg(name);
    }
    const val_str = utils.stripQuotes(state.arg);
    const val = fmt.parseInt(u8, val_str, 10) catch {
        return errInvalidMarginArg(name, val_str);
    };
    switch (name) {
        .top => config.bar_config.?.margin_top = val,
        .right => config.bar_config.?.margin_right = val,
        .bottom => config.bar_config.?.margin_bottom = val,
        .left => config.bar_config.?.margin_left = val,
    }
    logDebugSettingNode(name, val_str);
}

inline fn logDebugSettingNode(node_name: anytype, node_value: []const u8) void {
    const node_name_type = @TypeOf(node_name);
    switch (node_name_type) {
        NodeName => log.debug("Setting bar.{s} to {s}", .{ @tagName(node_name), node_value }),
        MarginsNodeName => log.debug("Setting bar.margins.{s} to {s}", .{ @tagName(node_name), node_value }),
        else => @compileError("This function does not (yet) support type \"" ++ @typeName(@TypeOf(node_name)) ++ "\""),
    }
}

inline fn logDebugHostMismatch(node_name: anytype) void {
    const node_name_type = @TypeOf(node_name);
    switch (node_name_type) {
        NodeName => log.debug("Skipping \"bar.{s}\" (host mismatch)", .{@tagName(node_name)}),
        MarginsNodeName => log.debug("Skipping \"bar.margins.{s}\" (host mismatch)", .{@tagName(node_name)}),
        else => @compileError("This function does not (yet) support type \"" ++ @typeName(node_name_type) ++ "\""),
    }
}

fn errInvalidArg(node_name: NodeName, node_value: []const u8) error{InvalidConfig} {
    log.err("Invalid \"bar.{s}\" ({s})", .{ @tagName(node_name), node_value });
    return error.InvalidConfig;
}

fn errMissingArg(node_name: NodeName) error{InvalidConfig} {
    log.err("\"bar.{s}\" missing argument", .{@tagName(node_name)});
    return error.InvalidConfig;
}

fn errInvalidMarginArg(node_name: MarginsNodeName, node_value: []const u8) error{InvalidConfig} {
    log.err("Invalid \"bar.margins.{s}\" ({s})", .{ @tagName(node_name), node_value });
    return error.InvalidConfig;
}

fn errMissingMarginArg(node_name: MarginsNodeName) error{InvalidConfig} {
    log.err("\"bar.margins.{s}\" missing argument", .{@tagName(node_name)});
    return error.InvalidConfig;
}

fn validateTimeFormat(format: []const u8) bool {
    // Try formatting with a dummy time to validate the format string
    var buf: [255]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);
    const dummy_time = zeit.Time{};
    dummy_time.strftime(&writer, format) catch return false;
    return true;
}

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Io = std.Io;

const kdl = @import("kdl");
const pixman = @import("pixman");
const zeit = @import("zeit");

const utils = @import("../utils.zig");
const Bar = @import("../Bar.zig");
const Config = @import("../Config.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.BarConfig);
