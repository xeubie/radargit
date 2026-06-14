const std = @import("std");
const xitui = @import("xitui");
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const g_diff = @import("./git_diff.zig");

const c = @import("./main.zig").c;

pub fn GitCommitList(comptime Widget: type) type {
    return struct {
        scroll: wgt.Scroll(Widget),
        repo: ?*c.git_repository,
        walker: ?*c.git_revwalk,
        commits: std.ArrayList(?*c.git_commit),

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository) !GitCommitList(Widget) {
            var self = blk: {
                // init walker
                var walker: ?*c.git_revwalk = null;
                std.debug.assert(0 == c.git_revwalk_new(&walker, repo));
                errdefer c.git_revwalk_free(walker);
                std.debug.assert(0 == c.git_revwalk_sorting(walker, c.GIT_SORT_TIME));
                std.debug.assert(0 == c.git_revwalk_push_head(walker));

                // init commits
                var commits: std.ArrayList(?*c.git_commit) = .empty;
                errdefer commits.deinit(allocator);

                var inner_box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .vert });
                errdefer inner_box.deinit(allocator);

                // init scroll
                var scroll = try wgt.Scroll(Widget).init(allocator, .{ .box = inner_box }, .{ .direction = .vert });
                errdefer scroll.deinit(allocator);

                break :blk GitCommitList(Widget){
                    .scroll = scroll,
                    .repo = repo,
                    .walker = walker,
                    .commits = commits,
                };
            };
            errdefer self.deinit(allocator);

            try self.addCommits(allocator, 20);
            if (self.scroll.child.box.children.count() > 0) {
                self.scroll.getFocus().child_id = self.scroll.child.box.children.keys()[0];
            }

            return self;
        }

        pub fn deinit(self: *GitCommitList(Widget), allocator: std.mem.Allocator) void {
            if (self.walker) |walker| c.git_revwalk_free(walker);
            for (self.commits.items) |commit| {
                c.git_commit_free(commit);
            }
            self.commits.deinit(allocator);
            self.scroll.deinit(allocator);
        }

        pub fn build(self: *GitCommitList(Widget), allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            const children = &self.scroll.child.box.children;
            for (children.keys(), children.values()) |id, *commit| {
                commit.widget.text_box.options.border_style = if (self.getFocus().child_id == id) .single else .hidden;
            }
            try self.scroll.build(allocator, constraint, root_focus);

            // re-anchor scroll on the selected commit so it stays visible
            if (self.getSelectedIndex()) |idx| {
                if (children.values()[idx].rect) |rect| {
                    const prev_y = self.scroll.y;
                    self.scroll.scrollToRect(rect);
                    if (self.scroll.y != prev_y) {
                        try self.scroll.build(allocator, constraint, root_focus);
                    }
                }
            }

            // add more commits if necessary
            if (self.scroll.grid) |scroll_grid| {
                const scroll_y = self.scroll.y;
                const u_scroll_y: usize = if (scroll_y >= 0) @intCast(scroll_y) else 0;
                if (self.scroll.child.box.grid) |inner_box_grid| {
                    const inner_box_height = inner_box_grid.size.height;
                    const min_scroll_remaining = 5;
                    if (inner_box_height -| (scroll_grid.size.height + u_scroll_y) <= min_scroll_remaining) {
                        try self.addCommits(allocator, 20);
                    }
                }
            }
        }

        pub fn input(self: *GitCommitList(Widget), allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
            _ = allocator;
            if (self.getFocus().child_id) |child_id| {
                const children = &self.scroll.child.box.children;
                if (children.getIndex(child_id)) |current_index| {
                    var index = current_index;

                    switch (key) {
                        .arrow_up => {
                            index -|= 1;
                        },
                        .arrow_down => {
                            if (index + 1 < children.count()) {
                                index += 1;
                            }
                        },
                        .home => {
                            index = 0;
                        },
                        .end => {
                            if (children.count() > 0) {
                                index = children.count() - 1;
                            }
                        },
                        .page_up => {
                            if (self.getGrid()) |grid| {
                                const half_count = (grid.size.height / 3) / 2;
                                index -|= half_count;
                            }
                        },
                        .page_down => {
                            if (self.getGrid()) |grid| {
                                if (children.count() > 0) {
                                    const half_count = (grid.size.height / 3) / 2;
                                    index = @min(index + half_count, children.count() - 1);
                                }
                            }
                        },
                        .mouse => |mouse| switch (mouse.action) {
                            .scroll => |dir| switch (dir) {
                                .up => index -|= 1,
                                .down => if (index + 1 < children.count()) {
                                    index += 1;
                                },
                            },
                            else => {},
                        },
                        else => {},
                    }

                    if (index != current_index) {
                        try root_focus.setFocus(children.keys()[index]);
                        self.updateScroll(index);
                    }
                }
            }
        }

        pub fn clearGrid(self: *GitCommitList(Widget)) void {
            self.scroll.clearGrid();
        }

        pub fn getGrid(self: GitCommitList(Widget)) ?Grid {
            return self.scroll.getGrid();
        }

        pub fn getFocus(self: *GitCommitList(Widget)) *Focus {
            return self.scroll.getFocus();
        }

        pub fn getSelectedIndex(self: GitCommitList(Widget)) ?usize {
            if (self.scroll.child.box.focus.child_id) |child_id| {
                const children = &self.scroll.child.box.children;
                return children.getIndex(child_id);
            } else {
                return null;
            }
        }

        fn updateScroll(self: *GitCommitList(Widget), index: usize) void {
            const left_box = &self.scroll.child.box;
            if (left_box.children.values()[index].rect) |rect| {
                self.scroll.scrollToRect(rect);
            }
        }

        fn addCommits(self: *GitCommitList(Widget), allocator: std.mem.Allocator, max_commits: usize) !void {
            if (self.walker) |walker| {
                var oid: c.git_oid = undefined;
                var commits_remaining = true;

                for (0..max_commits) |_| {
                    if (0 == c.git_revwalk_next(&oid, walker)) {
                        var commit: ?*c.git_commit = null;
                        std.debug.assert(0 == c.git_commit_lookup(&commit, self.repo, &oid));
                        {
                            errdefer c.git_commit_free(commit);
                            try self.commits.append(allocator, commit);
                        }

                        const inner_box = &self.scroll.child.box;
                        const line = std.mem.sliceTo(std.mem.sliceTo(c.git_commit_message(commit), 0), '\n');
                        var text_box = try wgt.TextBox(Widget).init(allocator, line, .{ .border_style = .hidden, .wrap_kind = .word });
                        errdefer text_box.deinit(allocator);
                        text_box.getFocus().focusable = true;
                        try inner_box.children.put(allocator, text_box.getFocus().id, .{
                            .widget = .{ .text_box = text_box },
                            .rect = null,
                            .min_size = null,
                            .max_size = .{ .width = null, .height = 5 },
                        });
                    } else {
                        commits_remaining = false;
                        break;
                    }
                }

                if (!commits_remaining) {
                    c.git_revwalk_free(walker);
                    self.walker = null;
                }
            }
        }
    };
}

