const std = @import("std");
const main = @import("./main.zig");
const g_ui = @import("./git_ui.zig");

const c = main.c;

test "end to end" {
    const temp_dir_name = "temp-test-end-to-end";

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // start libgit
    _ = c.git_libgit2_init();
    defer _ = c.git_libgit2_shutdown();

    // get the current working directory path.
    // we can't just call std.Io.Dir.cwd() all the time because we're
    // gonna change it later. and since defers run at the end,
    // if you call std.Io.Dir.cwd() in them you're gonna have a bad time.
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    var cwd = try std.Io.Dir.openDirAbsolute(io, cwd_path, .{});
    defer cwd.close(io);

    // create the temp dir
    if (cwd.openFile(io, temp_dir_name, .{})) |file| {
        file.close(io);
        try cwd.deleteTree(io, temp_dir_name);
    } else |_| {}
    var temp_dir = try cwd.createDirPathOpen(io, temp_dir_name, .{});
    defer cwd.deleteTree(io, temp_dir_name) catch {};
    defer temp_dir.close(io);

    // create the repo dir
    var repo_dir = try temp_dir.createDirPathOpen(io, "repo", .{});
    defer repo_dir.close(io);

    // get repo path for libgit
    const repo_path_z = try repo_dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(repo_path_z);
    const repo_path: [*c]const u8 = @ptrCast(repo_path_z.ptr);

    // init repo
    var repo: ?*c.git_repository = null;
    try std.testing.expectEqual(0, c.git_repository_init(&repo, repo_path, 0));
    defer c.git_repository_free(repo);

    // make sure the git dir was created
    var git_dir = try repo_dir.openDir(io, ".git", .{});
    defer git_dir.close(io);

    // add and commit
    {
        // make file
        var hello_txt = try repo_dir.createFile(io, "hello.txt", .{});
        defer hello_txt.close(io);
        try hello_txt.writeStreamingAll(io, "hello, world!");

        // make file
        var readme = try repo_dir.createFile(io, "README", .{});
        defer readme.close(io);
        try readme.writeStreamingAll(io, "My cool project");

        // add the files
        var index: ?*c.git_index = null;
        try std.testing.expectEqual(0, c.git_repository_index(&index, repo));
        defer c.git_index_free(index);
        try std.testing.expectEqual(0, c.git_index_add_bypath(index, "hello.txt"));
        try std.testing.expectEqual(0, c.git_index_add_bypath(index, "README"));
        try std.testing.expectEqual(0, c.git_index_write(index));

        // make the commit
        var tree_oid: c.git_oid = undefined;
        try std.testing.expectEqual(0, c.git_index_write_tree(&tree_oid, index));
        var tree: ?*c.git_tree = null;
        try std.testing.expectEqual(0, c.git_tree_lookup(&tree, repo, &tree_oid));
        defer c.git_tree_free(tree);
        var commit_oid: c.git_oid = undefined;
        var signature: ?*c.git_signature = null;
        try std.testing.expectEqual(0, c.git_signature_new(&signature, "radarroark", "radarroark@radar.roark", 0, 0));
        defer c.git_signature_free(signature);
        try std.testing.expectEqual(0, c.git_commit_create(
            &commit_oid,
            repo,
            "HEAD",
            signature,
            signature,
            null,
            "let there be light",
            tree,
            0,
            null,
        ));
    }

    // add and commit
    {
        // make files
        var license = try repo_dir.createFile(io, "LICENSE", .{});
        defer license.close(io);
        try license.writeStreamingAll(io, "do whatever you want");
        var change_log = try repo_dir.createFile(io, "CHANGELOG", .{});
        defer change_log.close(io);
        try change_log.writeStreamingAll(io, "cha-cha-cha-changes");

        // change file
        const new_hello = "goodbye, world!";
        const hello_txt = try repo_dir.openFile(io, "hello.txt", .{ .mode = .read_write });
        defer hello_txt.close(io);
        try hello_txt.writeStreamingAll(io, new_hello);
        try hello_txt.setLength(io, new_hello.len);

        // add the files
        var index: ?*c.git_index = null;
        try std.testing.expectEqual(0, c.git_repository_index(&index, repo));
        defer c.git_index_free(index);
        try std.testing.expectEqual(0, c.git_index_add_bypath(index, "LICENSE"));
        try std.testing.expectEqual(0, c.git_index_add_bypath(index, "CHANGELOG"));
        try std.testing.expectEqual(0, c.git_index_add_bypath(index, "hello.txt"));
        try std.testing.expectEqual(0, c.git_index_write(index));

        // get previous commit
        var parent_object: ?*c.git_object = null;
        var ref: ?*c.git_reference = null;
        try std.testing.expectEqual(0, c.git_revparse_ext(&parent_object, &ref, repo, "HEAD"));
        defer c.git_object_free(parent_object);
        defer c.git_reference_free(ref);
        var parent_commit: ?*c.git_commit = null;
        try std.testing.expectEqual(0, c.git_commit_lookup(&parent_commit, repo, c.git_object_id(parent_object)));
        defer c.git_commit_free(parent_commit);
        var parents = [_]?*const c.git_commit{parent_commit};

        // make the commit
        var tree_oid: c.git_oid = undefined;
        try std.testing.expectEqual(0, c.git_index_write_tree(&tree_oid, index));
        var tree: ?*c.git_tree = null;
        try std.testing.expectEqual(0, c.git_tree_lookup(&tree, repo, &tree_oid));
        defer c.git_tree_free(tree);
        var commit_oid: c.git_oid = undefined;
        var signature: ?*c.git_signature = null;
        try std.testing.expectEqual(0, c.git_signature_new(&signature, "radarroark", "radarroark@radar.roark", 0, 0));
        defer c.git_signature_free(signature);
        try std.testing.expectEqual(0, c.git_commit_create(
            &commit_oid,
            repo,
            "HEAD",
            signature,
            signature,
            null,
            "add license",
            tree,
            1,
            &parents,
        ));
    }

    // walk the commits
    {
        // init walker
        var walker: ?*c.git_revwalk = null;
        try std.testing.expectEqual(0, c.git_revwalk_new(&walker, repo));
        defer c.git_revwalk_free(walker);
        try std.testing.expectEqual(0, c.git_revwalk_sorting(walker, c.GIT_SORT_TIME));
        try std.testing.expectEqual(0, c.git_revwalk_push_head(walker));

        // init commits list
        var commits: std.ArrayList(?*c.git_commit) = .empty;
        defer {
            for (commits.items) |commit| {
                c.git_commit_free(commit);
            }
            commits.deinit(allocator);
        }

        // walk the commits
        var oid: c.git_oid = undefined;
        while (0 == c.git_revwalk_next(&oid, walker)) {
            var commit: ?*c.git_commit = null;
            try std.testing.expectEqual(0, c.git_commit_lookup(&commit, repo, &oid));
            {
                errdefer c.git_commit_free(commit);
                try commits.append(allocator, commit);
            }
        }

        // check the commit messages
        try std.testing.expectEqual(2, commits.items.len);
        try std.testing.expectEqualStrings("add license", std.mem.sliceTo(c.git_commit_message(commits.items[0]), 0));
        try std.testing.expectEqualStrings("let there be light", std.mem.sliceTo(c.git_commit_message(commits.items[1]), 0));

        // diff the commits
        for (0..commits.items.len) |i| {
            const commit = commits.items[i];

            const commit_oid = c.git_commit_tree_id(commit);
            var commit_tree: ?*c.git_tree = null;
            try std.testing.expectEqual(0, c.git_tree_lookup(&commit_tree, repo, commit_oid));
            defer c.git_tree_free(commit_tree);

            var prev_commit_tree: ?*c.git_tree = null;

            if (i < commits.items.len - 1) {
                const prev_commit = commits.items[i + 1];
                const prev_commit_oid = c.git_commit_tree_id(prev_commit);
                try std.testing.expectEqual(0, c.git_tree_lookup(&prev_commit_tree, repo, prev_commit_oid));
            }
            defer if (prev_commit_tree) |ptr| c.git_tree_free(ptr);

            var commit_diff: ?*c.git_diff = null;
            try std.testing.expectEqual(0, c.git_diff_tree_to_tree(&commit_diff, repo, prev_commit_tree, commit_tree, null));
            defer c.git_diff_free(commit_diff);

            const delta_count = c.git_diff_num_deltas(commit_diff);
            for (0..delta_count) |delta_index| {
                var commit_patch: ?*c.git_patch = null;
                try std.testing.expectEqual(0, c.git_patch_from_diff(&commit_patch, commit_diff, delta_index));
                defer c.git_patch_free(commit_patch);

                var commit_buf: c.git_buf = std.mem.zeroes(c.git_buf);
                try std.testing.expectEqual(0, c.git_patch_to_buf(&commit_buf, commit_patch));
                defer c.git_buf_dispose(&commit_buf);
            }
        }
    }

    // status
    {
        // modify file
        var readme = try repo_dir.openFile(io, "README", .{ .mode = .read_write });
        defer readme.close(io);
        try readme.writeStreamingAll(io, "My really cool project");

        // make dirs
        var a_dir = try repo_dir.createDirPathOpen(io, "a", .{});
        defer a_dir.close(io);
        var b_dir = try repo_dir.createDirPathOpen(io, "b", .{});
        defer b_dir.close(io);
        var c_dir = try repo_dir.createDirPathOpen(io, "c", .{});
        defer c_dir.close(io);

        // make file in dir
        var farewell_txt = try a_dir.createFile(io, "farewell.txt", .{});
        defer farewell_txt.close(io);
        try farewell_txt.writeStreamingAll(io, "Farewell");

        // delete file
        try repo_dir.deleteFile(io, "CHANGELOG");

        // modify indexed files
        const hello_txt = try repo_dir.openFile(io, "hello.txt", .{ .mode = .read_write });
        defer hello_txt.close(io);
        try hello_txt.writeStreamingAll(io, "hello, world again!");
        try repo_dir.deleteFile(io, "LICENSE");

        // make file
        var goodbye_txt = try repo_dir.createFile(io, "goodbye.txt", .{});
        defer goodbye_txt.close(io);
        try goodbye_txt.writeStreamingAll(io, "Goodbye");

        // add the files
        var index: ?*c.git_index = null;
        try std.testing.expectEqual(0, c.git_repository_index(&index, repo));
        defer c.git_index_free(index);
        try std.testing.expectEqual(0, c.git_index_add_bypath(index, "hello.txt"));
        try std.testing.expectEqual(0, c.git_index_add_bypath(index, "goodbye.txt"));
        try std.testing.expectEqual(0, c.git_index_remove_bypath(index, "LICENSE"));
        try std.testing.expectEqual(0, c.git_index_write(index));

        // get status
        var status_list: ?*c.git_status_list = null;
        var status_options: c.git_status_options = undefined;
        try std.testing.expectEqual(0, c.git_status_options_init(&status_options, c.GIT_STATUS_OPTIONS_VERSION));
        status_options.show = c.GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
        status_options.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED;
        try std.testing.expectEqual(0, c.git_status_list_new(&status_list, repo, &status_options));
        defer c.git_status_list_free(status_list);
        const entry_count = c.git_status_list_entrycount(status_list);
        try std.testing.expectEqual(6, entry_count);

        // loop over results
        for (0..entry_count) |i| {
            const entry = c.git_status_byindex(status_list, i);
            try std.testing.expect(null != entry);
            const status_kind: c_int = @intCast(entry.*.status);
            if (c.GIT_STATUS_INDEX_NEW & status_kind != 0) {
                const old_path = entry.*.head_to_index.*.old_file.path;
                try std.testing.expect(null != old_path);
            }
            if (c.GIT_STATUS_INDEX_MODIFIED & status_kind != 0) {
                const old_path = entry.*.head_to_index.*.old_file.path;
                try std.testing.expect(null != old_path);
            }
            if (c.GIT_STATUS_INDEX_DELETED & status_kind != 0) {
                const old_path = entry.*.head_to_index.*.old_file.path;
                try std.testing.expect(null != old_path);
            }
            if (c.GIT_STATUS_WT_NEW & status_kind != 0) {
                const old_path = entry.*.index_to_workdir.*.old_file.path;
                try std.testing.expect(null != old_path);
            }
            if (c.GIT_STATUS_WT_MODIFIED & status_kind != 0) {
                const old_path = entry.*.index_to_workdir.*.old_file.path;
                try std.testing.expect(null != old_path);
            }
            if (c.GIT_STATUS_WT_DELETED & status_kind != 0) {
                const old_path = entry.*.index_to_workdir.*.old_file.path;
                try std.testing.expect(null != old_path);
            }
        }

        // get diff between HEAD and workdir
        {
            // head oid
            var head_object: ?*c.git_object = null;
            try std.testing.expectEqual(0, c.git_revparse_single(&head_object, repo, "HEAD"));
            defer c.git_object_free(head_object);
            const head_oid = c.git_object_id(head_object);

            // commit
            var commit: ?*c.git_commit = null;
            try std.testing.expectEqual(0, c.git_commit_lookup(&commit, repo, head_oid));
            defer c.git_commit_free(commit);

            // commit tree
            const commit_oid = c.git_commit_tree_id(commit);
            var commit_tree: ?*c.git_tree = null;
            try std.testing.expectEqual(0, c.git_tree_lookup(&commit_tree, repo, commit_oid));
            defer c.git_tree_free(commit_tree);

            // diff
            var status_diff: ?*c.git_diff = null;
            try std.testing.expectEqual(0, c.git_diff_tree_to_workdir(&status_diff, repo, commit_tree, null));
            defer c.git_diff_free(status_diff);

            var modified_files = std.StringHashMap(void).init(allocator);
            defer modified_files.deinit();

            const delta_count = c.git_diff_num_deltas(status_diff);
            for (0..delta_count) |delta_index| {
                const delta = c.git_diff_get_delta(status_diff, delta_index);
                try modified_files.put(std.mem.sliceTo(delta.*.old_file.path, 0), {});

                var patch: ?*c.git_patch = null;
                try std.testing.expectEqual(0, c.git_patch_from_diff(&patch, status_diff, delta_index));
                defer c.git_patch_free(patch);

                var buf: c.git_buf = std.mem.zeroes(c.git_buf);
                try std.testing.expectEqual(0, c.git_patch_to_buf(&buf, patch));
                defer c.git_buf_dispose(&buf);
            }

            try std.testing.expectEqual(4, modified_files.count());
            try std.testing.expect(modified_files.contains("LICENSE"));
            try std.testing.expect(modified_files.contains("hello.txt"));
            try std.testing.expect(modified_files.contains("README"));
            try std.testing.expect(modified_files.contains("CHANGELOG"));
        }
    }

    // create root widget
    var root = main.Widget{ .git_ui = try g_ui.GitUI(main.Widget).init(allocator, repo) };
    defer root.deinit(allocator);
    try root.build(allocator, .{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 200, .height = 50 },
    }, root.getFocus());

    // get leaf widget to focus on
    // (the lazy way of doing it is just to get the largest id)
    try std.testing.expect(root.getFocus().children.count() > 0);
    var leaf_id = root.getFocus().id;
    var iter = root.getFocus().children.iterator();
    while (iter.next()) |child| {
        if (child.key_ptr.* > leaf_id and child.value_ptr.focus.focusable) {
            leaf_id = child.key_ptr.*;
        }
    }

    // focus on widget
    try root.getFocus().setFocus(leaf_id);
    try std.testing.expectEqual(leaf_id, root.getFocus().grandchild_id);
}
