const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const sdk = b.dependency("native_sdk", .{});
    const app = native_sdk.addAppArtifacts(b, sdk, .{
        .name = "canopy-native-sdk-poc",
        .manifest = "app.json",
        .terminal_sessions = true,
    });

    // SDK-wide tests use the inert VT seam. Run terminal regressions against
    // the exact Ghostty-enabled module graph used by this application's tests.
    const sdk_module = app.tests.root_module.import_table.get("native_sdk").?;
    const terminal_module = b.createModule(.{
        .root_source_file = sdk.path("src/canopy_terminal_tests.zig"),
        .target = app.tests.root_module.resolved_target,
        .optimize = .Debug,
        .link_libc = true,
    });
    var imports = sdk_module.import_table.iterator();
    while (imports.next()) |entry| terminal_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
    const terminal_tests = b.addTest(.{
        .root_module = terminal_module,
        .filters = &.{"runtime.terminal_session_tests"},
    });
    const run_terminal_tests = b.addRunArtifact(terminal_tests);
    b.step("test-terminal", "Run terminal regressions with real libghostty-vt").dependOn(&run_terminal_tests.step);
    b.top_level_steps.get("test").?.step.dependOn(&run_terminal_tests.step);

    const painter_tests = b.addTest(.{
        .root_module = sdk_module.import_table.get("canvas").?,
        .filters = &.{"terminal_grid_tests"},
    });
    const run_painter_tests = b.addRunArtifact(painter_tests);
    b.top_level_steps.get("test-terminal").?.step.dependOn(&run_painter_tests.step);
    b.top_level_steps.get("test").?.step.dependOn(&run_painter_tests.step);
}