pub fn GitLog(comptime Widget: type) type {
    return struct {
        box: wgt.Box(Widget),
        repo: ?*c.git_repository,
        diffed_commit_index: ?usize,

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository) !GitLog(Widget) {
            var box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
            errdefer box.deinit(allocator);

            // add commit list
            {
                var commit_list = try GitCommitList(Widget).init(allocator, repo);
                errdefer commit_list.deinit(allocator);
                try box.children.put(allocator, commit_list.getFocus().id, .{ .widget = .{ .git_commit_list = commit_list }, .rect = null, .min_size = .{ .width = 30, .height = null } });
            }

            // add diff
            {
                var diff = try g_diff.GitDiff(Widget).init(allocator, repo);
                errdefer diff.deinit(allocator);
                diff.getFocus().focusable = true;
                try box.children.put(allocator, diff.getFocus().id, .{ .widget = .{ .git_diff = diff }, .rect = null, .min_size = .{ .width = 60, .height = null } });
            }

            var git_log = GitLog(Widget){
                .box = box,
                .repo = repo,
                .diffed_commit_index = null,
            };
            git_log.getFocus().child_id = box.children.keys()[0];
            try git_log.refreshDiffIfNeeded(allocator);

            return git_log;
        }

        pub fn deinit(self: *GitLog(Widget), allocator: std.mem.Allocator) void {
            self.box.deinit(allocator);
        }

        pub fn build(self: *GitLog(Widget), allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            // regenerate the diff only when the selected commit actually changed.
            // doing this here (instead of in input) means a burst of scroll
            // events only triggers one diff computation, per render cycle.
            try self.refreshDiffIfNeeded(allocator);
            try self.box.build(allocator, constraint, root_focus);
        }

        pub fn input(self: *GitLog(Widget), allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
            const diff_scroll_x = self.box.children.values()[1].widget.git_diff.box.children.values()[0].widget.scroll.x;

            if (self.getFocus().child_id) |child_id| {
                if (self.box.children.getIndex(child_id)) |current_index| {
                    const child = &self.box.children.values()[current_index].widget;

                    const index = blk: {
                        switch (key) {
                            .arrow_left => {
                                if (child.* == .git_diff and diff_scroll_x == 0) {
                                    break :blk 0;
                                }
                            },
                            .arrow_right => {
                                if (child.* == .git_commit_list) {
                                    break :blk 1;
                                }
                            },
                            .codepoint => {
                                switch (key.codepoint) {
                                    13 => {
                                        if (child.* == .git_commit_list) {
                                            break :blk 1;
                                        }
                                    },
                                    127, '\x1B' => {
                                        if (child.* == .git_diff) {
                                            break :blk 0;
                                        }
                                    },
                                    else => {},
                                }
                            },
                            else => {},
                        }
                        try child.input(allocator, key, root_focus);
                        break :blk current_index;
                    };

                    if (index != current_index) {
                        try root_focus.setFocus(self.box.children.keys()[index]);
                    }
                }
            }
        }

        pub fn clearGrid(self: *GitLog(Widget)) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: GitLog(Widget)) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *GitLog(Widget)) *Focus {
            return self.box.getFocus();
        }

        pub fn scrolledToTop(self: GitLog(Widget)) bool {
            if (self.box.focus.child_id) |child_id| {
                if (self.box.children.getIndex(child_id)) |current_index| {
                    const child = &self.box.children.values()[current_index].widget;
                    switch (child.*) {
                        .git_commit_list => {
                            const commit_list = &child.git_commit_list;
                            if (commit_list.getSelectedIndex()) |commit_index| {
                                return commit_index == 0;
                            }
                        },
                        .git_diff => {
                            const diff = &child.git_diff;
                            return diff.getScrollY() == 0;
                        },
                        else => {},
                    }
                }
            }
            return true;
        }

        fn refreshDiffIfNeeded(self: *GitLog(Widget), allocator: std.mem.Allocator) !void {
            const commit_list = &self.box.children.values()[0].widget.git_commit_list;
            const current = commit_list.getSelectedIndex();
            if (current == self.diffed_commit_index) return;
            try self.updateDiff(allocator);
            self.diffed_commit_index = current;
        }

        fn updateDiff(self: *GitLog(Widget), allocator: std.mem.Allocator) !void {
            const commit_list = &self.box.children.values()[0].widget.git_commit_list;
            if (commit_list.getSelectedIndex()) |commit_index| {
                const commit = commit_list.commits.items[commit_index];

                const commit_oid = c.git_commit_tree_id(commit);
                var commit_tree: ?*c.git_tree = null;
                std.debug.assert(0 == c.git_tree_lookup(&commit_tree, self.repo, commit_oid));
                defer c.git_tree_free(commit_tree);

                // diff against the commit's actual first parent, read straight
                // from the commit object, so it doesn't depend on the parent
                // having been lazily loaded into the list. null for the root
                // commit, which correctly diffs against an empty tree.
                var prev_commit_tree: ?*c.git_tree = null;

                if (c.git_commit_parentcount(commit) > 0) {
                    var prev_commit: ?*c.git_commit = null;
                    std.debug.assert(0 == c.git_commit_parent(&prev_commit, commit, 0));
                    defer c.git_commit_free(prev_commit);
                    const prev_commit_oid = c.git_commit_tree_id(prev_commit);
                    std.debug.assert(0 == c.git_tree_lookup(&prev_commit_tree, self.repo, prev_commit_oid));
                }
                defer if (prev_commit_tree) |ptr| c.git_tree_free(ptr);

                var commit_diff: ?*c.git_diff = null;
                std.debug.assert(0 == c.git_diff_tree_to_tree(&commit_diff, self.repo, prev_commit_tree, commit_tree, null));
                defer c.git_diff_free(commit_diff);

                var diff = &self.box.children.values()[1].widget.git_diff;
                try diff.clearDiffs(allocator);

                const delta_count = c.git_diff_num_deltas(commit_diff);
                for (0..delta_count) |delta_index| {
                    var patch: ?*c.git_patch = null;
                    std.debug.assert(0 == c.git_patch_from_diff(&patch, commit_diff, delta_index));
                    errdefer c.git_patch_free(patch);
                    try diff.patches.append(allocator, patch);
                }
            }
        }
    };
}
