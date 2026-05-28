const std = @import("std");
const xitui = @import("xitui");
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const g_stat = @import("./git_status.zig");
const g_log = @import("./git_log.zig");

const c = @import("./main.zig").c;

pub fn GitUITabs(comptime Widget: type) type {
    return struct {
        box: wgt.Box(Widget),

        const FocusKind = enum { log, status };

        pub fn init(allocator: std.mem.Allocator) !GitUITabs(Widget) {
            var box = wgt.Box(Widget).init(.{ .border_style = null, .direction = .horiz });
            errdefer box.deinit(allocator);

            inline for (@typeInfo(FocusKind).@"enum".fields) |focus_kind_field| {
                const focus_kind: FocusKind = @enumFromInt(focus_kind_field.value);
                const name = switch (focus_kind) {
                    .log => "log",
                    .status => "status",
                };
                var text_box = try wgt.TextBox(Widget).init(allocator, name, .{ .border_style = .single, .wrap_kind = .none });
                errdefer text_box.deinit(allocator);
                text_box.getFocus().focusable = true;
                try box.children.put(allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
            }

            var git_ui_tabs = GitUITabs(Widget){
                .box = box,
            };
            git_ui_tabs.getFocus().child_id = box.children.keys()[0];
            return git_ui_tabs;
        }

        pub fn deinit(self: *GitUITabs(Widget), allocator: std.mem.Allocator) void {
            self.box.deinit(allocator);
        }

        pub fn build(self: *GitUITabs(Widget), allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            for (self.box.children.keys(), self.box.children.values()) |id, *tab| {
                tab.widget.text_box.options.border_style = if (self.getFocus().child_id == id) .single else .hidden;
            }
            try self.box.build(allocator, constraint, root_focus);
        }

        pub fn input(self: *GitUITabs(Widget), allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
            _ = allocator;
            if (self.getFocus().child_id) |child_id| {
                const children = &self.box.children;
                if (children.getIndex(child_id)) |current_index| {
                    var index = current_index;

                    switch (key) {
                        .arrow_left => {
                            index -|= 1;
                        },
                        .arrow_right => {
                            if (index + 1 < self.box.children.count()) {
                                index += 1;
                            }
                        },
                        else => {},
                    }

                    if (index != current_index) {
                        try root_focus.setFocus(children.keys()[index]);
                    }
                }
            }
        }

        pub fn clearGrid(self: *GitUITabs(Widget)) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: GitUITabs(Widget)) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *GitUITabs(Widget)) *Focus {
            return self.box.getFocus();
        }

        pub fn getSelectedIndex(self: GitUITabs(Widget)) ?usize {
            if (self.box.focus.child_id) |child_id| {
                const children = &self.box.children;
                return children.getIndex(child_id);
            } else {
                return null;
            }
        }
    };
}

pub fn GitUI(comptime Widget: type) type {
    return struct {
        box: wgt.Box(Widget),

        const FocusKind = enum { tabs, stack };

        pub fn init(allocator: std.mem.Allocator, repo: ?*c.git_repository) !GitUI(Widget) {
            var box = wgt.Box(Widget).init(.{ .border_style = null, .direction = .vert });
            errdefer box.deinit(allocator);

            inline for (@typeInfo(FocusKind).@"enum".fields) |focus_kind_field| {
                const focus_kind: FocusKind = @enumFromInt(focus_kind_field.value);
                switch (focus_kind) {
                    .tabs => {
                        var git_ui_tabs = try GitUITabs(Widget).init(allocator);
                        errdefer git_ui_tabs.deinit(allocator);
                        try box.children.put(allocator, git_ui_tabs.getFocus().id, .{ .widget = .{ .git_ui_tabs = git_ui_tabs }, .rect = null, .min_size = null });
                    },
                    .stack => {
                        var stack = wgt.Stack(Widget).init();
                        errdefer stack.deinit(allocator);

                        {
                            var git_log = try g_log.GitLog(Widget).init(allocator, repo);
                            errdefer git_log.deinit(allocator);
                            try stack.children.put(allocator, git_log.getFocus().id, .{ .git_log = git_log });
                        }

                        {
                            var git_status = try g_stat.GitStatus(Widget).init(allocator, repo);
                            errdefer git_status.deinit(allocator);
                            try stack.children.put(allocator, git_status.getFocus().id, .{ .git_status = git_status });
                        }

                        try box.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
                    },
                }
            }

            var git_ui = GitUI(Widget){
                .box = box,
            };
            git_ui.getFocus().child_id = box.children.keys()[0];
            return git_ui;
        }

        pub fn deinit(self: *GitUI(Widget), allocator: std.mem.Allocator) void {
            self.box.deinit(allocator);
        }

        pub fn build(self: *GitUI(Widget), allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            const git_ui_tabs = &self.box.children.values()[@intFromEnum(FocusKind.tabs)].widget.git_ui_tabs;
            const git_ui_stack = &self.box.children.values()[@intFromEnum(FocusKind.stack)].widget.stack;
            if (git_ui_tabs.getSelectedIndex()) |index| {
                git_ui_stack.getFocus().child_id = git_ui_stack.children.keys()[index];
            }
            try self.box.build(allocator, constraint, root_focus);
        }

        pub fn input(self: *GitUI(Widget), allocator: std.mem.Allocator, key: inp.Key, root_focus: *Focus) !void {
            if (self.getFocus().child_id) |child_id| {
                if (self.box.children.getIndex(child_id)) |current_index| {
                    const child = &self.box.children.values()[current_index].widget;
                    var index = current_index;

                    // scroll wheel moves the selection across tab/stack just
                    // like arrow up/down does
                    const Direction = enum { up, down, none };
                    const direction: Direction = switch (key) {
                        .arrow_up => .up,
                        .arrow_down => .down,
                        .mouse => |mouse| if (mouse.action == .scroll)
                            (if (mouse.action.scroll == .up) .up else .down)
                        else
                            .none,
                        else => .none,
                    };

                    switch (direction) {
                        .up => {
                            switch (child.*) {
                                .git_ui_tabs => {
                                    try child.input(allocator, key, root_focus);
                                },
                                .stack => {
                                    if (child.stack.getSelected()) |selected_widget| {
                                        switch (selected_widget.*) {
                                            .git_log => {
                                                if (selected_widget.git_log.scrolledToTop()) {
                                                    index = @intFromEnum(FocusKind.tabs);
                                                } else {
                                                    try child.input(allocator, key, root_focus);
                                                }
                                            },
                                            .git_status => {
                                                if (selected_widget.git_status.getSelectedIndex() == 0) {
                                                    index = @intFromEnum(FocusKind.tabs);
                                                } else {
                                                    try child.input(allocator, key, root_focus);
                                                }
                                            },
                                            else => {},
                                        }
                                    }
                                },
                                else => {},
                            }
                        },
                        .down => {
                            switch (child.*) {
                                .git_ui_tabs => {
                                    index = @intFromEnum(FocusKind.stack);
                                },
                                .stack => {
                                    try child.input(allocator, key, root_focus);
                                },
                                else => {},
                            }
                        },
                        .none => {
                            try child.input(allocator, key, root_focus);
                        },
                    }

                    if (index != current_index) {
                        try root_focus.setFocus(self.box.children.keys()[index]);
                    }
                }
            }
        }

        pub fn clearGrid(self: *GitUI(Widget)) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: GitUI(Widget)) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *GitUI(Widget)) *Focus {
            return self.box.getFocus();
        }
    };
}
