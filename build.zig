// SPDX-FileCopyrightText: 2025 Ben Buhse <me@benbuhse.email>
//
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const pie = b.option(bool, "pie", "Build a Position Independent Executable") orelse false;
    const man_pages = b.option(
        bool,
        "man-pages",
        "Set to true to build man pages. Requires scdoc. Defaults to true if scdoc is found.",
    ) orelse scdoc_found: {
        // Default to true if scdoc is available; else false.
        _ = b.findProgram(&.{"scdoc"}, &.{}) catch |err| switch (err) {
            error.FileNotFound => break :scdoc_found false,
            else => return err,
        };
        break :scdoc_found true;
    };

    // Wayland
    const scanner = Scanner.create(b, .{});
    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    // Rest of the deps
    const fcft = b.dependency("fcft", .{}).module("fcft");
    const kdl = b.dependency("kdl", .{}).module("kdl");
    const known_folders = b.dependency("known_folders", .{}).module("known-folders");
    const pixman = b.dependency("pixman", .{}).module("pixman");
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const zeit = b.dependency("zeit", .{}).module("zeit");
    const zigimg = b.dependency("zigimg", .{}).module("zigimg");

    scanner.addCustomProtocol(b.path("protocol/river-input-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-libinput-config-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-layer-shell-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-config-v1.xml"));
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml"); // dep of wlr-layer-shell-unstable-v1
    scanner.addCustomProtocol(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("river_input_manager_v1", 1);
    scanner.generate("river_libinput_config_v1", 1);
    scanner.generate("river_layer_shell_v1", 1);
    scanner.generate("river_window_manager_v1", 4);
    scanner.generate("river_xkb_bindings_v1", 2);
    scanner.generate("river_xkb_config_v1", 1);
    scanner.generate("zwlr_layer_shell_v1", 3);

    const full_version = blk: {
        if (b.option([]const u8, "version-string", "Override `river -version` output.")) |version_override| {
            break :blk version_override;
        } else if (mem.endsWith(u8, version, "-dev")) {
            var ret: u8 = undefined;

            const git_describe_long = b.runAllowFail(
                &.{ "git", "-C", b.build_root.path orelse ".", "describe", "--long" },
                &ret,
                .Ignore,
            ) catch break :blk version;

            var it = mem.splitSequence(u8, mem.trim(u8, git_describe_long, &std.ascii.whitespace), "-");
            _ = it.next().?; // previous tag
            const commit_count = it.next().?;
            const commit_hash = it.next().?;
            assert(it.next() == null);
            assert(commit_hash[0] == 'g');

            // Follow semantic versioning, e.g. 0.2.0-dev.42+d1cf95b
            break :blk b.fmt(version ++ ".{s}+{s}", .{ commit_count, commit_hash[1..] });
        } else {
            break :blk version;
        }
    };

    const options = b.addOptions();
    options.addOption([]const u8, "version", full_version);

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
    beansprout.root_module.addImport("fcft", fcft);
    beansprout.root_module.addImport("kdl", kdl);
    beansprout.root_module.addImport("known_folders", known_folders);
    beansprout.root_module.addImport("pixman", pixman);
    beansprout.root_module.addImport("xkbcommon", xkbcommon);
    beansprout.root_module.addImport("zigimg", zigimg);
    beansprout.root_module.addImport("zeit", zeit);

    beansprout.linkLibC();
    beansprout.linkSystemLibrary("wayland-client");
    beansprout.linkSystemLibrary("fcft");
    beansprout.linkSystemLibrary("pixman-1");
    beansprout.linkSystemLibrary("xkbcommon");

    b.installArtifact(beansprout);

    const man_step = b.step("man", "Build man pages");
    if (man_pages) {
        inline for (.{ .{ "beansprout", "1" }, .{ "beansprout", "5" } }) |page| {
            const scdoc = b.addSystemCommand(&.{ "/bin/sh", "-c", "scdoc < man/" ++ page[0] ++ "." ++ page[1] ++ ".scd" });
            scdoc.setCwd(b.path("."));
            scdoc.addFileArg(b.path("man/" ++ page[0] ++ "." ++ page[1] ++ ".scd"));

            const stdout = scdoc.captureStdOut();
            const install = b.addInstallFile(stdout, "share/man/man" ++ page[1] ++ "/" ++ page[0] ++ "." ++ page[1]);
            b.getInstallStep().dependOn(&install.step);
            man_step.dependOn(&install.step);
        }
    } else {
        man_step.dependOn(&b.addFail("man pages disabled; scdoc not found or -Dman-pages=false was set").step);
    }

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
const manifest = @import("build.zig.zon");
