// SPDX-FileCopyrightText: 2026 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const NodeName = enum {
    float,
    no_float,
    tags,
    vsync,
    async,
};

pub const Rule = struct {
    // if app_id/title are null, they match all values
    app_id_glob: ?[]const u8 = null,
    title_glob: ?[]const u8 = null,
    action: Action,
};

pub const Action = union(enum) {
    float: bool,
    tags: u32,
    presentation_mode: PresentationMode,
};

/// State accumulated while parsing a KDL node
/// Each node gets its own parse state, i.e. state is reset between nodes
const ParseState = struct {
    /// Enum version of the current node
    cur_node: ?NodeName = null,

    /// The hostname that this node should apply to
    host: ?[]const u8 = null,

    /// app_id and title glob properties
    app_id: ?[]const u8 = null,
    title: ?[]const u8 = null,

    /// Argument to the current node
    arg: []const u8 = "",
    /// The number of arguments parsed so far on this node
    arg_count: usize = 0,
};

pub fn load(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
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
                } else if (mem.eql(u8, prop.key, "app_id")) {
                    state.app_id = prop.val;
                } else if (mem.eql(u8, prop.key, "title")) {
                    state.title = prop.val;
                }
            },
            .child_block_begin => return helpers.unexpectedChildBlock(),
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
        log.debug("Skipping \"window_rule.{s}\" (host mismatch)", .{@tagName(name)});
        return;
    }

    const app_id_glob = if (state.app_id) |raw_app_id| blk: {
        const app_id = utils.stripQuotes(raw_app_id);
        globber.validate(app_id) catch {
            log.err("Invalid glob for app_id \"{s}\"", .{app_id});
            return error.InvalidConfig;
        };
        break :blk try utils.gpa.dupe(u8, app_id);
    } else null;
    errdefer if (app_id_glob) |app_id| {
        utils.gpa.free(app_id);
    };

    const title_glob = if (state.title) |raw_title| blk: {
        const title = utils.stripQuotes(raw_title);
        globber.validate(title) catch {
            log.err("Invalid glob for title \"{s}\"", .{title});
            return error.InvalidConfig;
        };
        break :blk try utils.gpa.dupe(u8, title);
    } else null;
    errdefer if (title_glob) |title| {
        utils.gpa.free(title);
    };

    const action: Action = sw: switch (name) {
        .float => .{ .float = true },
        .no_float => .{ .float = false },
        .tags => {
            if (state.arg_count < 1) {
                return errMissingArg(name);
            }
            const tags_str = utils.stripQuotes(state.arg);
            const tags = fmt.parseInt(u32, tags_str, 0) catch {
                return errInvalidArg(name, tags_str);
            };
            break :sw .{ .tags = tags };
        },
        inline .vsync, .async => |mode_name| .{
            .presentation_mode = @field(PresentationMode, @tagName(mode_name)),
        },
    };

    try config.window_rules.append(utils.gpa, .{
        .app_id_glob = app_id_glob,
        .title_glob = title_glob,
        .action = action,
    });
}

fn errInvalidArg(node_name: NodeName, node_value: []const u8) error{InvalidConfig} {
    log.err("Invalid \"window_rule.{s}\" ({s})", .{ @tagName(node_name), node_value });
    return error.InvalidConfig;
}

fn errMissingArg(node_name: NodeName) error{InvalidConfig} {
    log.err("\"window_rule.{s}\" missing argument", .{@tagName(node_name)});
    return error.InvalidConfig;
}

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const kdl = @import("kdl");
const PresentationMode = @import("wayland").client.river.OutputV1.PresentationMode;

const globber = @import("../globber.zig");
const utils = @import("../utils.zig");
const Config = @import("../Config.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.config_window_rule);
