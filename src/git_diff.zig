const std = @import("std");
const xitui = @import("xitui");
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const c = @import("./main.zig").c;

pub fn GitDiff(comptime Widget: type) type {
    return struct {
        box: wgt.Box(Widget),
        patches: std.ArrayList(?*c.git_patch),
        diff_count: usize,

        pub fn init(allocator: std.mem.Allocator) !GitDiff(Widget) {
            var inner_box = try wgt.Box(Widget).init(allocator, .{ .border_style = null, .direction = .vert });
            errdefer inner_box.deinit(allocator);

            var scroll = try wgt.Scroll(Widget).init(allocator, .{ .box = inner_box }, .{ .direction = .both });
            errdefer scroll.deinit(allocator);

            var outer_box = try wgt.Box(Widget).init(allocator, .{ .border_style = .single, .direction = .vert });
            errdefer outer_box.deinit(allocator);
            try outer_box.children.put(allocator, scroll.getFocus().id, .{ .widget = .{ .scroll = scroll }, .rect = null, .min_size = null });

            return .{
                .box = outer_box,
                .patches = .empty,
                .diff_count = 0,
            };
        }

        pub fn deinit(self: *GitDiff(Widget), allocator: std.mem.Allocator) void {
            for (self.patches.items) |patch| {
                c.git_patch_free(patch);
            }
            self.patches.deinit(allocator);

            self.box.deinit(allocator);
        }

        pub fn build(self: *GitDiff(Widget), allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            self.box.options.border_style = if (root_focus.grandchild_id == self.getFocus().id) .double else .single;
            try self.box.build(allocator, constraint, root_focus);

            // add another diff if necessary
            if (self.box.children.values()[0].widget.scroll.grid) |scroll_grid| {
                const scroll_y = self.box.children.values()[0].widget.scroll.y;
                const u_scroll_y: usize = if (scroll_y >= 0) @intCast(scroll_y) else 0;
                if (self.box.children.values()[0].widget.scroll.child.box.grid) |inner_box_grid| {
                    const inner_box_height = inner_box_grid.size.height;
                    const min_scroll_remaining = 5;
                    if (inner_box_height -| (scroll_grid.size.height + u_scroll_y) <= min_scroll_remaining) {
                        if (self.diff_count < self.patches.items.len) {
                            try self.addDiff(allocator, self.patches.items[self.diff_count]);
                        }
                    }
                }
            }
        }

        pub fn input(self: *GitDiff(Widget), allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
            _ = allocator;
            _ = root_focus;
            switch (key) {
                .arrow_up => {
                    if (self.box.children.values()[0].widget.scroll.y > 0) {
                        self.box.children.values()[0].widget.scroll.y -= 1;
                    }
                },
                .arrow_down => {
                    if (self.box.children.values()[0].widget.scroll.grid) |scroll_grid| {
                        const scroll_y = self.box.children.values()[0].widget.scroll.y;
                        const u_scroll_y: usize = if (scroll_y >= 0) @intCast(scroll_y) else 0;
                        if (self.box.children.values()[0].widget.scroll.child.box.grid) |inner_box_grid| {
                            const inner_box_height = inner_box_grid.size.height;
                            if (scroll_grid.size.height + u_scroll_y < inner_box_height) {
                                self.box.children.values()[0].widget.scroll.y += 1;
                            }
                        }
                    }
                },
                .arrow_left => {
                    if (self.box.children.values()[0].widget.scroll.x > 0) {
                        self.box.children.values()[0].widget.scroll.x -= 1;
                    }
                },
                .arrow_right => {
                    if (self.box.children.values()[0].widget.scroll.grid) |scroll_grid| {
                        const scroll_x = self.box.children.values()[0].widget.scroll.x;
                        const u_scroll_x: usize = if (scroll_x >= 0) @intCast(scroll_x) else 0;
                        if (self.box.children.values()[0].widget.scroll.child.box.grid) |inner_box_grid| {
                            const inner_box_width = inner_box_grid.size.width;
                            if (scroll_grid.size.width + u_scroll_x < inner_box_width) {
                                self.box.children.values()[0].widget.scroll.x += 1;
                            }
                        }
                    }
                },
                .home => {
                    self.box.children.values()[0].widget.scroll.y = 0;
                },
                .end => {
                    if (self.box.children.values()[0].widget.scroll.grid) |scroll_grid| {
                        if (self.box.children.values()[0].widget.scroll.child.box.grid) |inner_box_grid| {
                            const inner_box_height = inner_box_grid.size.height;
                            const max_scroll: isize = @intCast(inner_box_height -| scroll_grid.size.height);
                            self.box.children.values()[0].widget.scroll.y = max_scroll;
                        }
                    }
                },
                .page_up => {
                    if (self.box.children.values()[0].widget.scroll.grid) |scroll_grid| {
                        const scroll_y = self.box.children.values()[0].widget.scroll.y;
                        const scroll_change: isize = @intCast(scroll_grid.size.height / 2);
                        self.box.children.values()[0].widget.scroll.y = @max(0, scroll_y - scroll_change);
                    }
                },
                .page_down => {
                    if (self.box.children.values()[0].widget.scroll.grid) |scroll_grid| {
                        if (self.box.children.values()[0].widget.scroll.child.box.grid) |inner_box_grid| {
                            const inner_box_height = inner_box_grid.size.height;
                            const max_scroll: isize = @intCast(inner_box_height - scroll_grid.size.height);
                            const scroll_y = self.box.children.values()[0].widget.scroll.y;
                            const scroll_change: isize = @intCast(scroll_grid.size.height / 2);
                            self.box.children.values()[0].widget.scroll.y = @min(scroll_y + scroll_change, max_scroll);
                        }
                    }
                },
                .mouse => |mouse| switch (mouse.action) {
                    .scroll => |dir| switch (dir) {
                        .up => {
                            if (self.box.children.values()[0].widget.scroll.y > 0) {
                                self.box.children.values()[0].widget.scroll.y -= 1;
                            }
                        },
                        .down => {
                            if (self.box.children.values()[0].widget.scroll.grid) |scroll_grid| {
                                const scroll_y = self.box.children.values()[0].widget.scroll.y;
                                const u_scroll_y: usize = if (scroll_y >= 0) @intCast(scroll_y) else 0;
                                if (self.box.children.values()[0].widget.scroll.child.box.grid) |inner_box_grid| {
                                    const inner_box_height = inner_box_grid.size.height;
                                    if (scroll_grid.size.height + u_scroll_y < inner_box_height) {
                                        self.box.children.values()[0].widget.scroll.y += 1;
                                    }
                                }
                            }
                        },
                    },
                    else => {},
                },
                else => {},
            }
        }

        pub fn clearGrid(self: *GitDiff(Widget)) void {
            self.box.clearGrid();
        }

        pub fn getGrid(self: GitDiff(Widget)) ?Grid {
            return self.box.getGrid();
        }

        pub fn getFocus(self: *GitDiff(Widget)) *Focus {
            return self.box.getFocus();
        }

        pub fn clearDiffs(self: *GitDiff(Widget), allocator: std.mem.Allocator) void {
            // clear patches
            for (self.patches.items) |patch| {
                c.git_patch_free(patch);
            }
            self.patches.clearAndFree(allocator);

            // remove old diff widgets
            for (self.box.children.values()[0].widget.scroll.child.box.children.values()) |*child| {
                child.widget.deinit(allocator);
            }
            self.box.children.values()[0].widget.scroll.child.box.children.clearAndFree(allocator);

            // reset scroll position
            const widget = &self.box.children.values()[0].widget;
            widget.scroll.x = 0;
            widget.scroll.y = 0;
            self.diff_count = 0;
        }

        pub fn addDiff(self: *GitDiff(Widget), allocator: std.mem.Allocator, patch: ?*c.git_patch) !void {
            // add new buffer
            var buf: c.git_buf = std.mem.zeroes(c.git_buf);
            std.debug.assert(0 == c.git_patch_to_buf(&buf, patch));
            defer c.git_buf_dispose(&buf);
            const content = std.mem.sliceTo(buf.ptr, 0);

            const display_text = if (std.unicode.utf8ValidateSlice(content)) content else "Diff omitted due to invalid unicode";

            // one span per line: added lines green, removed lines red. the
            // text box copies the text, so the spans only live until init.
            var spans: std.ArrayList(wgt.Span) = .empty;
            defer spans.deinit(allocator);
            var start: usize = 0;
            while (start < display_text.len) {
                // each span keeps its trailing newline so the text box still breaks there
                const end = if (std.mem.indexOfScalarPos(u8, display_text, start, '\n')) |nl| nl + 1 else display_text.len;
                const line = display_text[start..end];
                const style: wgt.Style = if (std.mem.startsWith(u8, line, "+"))
                    .{ .fg = .{ .ansi = .green } }
                else if (std.mem.startsWith(u8, line, "-"))
                    .{ .fg = .{ .ansi = .red } }
                else
                    .{};
                try spans.append(allocator, .{ .text = line, .style = style });
                start = end;
            }

            var text_box = try wgt.TextBox.initSpans(allocator, spans.items, .{ .border_style = .hidden, .wrap_kind = .none });
            errdefer text_box.deinit(allocator);
            try self.box.children.values()[0].widget.scroll.child.box.children.put(allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
            self.diff_count += 1;
        }

        pub fn getScrollX(self: GitDiff(Widget)) isize {
            return self.box.children.values()[0].widget.scroll.x;
        }

        pub fn getScrollY(self: GitDiff(Widget)) isize {
            return self.box.children.values()[0].widget.scroll.y;
        }

        pub fn isEmpty(self: GitDiff(Widget)) bool {
            return self.diff_count == 0;
        }
    };
}
