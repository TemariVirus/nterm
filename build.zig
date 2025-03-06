const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Expose the library root
    const nterm = b.addModule("nterm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag == .windows, // LibC required on Windows for signal handling
    });

    // Add test step
    const lib_tests = b.addTest(.{
        .root_module = nterm,
        .link_libc = target.result.os.tag == .windows, // LibC required on Windows for signal handling
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
}
