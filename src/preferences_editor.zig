//! Preferences draft, navigation, validation and database-write lifecycle.
const std = @import("std");
const canvas = @import("native_sdk").canvas;
const preferences = @import("preferences.zig");
const workspaces = @import("workspaces.zig");

pub const Section = enum { general, appearance, worktrees, claude, codex };
pub const Prepared = struct { reopen: []const u8, appearance: []const u8, base_dir: []const u8 };
pub const Prepare = union(enum) { skip, invalid: []const u8, ready: Prepared };
pub const Completion = struct { handled: bool = true, committed: bool = false, message: []const u8 = "" };

pub const State = struct {
    saved: preferences.Values = .{},
    draft: preferences.Values = .{},
    open: bool = false,
    dirty: bool = false,
    section: Section = .general,
    loaded: bool = false,
    load_valid: bool = true,
    saving: bool = false,
    submitted: ?preferences.Values = null,
    pending_load: preferences.Values = .{},
    base_dir: canvas.TextBuffer(workspaces.max_path_bytes) = .{},
    search: canvas.TextBuffer(128) = .{},

    pub fn openDialog(self: *State) bool {
        if (!self.loaded or self.saving) return false;
        self.draft = self.saved;
        self.base_dir.set(self.saved.worktrees_base_dir.slice());
        self.search.clear();
        self.dirty = false;
        self.section = .general;
        self.open = true;
        return true;
    }

    pub fn closeDialog(self: *State) bool {
        if (self.saving) return false;
        self.draft = self.saved;
        self.base_dir.clear();
        self.search.clear();
        self.dirty = false;
        self.open = false;
        return true;
    }

    pub fn select(self: *State, section: Section) void {
        self.section = section;
    }

    pub fn profileSelected(self: *const State) bool {
        return self.section == .claude or self.section == .codex;
    }

    pub fn agent(self: *const State) ?@import("profiles.zig").AgentType {
        return switch (self.section) {
            .claude => .claude,
            .codex => .codex,
            else => null,
        };
    }

    pub fn title(self: *const State) []const u8 {
        return switch (self.section) {
            .general => "General",
            .appearance => "Appearance",
            .worktrees => "Worktrees",
            .claude => "Claude",
            .codex => "Codex",
        };
    }

    pub fn description(self: *const State) []const u8 {
        return switch (self.section) {
            .general => "Startup behavior and workspace restoration",
            .appearance => "Application color mode and accessibility",
            .worktrees => "Defaults used when creating Git worktrees",
            .claude => "Claude Code integration",
            .codex => "Codex integration",
        };
    }

    pub fn searchMatches(self: *const State, haystack: []const u8) bool {
        const needle = std.mem.trim(u8, self.search.text(), " ");
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        for (0..haystack.len - needle.len + 1) |start| {
            if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
        }
        return false;
    }

    pub fn toggleReopen(self: *State) void {
        if (self.saving) return;
        self.draft.reopen_last_workspace = !self.draft.reopen_last_workspace;
        self.dirty = true;
    }

    pub fn setAppearance(self: *State, appearance: preferences.AppearanceMode) void {
        if (self.saving) return;
        self.draft.appearance_mode = appearance;
        self.dirty = true;
    }

    pub fn editBaseDir(self: *State, edit: canvas.TextInputEvent) void {
        if (self.saving) return;
        self.base_dir.apply(edit);
        self.dirty = true;
    }

    pub fn baseDirInvalid(self: *const State) bool {
        const value = std.mem.trim(u8, self.base_dir.text(), " ");
        return value.len > 0 and !std.fs.path.isAbsolute(value);
    }

    pub fn prepareSave(self: *State) Prepare {
        if (!self.open or !self.dirty or self.saving or self.baseDirInvalid()) return .skip;
        const base_dir = std.mem.trim(u8, self.base_dir.text(), " ");
        self.draft.worktrees_base_dir.len = 0;
        if (base_dir.len > 0 and !self.draft.worktrees_base_dir.set(base_dir)) return .{ .invalid = "Worktree base directory is too long" };
        self.saving = true;
        self.submitted = self.draft;
        return .{ .ready = .{
            .reopen = if (self.draft.reopen_last_workspace) "true" else "false",
            .appearance = @tagName(self.draft.appearance_mode),
            .base_dir = self.draft.worktrees_base_dir.slice(),
        } };
    }

    pub fn finishSave(self: *State, success: bool, busy: bool) Completion {
        if (!self.saving) return .{ .handled = false };
        const submitted = self.submitted orelse return .{ .handled = false };
        self.submitted = null;
        self.saving = false;
        if (!success) return .{ .message = if (busy) "Preferences database is busy; try again" else "Preferences could not be saved" };
        self.saved = submitted;
        self.dirty = false;
        return .{ .committed = true, .message = "Preferences saved" };
    }

    pub fn loadPage(self: *State, bytes: []const u8) void {
        if (!preferences.decodePage(&self.pending_load, bytes)) self.load_valid = false;
    }

    pub fn finishLoad(self: *State, success: bool) void {
        if (!success) self.load_valid = false;
        if (self.load_valid) self.saved = self.pending_load;
        self.draft = self.saved;
        self.loaded = true;
    }
};

test "dialog edits are discarded on close and committed only after write success" {
    var state: State = .{ .loaded = true };
    try std.testing.expect(state.openDialog());
    state.toggleReopen();
    state.setAppearance(.dark);
    state.base_dir.set("/tmp/worktrees");
    state.dirty = true;
    const prepared = state.prepareSave().ready;
    try std.testing.expectEqualStrings("false", prepared.reopen);
    try std.testing.expectEqualStrings("dark", prepared.appearance);
    try std.testing.expectEqualStrings("/tmp/worktrees", prepared.base_dir);
    const failed = state.finishSave(false, true);
    try std.testing.expect(!failed.committed and state.dirty);
    _ = state.prepareSave();
    try std.testing.expect(state.finishSave(true, false).committed);
    try std.testing.expect(!state.dirty and !state.saved.reopen_last_workspace);
    state.toggleReopen();
    try std.testing.expect(state.closeDialog());
    try std.testing.expect(!state.open and !state.dirty and !state.draft.reopen_last_workspace);
}

test "navigation and validation stay inside editor state" {
    var state: State = .{ .loaded = true };
    _ = state.openDialog();
    state.select(.codex);
    try std.testing.expectEqualStrings("Codex", state.title());
    try std.testing.expectEqual(@import("profiles.zig").AgentType.codex, state.agent().?);
    state.search.set("OPENAI");
    try std.testing.expect(state.searchMatches("Codex OpenAI model"));
    try std.testing.expect(!state.searchMatches("Claude Anthropic model"));
    state.base_dir.set("relative/path");
    state.dirty = true;
    try std.testing.expect(state.baseDirInvalid());
    try std.testing.expectEqual(Prepare.skip, state.prepareSave());
}
