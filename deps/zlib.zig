const std = @import("std");
fn root() []const u8 {
    return std.Io.Dir.path.dirname(@src().file) orelse ".";
}

const root_path = root() ++ "/";
pub const include_dir = root_path ++ "zlib";

pub const Library = struct {
    step: *std.Build.Step.Compile,

    pub fn link(self: Library, other: *std.Build.Step.Compile) void {
        other.root_module.addIncludePath(other.step.owner.graph.cwdRelativePath(include_dir));
        other.root_module.linkLibrary(self.step);
    }
};

pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) Library {
    var ret = b.addLibrary(.{
        .name = "z",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    ret.root_module.link_libc = true;
    ret.root_module.addCSourceFiles(.{
        .root = b.graph.cwdRelativePath(root()),
        .files = srcs,
        .flags = &.{"-std=c89"},
    });

    return .{ .step = ret };
}

const srcs = &.{
    "zlib/adler32.c",
    "zlib/compress.c",
    "zlib/crc32.c",
    "zlib/deflate.c",
    "zlib/gzclose.c",
    "zlib/gzlib.c",
    "zlib/gzread.c",
    "zlib/gzwrite.c",
    "zlib/inflate.c",
    "zlib/infback.c",
    "zlib/inftrees.c",
    "zlib/inffast.c",
    "zlib/trees.c",
    "zlib/uncompr.c",
    "zlib/zutil.c",
};
