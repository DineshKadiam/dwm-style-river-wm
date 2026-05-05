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

pub fn load(config: *Config, parser: *kdl.Parser, hostname: ?[]const u8) !void {
    while (try parser.next()) |event| {
        switch (event) {
            .node => |node| {
                const node_name = std.meta.stringToEnum(NodeName, node.name);
                if (node_name) |name| {
                    if (!helpers.hostMatches(node, parser, hostname)) {
                        log.debug("Skipping \"window_rule.{s}\" (host mismatch)", .{@tagName(name)});
                        continue;
                    }

                    const app_id_glob = if (node.prop(parser, "app_id")) |raw_app_id| blk: {
                        const app_id = utils.stripQuotes(raw_app_id);
                        globber.validate(app_id) catch {
                            log.err("Invalid glob for app_id \"{s}\"", .{app_id});
                            return error.InvalidConfig;
                        };
                        break :blk try utils.gpa.dupe(u8, app_id);
                    } else null;
                    errdefer if (app_id_glob) |app_id| utils.gpa.free(app_id);
                    const title_glob = if (node.prop(parser, "title")) |raw_title| blk: {
                        const title = utils.stripQuotes(raw_title);
                        globber.validate(title) catch {
                            log.err("Invalid glob for title \"{s}\"", .{title});
                            return error.InvalidConfig;
                        };
                        break :blk try utils.gpa.dupe(u8, title);
                    } else null;
                    errdefer if (title_glob) |title| utils.gpa.free(title);

                    const action: Action = sw: switch (name) {
                        .float => .{ .float = true },
                        .no_float => .{ .float = false },
                        .tags => {
                            const tags_str = utils.stripQuotes(node.arg(parser, 0) orelse "");
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
                } else {
                    return helpers.invalidNode(node.name);
                }
            },
            .child_block_begin => {
                // window_rules should never have a nested child block
                try helpers.unexpectedChildBlock(parser);
            },
            .child_block_end => {
                // Done parsing the window_rules block; return
                return;
            },
        }
    }
}

fn errInvalidArg(node_name: NodeName, node_value: []const u8) error{InvalidConfig} {
    log.err("Invalid \"window_rule.{s}\" ({s})", .{ @tagName(node_name), node_value });
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
const XkbBindings = @import("../XkbBindings.zig");

const helpers = @import("helpers.zig");

const log = std.log.scoped(.config_window_rule);
