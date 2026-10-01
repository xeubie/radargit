//! you're looking at my hopeless attempt to implement
//! a text UI for git. it can't possibly be worse then using
//! the git CLI, right?

const std = @import("std");
const builtin = @import("builtin");
const xitui = @import("xitui");
const term = xitui.terminal;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const g_diff = @import("./git_diff.zig");
const g_log = @import("./git_log.zig");
const g_stat = @import("./git_status.zig");
const g_ui = @import("./git_ui.zig");

pub const c = @cImport({
    @cInclude("git2.h");
});

// cook the terminal before a panic/segfault trace is printed, so the trace
// isn't mangled by raw mode and the alternate buffer
pub const std_options_debug_io = term.crash_debug_io;

pub const Widget = union(enum) {
    text: wgt.Text,
    box: wgt.Box(Widget),
    text_box: wgt.TextBox,
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

    pub fn deinit(self: *Widget, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*case| case.deinit(allocator),
        }
    }

    pub fn build(self: *Widget, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.build(allocator, constraint, root_focus),
        }
    }

    pub fn input(self: *Widget, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) anyerror!void {
        switch (self.*) {
            inline else => |*case| try case.input(allocator, key, root_focus),
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

fn openRepo(path: [*:0]const u8) !*c.git_repository {
    var repo: ?*c.git_repository = null;
    const result = c.git_repository_open_ext(&repo, path, 0, null);
    if (result == c.GIT_ENOTFOUND) return error.RepositoryNotFound;
    if (result != 0) return error.FailedToOpenRepository;
    return repo.?;
}

pub fn main(init: std.process.Init.Minimal) !void {
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

    // find the repo in this directory or one of its parents
    var repo = try openRepo(cwd_path.ptr);
    defer c.git_repository_free(repo);

    // init root widget
    var root = Widget{ .git_ui = try g_ui.GitUI(Widget).init(allocator, repo) };
    defer root.deinit(allocator);

    // build once so the root settles focus onto its initial child
    try root.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 10, .height = 10 },
    }, root.getFocus());

    // init term
    var terminal = try term.Terminal.init(io, allocator);
    defer terminal.deinit(io);
    terminal.render_state.no_color = init.environ.containsUnemptyConstant("NO_COLOR");

    // set term as active so it will be properly cooked
    // when a panic/segfault happens
    term.setActive(&terminal);
    defer term.setActive(null);

    while (!term.quit.load(.monotonic)) {
        // render to tty
        const grid_changed = try terminal.render(&root);

        // process any inputs.
        //
        // if the grid didn't change, then first do a blocking
        // read, so the thread will sleep until further input.
        // after that, all remaining reads are non-blocking so
        // we can process the rest of the queued inputs.
        //
        // if the grid *did* change, then only do non-blocking
        // reads. we do not want to sleep the thread because
        // there may be an animation that requires more looping.
        var blocking = !grid_changed;
        while (try terminal.readKey(io, blocking)) |key| {
            blocking = false;
            switch (key) {
                .escape => return,
                .ctrl => |letter| switch (letter) {
                    // ctrl+r: refresh by reopening the repo and recreating
                    // the root widget, preserving the currently selected tab
                    'r' => {
                        const new_repo = try openRepo(cwd_path.ptr);

                        const new_git_ui = g_ui.GitUI(Widget).init(allocator, new_repo) catch |err| {
                            c.git_repository_free(new_repo);
                            return err;
                        };

                        const tab_index = root.git_ui.box.children.values()[0].widget.git_ui_tabs.getSelectedIndex();

                        // deinit the old root before freeing the old repo,
                        // because its widgets hold libgit2 objects that must
                        // not outlive their repository
                        root.deinit(allocator);
                        root = Widget{ .git_ui = new_git_ui };
                        c.git_repository_free(repo);
                        repo = new_repo;

                        // build once so the root settles focus onto its
                        // initial child, then restore the selected tab
                        try root.build(allocator, .{
                            .min_size = .{ .width = null, .height = null },
                            .max_size = .{ .width = 10, .height = 10 },
                        }, root.getFocus());
                        if (tab_index) |index| {
                            const tabs = &root.git_ui.box.children.values()[0].widget.git_ui_tabs;
                            root.getFocus().setFocus(tabs.box.children.keys()[index]);
                        }
                    },
                    else => try root.input(allocator, key, root.getFocus()),
                },
                .mouse => |mouse| {
                    if (mouse.action == .press and mouse.action.press == .left) {
                        const root_focus = root.getFocus();
                        if (root_focus.hitTest(mouse.x, mouse.y)) |hit| root_focus.setFocus(hit.id);
                    } else {
                        try root.input(allocator, key, root.getFocus());
                    }
                },
                else => try root.input(allocator, key, root.getFocus()),
            }
        }

        // rebuild widget
        try root.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = terminal.size.width, .height = terminal.size.height },
        }, root.getFocus());
    }
}
