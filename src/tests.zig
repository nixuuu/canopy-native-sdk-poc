// Application integration suites; pure module tests remain beside their implementation.
test {
    _ = @import("tests/git_service_tests.zig");
    _ = @import("tests/maintainability_tests.zig");
    _ = @import("effect_keys.zig");
    _ = @import("tests/profiles_tests.zig");
    _ = @import("tests/tools_sidebar_tests.zig");
    _ = @import("tests/sidebar_tests.zig");
    _ = @import("tests/terminals_tests.zig");
    _ = @import("tests/workspaces_tests.zig");
    _ = @import("tests/git_tests.zig");
    _ = @import("tests/libgit2_tests.zig");
    _ = @import("tests/persistence_tests.zig");
}
