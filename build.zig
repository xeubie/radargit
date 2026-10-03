const std = @import("std");
const libgit2 = @import("deps/libgit2.zig");
const zlib = @import("deps/zlib.zig");
const mbedtls = @import("deps/mbedtls.zig");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z = zlib.create(b, target, optimize);
    const tls = mbedtls.create(b, target, optimize);

    const git2 = try libgit2.create(b, target, optimize);
    tls.link(git2.step);
    z.link(git2.step);

    const translator: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("deps/libgit2/include/git2.h"),
        .target = target,
        .optimize = optimize,
    });
    translator.addIncludePath(b.path("deps/libgit2/include"));
    translator.linkLibrary(git2.step);

    {
        const exe = b.addExecutable(.{
            .name = "radargit",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = true,
        });
        exe.root_module.addImport("c", translator.mod);
        exe.root_module.addImport("xitui", b.dependency("xitui", .{}).module("xitui"));
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/test.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        unit_tests.root_module.addImport("c", translator.mod);
        unit_tests.root_module.addImport("xitui", b.dependency("xitui", .{}).module("xitui"));

        const run_unit_tests = b.addRunArtifact(unit_tests);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);
    }
}
