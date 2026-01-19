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

    const scanner = Scanner.create(b, .{});
    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");

    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("river_window_manager_v1", 3);
    scanner.generate("river_xkb_bindings_v1", 2);

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

    exe.root_module.addImport("wayland", wayland);
    exe.root_module.addImport("xkbcommon", xkbcommon);

    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");

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

    exe_check.linkLibC();
    exe_check.linkSystemLibrary("wayland-client");

    const check = b.step("check", "Check if beanbag compiles");
    check.dependOn(&exe_check.step);
}
