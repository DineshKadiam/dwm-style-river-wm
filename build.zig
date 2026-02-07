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

    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-layer-shell-v1.xml"));
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml"); // dep of wlr-layer-shell-unstable-v1
    scanner.addCustomProtocol(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("river_window_manager_v1", 3);
    scanner.generate("river_xkb_bindings_v1", 2);
    scanner.generate("river_layer_shell_v1", 1);
    scanner.generate("zwlr_layer_shell_v1", 3);

    const exe = b.addExecutable(.{
        .name = "beansprout",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    exe.pie = pie;

    // Make sure to also add new imports to the exe_check step
    exe.root_module.addImport("wayland", wayland);
    exe.root_module.addImport("kdl", kdl);
    exe.root_module.addImport("known_folders", known_folders);
    exe.root_module.addImport("pixman", pixman);
    exe.root_module.addImport("xkbcommon", xkbcommon);
    exe.root_module.addImport("zigimg", zigimg);

    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("pixman-1");
    exe.linkSystemLibrary("xkbcommon");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run beansprout");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // check step used for zls to give comptime info
    const exe_check = b.addExecutable(.{
        .name = "beansprout",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });

    exe_check.root_module.addImport("wayland", wayland);
    exe_check.root_module.addImport("kdl", kdl);
    exe_check.root_module.addImport("known_folders", known_folders);
    exe_check.root_module.addImport("pixman", pixman);
    exe_check.root_module.addImport("xkbcommon", xkbcommon);
    exe_check.root_module.addImport("zigimg", zigimg);

    exe_check.linkLibC();
    exe_check.linkSystemLibrary("wayland-client");
    exe_check.linkSystemLibrary("pixman-1");
    exe_check.linkSystemLibrary("xkbcommon");

    const check = b.step("check", "Check if beansprout compiles");
    check.dependOn(&exe_check.step);
}
