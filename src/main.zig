//! you're looking at my hopeless attempt to implement
//! a text UI for git. it can't possibly be worse then using
//! the git CLI, right?

const std = @import("std");
const builtin = @import("builtin");
const xitui = @import("xitui");
const term = xitui.terminal;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const g_diff = @import("./git_diff.zig");
const g_log = @import("./git_log.zig");
const g_stat = @import("./git_status.zig");
const g_ui = @import("./git_ui.zig");

pub const c = @cImport({
    @cInclude("git2.h");
});

pub const Widget = union(enum) {
    text: wgt.Text(Widget),
    box: wgt.Box(Widget),
    text_box: wgt.TextBox(Widget),
    scroll: wgt.Scroll(Widget),
    stack: wgt.Stack(Widget),
    git_diff: g_diff.GitDiff(Widget),
    git_commit_list: g_log.GitCommitList(Widget),
    git_log: g_log.GitLog(Widget),
    git_status_tabs: g_stat.GitStatusTabs(Widget),
    git_status_list_item: g_stat.GitStatusListItem(Widget),
    git_status_list: g_stat.GitStatusList(Widget),
    git_status_content: g_stat.GitStatusContent(Widget),
    git_status: g_stat.GitStatus(Widget),
    git_ui_tabs: g_ui.GitUITabs(Widget),
    git_ui: g_ui.GitUI(Widget),

    pub fn deinit(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.deinit(),
        }
    }

    pub fn build(self: *Widget, constraint: layout.Constraint, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.build(constraint, root_focus),
        }
    }

    pub fn input(self: *Widget, key: inp.Key, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.input(key, root_focus),
        }
    }

    pub fn clearGrid(self: *Widget) void {
        switch (self.*) {
            inline else => |*case| case.clearGrid(),
        }
    }

    pub fn getGrid(self: Widget) ?Grid {
        switch (self) {
            inline else => |*case| return case.getGrid(),
        }
    }

    pub fn getFocus(self: *Widget) *Focus {
        switch (self.*) {
            inline else => |*case| return case.getFocus(),
        }
    }
};

pub fn main() !void {
    // start libgit
    _ = c.git_libgit2_init();
    defer _ = c.git_libgit2_shutdown();

    // init allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = if (builtin.mode == .Debug) debug_allocator.allocator() else std.heap.smp_allocator;
    defer if (builtin.mode == .Debug) {
        _ = debug_allocator.deinit();
    };

    // init io
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    // find cwd
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    // init repo
    var repo: ?*c.git_repository = null;
    std.debug.assert(0 == c.git_repository_init(&repo, cwd_path.ptr, 0));
    defer c.git_repository_free(repo);

    // init root widget
    var root = Widget{ .git_ui = try g_ui.GitUI(Widget).init(allocator, repo) };
    defer root.deinit();

    // set initial focus for root widget
    try root.build(.{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 10, .height = 10 },
    }, root.getFocus());
    if (root.getFocus().child_id) |child_id| {
        try root.getFocus().setFocus(child_id);
    }

    // init term
    var terminal = try term.Terminal.init(io, allocator);
    defer terminal.deinit(io);

    var last_size = layout.Size{ .width = 0, .height = 0 };
    var last_grid = try Grid.init(allocator, last_size);
    defer last_grid.deinit();

    while (!term.quit) {
        // render to tty
        try terminal.render(&root, &last_grid, &last_size);

        // process any inputs
        while (try terminal.readKey(io)) |key| {
            switch (key) {
                .codepoint => |cp| if (cp == 'q') return,
                else => {},
            }
            try root.input(key, root.getFocus());
        }

        // rebuild widget
        try root.build(.{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = last_size.width, .height = last_size.height },
        }, root.getFocus());

        // TODO: do variable sleep with target frame rate
        try std.Io.sleep(io, .fromMilliseconds(5), .real);
    }
}
