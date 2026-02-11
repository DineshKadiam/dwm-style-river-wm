// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const pie = b.option(bool, "pie", "Build a Position Independent Executable") orelse false;

    // Wayland
    const scanner = Scanner.create(b, .{});
    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    // Rest of the deps
    const kdl = b.dependency("kdl", .{}).module("kdl");
    const known_folders = b.dependency("known_folders", .{}).module("known-folders");
    const pixman = b.dependency("pixman", .{}).module("pixman");
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const zigimg = b.dependency("zigimg", .{}).module("zigimg");

    scanner.addCustomProtocol(b.path("protocol/river-input-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-libinput-config-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-layer-shell-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml"); // dep of wlr-layer-shell-unstable-v1
    scanner.addCustomProtocol(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("river_input_manager_v1", 1);
    scanner.generate("river_libinput_config_v1", 1);
    scanner.generate("river_layer_shell_v1", 1);
    scanner.generate("river_window_manager_v1", 3);
    scanner.generate("river_xkb_bindings_v1", 2);
    scanner.generate("zwlr_layer_shell_v1", 3);

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const beansprout = b.addExecutable(.{
        .name = "beansprout",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    beansprout.pie = pie;

    beansprout.root_module.addOptions("build_options", options);

    beansprout.root_module.addImport("wayland", wayland);
    beansprout.root_module.addImport("kdl", kdl);
    beansprout.root_module.addImport("known_folders", known_folders);
    beansprout.root_module.addImport("pixman", pixman);
    beansprout.root_module.addImport("xkbcommon", xkbcommon);
    beansprout.root_module.addImport("zigimg", zigimg);

    beansprout.linkLibC();
    beansprout.linkSystemLibrary("wayland-client");
    beansprout.linkSystemLibrary("pixman-1");
    beansprout.linkSystemLibrary("xkbcommon");

    b.installArtifact(beansprout);

    const exe_unit_tests = b.addTest(.{
        .root_module = beansprout.root_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Use by zls to get inline compilation errors
    const check = b.step("check", "Check if beansprout compiles");
    check.dependOn(&beansprout.step);
}

const version = manifest.version;
/// Needed until https://github.com/ziglang/zig/issues/22775
/// is addressed.
const manifest: struct {
    name: @Type(.enum_literal),
    version: []const u8,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    dependencies: struct {
        wayland: struct {
            url: []const u8,
            hash: []const u8,
        },
        xkbcommon: struct {
            url: []const u8,
            hash: []const u8,
        },
        kdl: struct {
            url: []const u8,
            hash: []const u8,
        },
        known_folders: struct {
            url: []const u8,
            hash: []const u8,
        },
        pixman: struct {
            url: []const u8,
            hash: []const u8,
        },
        zigimg: struct {
            url: []const u8,
            hash: []const u8,
        },
    },
    paths: []const []const u8,
} = @import("build.zig.zon");
