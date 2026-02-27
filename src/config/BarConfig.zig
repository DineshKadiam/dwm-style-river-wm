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

    const BarChild = enum { margins };
    var next_child_block: ?BarChild = null;

    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                if (next_child_block) |child| {
                    log.warn("Expected child block for bar.{s}, got node instead. Ignoring", .{@tagName(child)});
                    next_child_block = null;
                }
                const node_name = std.meta.stringToEnum(NodeName, node.name);
                if (node_name) |name| {
                    if (!helpers.hostMatches(node, parser, hostname)) {
                        logDebugHostMismatch(name);
                        continue;
                    }
                    const val_str = utils.stripQuotes(node.arg(parser, 0) orelse "");
                    switch (name) {
                        .fonts => {
                            if (node.argcount() < 1) {
                                logWarnMissingNodeArg(name, "font specification");
                                continue;
                            }
                            config.bar_config.?.fonts = utils.gpa.dupe(u8, val_str) catch @panic("Out of memory");
                            logDebugSettingNode(name, val_str);
                        },
                        .position => {
                            if (std.meta.stringToEnum(Bar.Position, val_str)) |pos| {
                                config.bar_config.?.position = pos;
                                logDebugSettingNode(name, val_str);
                            } else {
                                logWarnInvalidNodeArg(name, val_str);
                            }
                        },
                        .time_format => {
                            if (node.argcount() < 1) {
                                logWarnMissingNodeArg(name, "format string");
                                continue;
                            }
                            if (validateTimeFormat(val_str)) {
                                config.bar_config.?.time_format = utils.gpa.dupe(u8, val_str) catch @panic("Out of memory");
                                logDebugSettingNode(name, val_str);
                            } else {
                                logWarnInvalidNodeArg(name, val_str);
                            }
                        },
                        .margins => next_child_block = .margins,
                        inline .background_color,
                        .text_color,
                        => |tag| {
                            @field(config.bar_config.?, @tagName(tag)) = utils.parseRgbaPixman(val_str) catch {
                                logWarnInvalidNodeArg(name, val_str);
                                continue;
                            };
                            logDebugSettingNode(name, val_str);
                        },
                        inline .vertical_padding,
                        .horizontal_padding,
                        => |tag| {
                            const padding_str = utils.stripQuotes(node.arg(parser, 0) orelse "");
                            const padding = fmt.parseInt(u8, padding_str, 10) catch {
                                logWarnInvalidNodeArg(name, padding_str);
                                continue;
                            };
                            @field(config.bar_config.?, @tagName(tag)) = padding;
                            logDebugSettingNode(name, padding_str);
                        },
                        inline .left, .center, .right => |tag| {
                            if (std.meta.stringToEnum(Bar.Component, val_str)) |component| {
                                @field(config.bar_config.?, @tagName(tag)) = component;
                                logDebugSettingNode(name, val_str);
                            } else {
                                logWarnInvalidNodeArg(name, val_str);
                            }
                        },
                    }
                } else {
                    helpers.logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => {
                if (next_child_block) |child| {
                    switch (child) {
                        .margins => try loadMarginsBlock(config, parser, hostname),
                    }
                    next_child_block = null;
                } else {
                    try helpers.skipChildBlock(parser);
                }
            },
            .child_block_end => return,
        }
    }
}

fn loadMarginsBlock(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                const node_name = std.meta.stringToEnum(MarginsNodeName, node.name);
                if (node_name) |name| {
                    if (!helpers.hostMatches(node, parser, hostname)) {
                        logDebugHostMismatch(name);
                        continue;
                    }
                    const val_str = utils.stripQuotes(node.arg(parser, 0) orelse "");
                    const val = fmt.parseInt(u8, val_str, 10) catch {
                        logWarnInvalidNodeArg(name, val_str);
                        continue;
                    };
                    switch (name) {
                        .top => config.bar_config.?.margin_top = val,
                        .right => config.bar_config.?.margin_right = val,
                        .bottom => config.bar_config.?.margin_bottom = val,
                        .left => config.bar_config.?.margin_left = val,
                    }
                    logDebugSettingNode(name, val_str);
                } else {
                    helpers.logWarnInvalidNode(node.name);
                }
            },
            .child_block_begin => try helpers.skipChildBlock(parser),
            .child_block_end => return,
        }
    }
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

inline fn logWarnInvalidNodeArg(node_name: anytype, node_value: []const u8) void {
    const node_name_type = @TypeOf(node_name);
    switch (node_name_type) {
        NodeName => log.warn("Invalid \"bar.{s}\" ({s}). Using default value", .{ @tagName(node_name), node_value }),
        MarginsNodeName => log.warn("Invalid \"bar.margins.{s}\" ({s}). Using default value", .{ @tagName(node_name), node_value }),
        else => @compileError("This function does not (yet) support type \"" ++ @typeName(node_name_type) ++ "\""),
    }
}

fn validateTimeFormat(format: []const u8) bool {
    // Try formatting with a dummy time to validate the format string
    var buf: [255]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);
    const dummy_time = zeit.Time{};
    dummy_time.strftime(&writer, format) catch return false;
    return true;
}

inline fn logWarnMissingNodeArg(node_name: NodeName, comptime arg: []const u8) void {
    log.warn("\"bar.{s}\" missing " ++ arg ++ " argument. Ignoring", .{@tagName(node_name)});
}

const std = @import("std");
const fmt = std.fmt;
const Io = std.Io;

const kdl = @import("kdl");
const pixman = @import("pixman");
const zeit = @import("zeit");

const utils = @import("../utils.zig");
const Bar = @import("../Bar.zig");
const Config = @import("../Config.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.BarConfig);
