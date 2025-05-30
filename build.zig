const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.graph.host;
    const optimize: std.builtin.OptimizeMode = .ReleaseSafe;

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zbpe_lib", lib_mod);

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zbpe",
        .root_module = lib_mod,
    });
    const exe = b.addExecutable(.{
        .name = "zbpe",
        .root_module = exe_mod,
    });
    const check = b.step("check", "Check step for ZLS");
    check.dependOn(&lib.step);

    check.dependOn(&exe.step);

    b.installArtifact(lib);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    test_step.dependOn(&run_exe_unit_tests.step);
}
