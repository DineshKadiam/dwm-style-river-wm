// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

pub const NodeName = enum {
    fonts,
    text_color,
    background_color,
    position,
    margins,
};
pub const MarginsNodeName = enum { top, right, bottom, left };

pub const BarConfig = struct {
    // Comma separated list of FontConfig formatted font specifications.
    // null means use the default ("monospace:size=14").
    fonts: ?[]const u8 = null,
    text_color: pixman.Color = utils.parseRgbaPixmanComptime("0xcdd6f4"),
    background_color: pixman.Color = utils.parseRgbaPixmanComptime("0x1e1e2e"),
    position: Bar.Position = .top,
    margin_top: i32 = 0,
    margin_right: i32 = 0,
    margin_bottom: i32 = 0,
    margin_left: i32 = 0,
    // TODO: Support only having the bar on specific outputs
    // output: []const u8,

    pub fn toBarOptions(config: BarConfig) Bar.Options {
        return .{
            .fonts = config.fonts orelse "monospace:size=14",
            .text_color = config.text_color,
            .background_color = config.background_color,
            .position = config.position,
            .margins = .{
                .top = config.margin_top,
                .right = config.margin_right,
                .bottom = config.margin_bottom,
                .left = config.margin_left,
            },
        };
    }
};

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
                    const val = fmt.parseInt(i32, val_str, 10) catch {
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

inline fn logWarnMissingNodeArg(node_name: NodeName, comptime arg: []const u8) void {
    log.warn("\"bar.{s}\" missing " ++ arg ++ " argument. Ignoring", .{@tagName(node_name)});
}

const std = @import("std");
const fmt = std.fmt;

const kdl = @import("kdl");
const pixman = @import("pixman");

const utils = @import("../utils.zig");
const Bar = @import("../Bar.zig");
const Config = @import("../Config.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.config_bar);
