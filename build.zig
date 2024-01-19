const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "nterm",
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Expose the library root
    _ = b.addModule("nterm", .{
        .root_source_file = .{ .path = "src/root.zig" },
        .link_libc = target.result.os.tag == .windows, // LibC required on Windows for signal handling
    });

    b.installArtifact(lib);

    // Add test step
    const lib_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag == .windows, // LibC required on Windows for signal handling
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
