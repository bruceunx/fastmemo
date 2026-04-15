//! tests.zig — integration test suite
const std = @import("std");
const storage = @import("storage");
const search = @import("search");
const aaak = @import("aaak");
const mining = @import("mining");

// Re-export module tests so `zig build test` picks them up
comptime {
    _ = @import("aaak");
    _ = @import("search");
    _ = @import("mining");
}

test "drawer store open/insert/query" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(db_path);
    const full = try std.fmt.allocPrint(alloc, "{s}/test.sqlite3", .{db_path});
    defer alloc.free(full);

    var store = try storage.DrawerStore.open(alloc, full);
    defer store.close();

    const id = try storage.computeDrawerId(alloc, "wing_test", "auth", "/src/auth.py", 0);
    defer alloc.free(id);

    try store.insert(.{
        .id = id,
        .wing = "wing_test",
        .room = "auth",
        .hall = .facts,
        .content = "We decided to use Clerk for authentication because of pricing.",
        .source_file = "/src/auth.py",
        .chunk_index = 0,
        .added_by = "test",
        .filed_at = "2026-01-01",
        .importance = 0.8,
        .emotional_weight = 0.0,
    });

    const count = try store.count();
    try std.testing.expectEqual(@as(i64, 1), count);

    const exists = try store.fileExists("/src/auth.py");
    try std.testing.expect(exists);

    const drawers = try store.query(alloc, "wing_test", null, 10);
    defer {
        for (drawers) |*d| {
            var dd = d.*;
            dd.deinit(alloc);
        }
        alloc.free(drawers);
    }
    try std.testing.expectEqual(@as(usize, 1), drawers.len);
    try std.testing.expectEqualStrings("auth", drawers[0].room);
}

test "knowledge graph triple add/query/invalidate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(db_path);
    const full = try std.fmt.allocPrint(alloc, "{s}/kg.sqlite3", .{db_path});
    defer alloc.free(full);

    var kg = try storage.KnowledgeGraph.open(alloc, full);
    defer kg.close();

    try kg.addTriple("Alice", "works_on", "Orion", "2025-06-01", null);
    try kg.addTriple("Alice", "completed", "auth-migration", "2026-02-01", null);

    const triples = try kg.queryEntity(alloc, "Alice", null);
    defer {
        for (triples) |*t| {
            var tt = t.*;
            tt.deinit(alloc);
        }
        alloc.free(triples);
    }
    try std.testing.expectEqual(@as(usize, 2), triples.len);

    try kg.invalidate("Alice", "works_on", "Orion", "2026-03-01");
    const after = try kg.queryEntity(alloc, "Alice", null); // current only
    defer {
        for (after) |*t| {
            var tt = t.*;
            tt.deinit(alloc);
        }
        alloc.free(after);
    }
    // works_on is now ended, should not appear in current query
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("completed", after[0].predicate);
}

test "search over drawers" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(db_path);
    const full = try std.fmt.allocPrint(alloc, "{s}/search.sqlite3", .{db_path});
    defer alloc.free(full);

    var store = try storage.DrawerStore.open(alloc, full);
    defer store.close();

    const docs = [_]struct { room: []const u8, content: []const u8 }{
        .{ .room = "auth", .content = "We switched from custom JWT to Clerk for authentication to reduce maintenance burden." },
        .{ .room = "billing", .content = "Stripe integration was completed. All billing now goes through Stripe checkout." },
        .{ .room = "deploy", .content = "Deployed to production using Kubernetes. Rollback plan is in place." },
    };
    for (docs, 0..) |doc, idx| {
        const src = try std.fmt.allocPrint(alloc, "/src/{s}.md", .{doc.room});
        defer alloc.free(src);
        const did = try storage.computeDrawerId(alloc, "wing_proj", doc.room, src, 0);
        defer alloc.free(did);
        const seq: u32 = @intCast(idx);
        _ = seq;
        try store.insert(.{
            .id = did,
            .wing = "wing_proj",
            .room = doc.room,
            .hall = .facts,
            .content = doc.content,
            .source_file = src,
            .chunk_index = 0,
            .added_by = "test",
            .filed_at = "2026-01-01",
            .importance = 0.7,
            .emotional_weight = 0.0,
        });
    }

    var searcher = search.Searcher.init(&store, alloc);
    const results = try searcher.search("authentication Clerk JWT", null, null, 3);
    defer {
        for (results) |*r| {
            var rr = r.*;
            rr.deinit(alloc);
        }
        alloc.free(results);
    }

    // auth drawer should rank first
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqualStrings("auth", results[0].room);
}

test "aaak compress and format" {
    const alloc = std.testing.allocator;
    var known = std.StringHashMap([]const u8).init(alloc);
    defer known.deinit();
    try known.put("Alice", "ALI");

    const entry = try aaak.compress(
        alloc,
        "Alice decided to migrate auth to Clerk because of better pricing and developer experience.",
        "wing_proj",
        "auth",
        "2026-04-01",
        "meeting_notes",
        known,
    );
    defer {
        alloc.free(entry.wing);
        alloc.free(entry.room);
        alloc.free(entry.date);
        alloc.free(entry.source_stem);
        alloc.free(entry.entities);
        alloc.free(entry.topic);
        alloc.free(entry.key_sentence);
        alloc.free(entry.emotion);
        alloc.free(entry.flag);
    }

    try std.testing.expect(std.mem.indexOf(u8, entry.entities, "ALI") != null);
    try std.testing.expectEqualStrings("DECISION", entry.flag);
    try std.testing.expect(entry.key_sentence.len <= 55);

    var buf: [512]u8 = undefined;
    const n = try entry.format(&buf);
    const line = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, line, "DECISION") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "wing_proj") != null);
}

test "mining chunk sizes" {
    const alloc = std.testing.allocator;
    // Build a 3000-char string
    var content = try alloc.alloc(u8, 3000);
    defer alloc.free(content);
    for (content, 0..) |*b, idx| b.* = if (idx % 100 == 99) '\n' else 'a';

    const chunks = try mining.chunk(alloc, content);
    defer {
        for (chunks) |c| alloc.free(c);
        alloc.free(chunks);
    }

    for (chunks) |c| {
        try std.testing.expect(c.len >= 50);
        try std.testing.expect(c.len <= 900); // at most chunk size + small overshoot
    }
    try std.testing.expect(chunks.len >= 3);
}
