//! mining/lib.zig — Project file and conversation ingest pipeline.
//! Chunking: 800-char chunks, 100-char overlap, paragraph/line boundaries.
//! Room assignment: 4-priority cascade (path > filename > keyword > fallback).
//! Supported formats: plain text, markdown, code files.

const std = @import("std");
const storage = @import("storage");
const aaak = @import("aaak");

pub const MineError = error{ OutOfMemory, IoError, StorageError };

pub const MineMode = enum { projects, convos, general };

/// Category scores for the general extractor.
const Category = enum { decision, preference, milestone, problem, emotional, general };
const CATEGORY_KEYWORDS = struct {
    const decisions = [_][]const u8{ "decided", "chose", "will use", "agreed", "switched to", "going with", "approved", "rejected" };
    const preferences = [_][]const u8{ "prefer", "like", "love", "hate", "always use", "never use", "favorite", "dislike" };
    const milestones = [_][]const u8{ "shipped", "launched", "completed", "finished", "deployed", "merged", "released" };
    const problems = [_][]const u8{ "bug", "broken", "failed", "error", "issue", "problem", "crash", "doesn't work" };
    const emotional = [_][]const u8{ "frustrated", "excited", "confused", "worried", "annoyed", "happy", "concerned" };
};

const SUPPORTED_EXTENSIONS = [_][]const u8{
    ".txt", ".md",   ".markdown", ".py",   ".js",   ".ts", ".jsx",  ".tsx",
    ".go",  ".rs",   ".zig",      ".c",    ".cpp",  ".h",  ".java", ".rb",
    ".sh",  ".yaml", ".yml",      ".toml", ".json",
};

const SKIP_DIRS = [_][]const u8{
    "node_modules", ".git",   "__pycache__", "target", "dist",      "build",
    ".cache",       "vendor", "venv",        ".venv",  "zig-cache", "zig-out",
};

pub const MineOptions = struct {
    mode: MineMode = .projects,
    wing: ?[]const u8 = null, // override auto-detected wing
    added_by: []const u8 = "cli",
};

pub const Miner = struct {
    store: *storage.DrawerStore,
    alloc: std.mem.Allocator,
    stats: struct {
        files_seen: u32 = 0,
        files_skipped: u32 = 0, // already indexed
        chunks_inserted: u32 = 0,
    } = .{},

    pub fn init(store: *storage.DrawerStore, alloc: std.mem.Allocator) Miner {
        return .{ .store = store, .alloc = alloc };
    }

    /// Mine a directory tree.
    pub fn mineDir(self: *Miner, dir_path: []const u8, opts: MineOptions) MineError!void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return MineError.IoError;
        defer dir.close();
        try self.walkDir(dir, dir_path, opts);
    }

    fn walkDir(self: *Miner, dir: std.fs.Dir, base_path: []const u8, opts: MineOptions) MineError!void {
        var iter = dir.iterate();
        while (iter.next() catch return MineError.IoError) |entry| {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            if (entry.kind == .directory) {
                if (isSkipDir(entry.name)) continue;
                var sub = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer sub.close();
                const sub_path = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ base_path, entry.name }) catch return MineError.OutOfMemory;
                defer self.alloc.free(sub_path);
                try self.walkDir(sub, sub_path, opts);
            } else if (entry.kind == .file) {
                if (!isSupportedExtension(entry.name)) continue;
                const file_path = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ base_path, entry.name }) catch return MineError.OutOfMemory;
                defer self.alloc.free(file_path);
                self.stats.files_seen += 1;
                self.mineFile(file_path, entry.name, opts) catch |err| {
                    if (err == MineError.StorageError) continue; // skip failed files
                    return err;
                };
            }
        }
    }

    fn mineFile(self: *Miner, file_path: []const u8, filename: []const u8, opts: MineOptions) MineError!void {
        // File-level dedup
        const exists = self.store.fileExists(file_path) catch return MineError.StorageError;
        if (exists) {
            self.stats.files_skipped += 1;
            return;
        }

        const content = readFile(self.alloc, file_path) catch return MineError.IoError;
        defer self.alloc.free(content);

        if (content.len < 10) return;

        const wing = opts.wing orelse detectWing(self.alloc, file_path) catch "wing_general";
        const room = detectRoom(file_path, filename, content);
        const hall = switch (opts.mode) {
            .general => classifyHall(content),
            .convos => .events,
            .projects => .general,
        };

        const chunks = try chunk(self.alloc, content);
        defer {
            for (chunks) |c| self.alloc.free(c);
            self.alloc.free(chunks);
        }

        const now = isoNow(self.alloc) catch "2026-01-01";
        defer self.alloc.free(now);

        for (chunks, 0..) |ch, i| {
            const id = storage.computeDrawerId(self.alloc, wing, room, file_path, @intCast(i)) catch return MineError.OutOfMemory;
            defer self.alloc.free(id);

            const importance = scoreImportance(ch);
            const drawer = storage.Drawer{
                .id = id,
                .wing = wing,
                .room = room,
                .hall = hall,
                .content = ch,
                .source_file = file_path,
                .chunk_index = @intCast(i),
                .added_by = opts.added_by,
                .filed_at = now,
                .importance = importance,
                .emotional_weight = scoreEmotion(ch),
            };
            self.store.insert(drawer) catch return MineError.StorageError;
            self.stats.chunks_inserted += 1;
        }
    }
};

// ─── Chunking ─────────────────────────────────────────────────────────────────

const CHUNK_SIZE: usize = 800;
const CHUNK_OVERLAP: usize = 100;
const MIN_CHUNK: usize = 50;

/// Split content into overlapping chunks. Caller owns result.
pub fn chunk(alloc: std.mem.Allocator, content: []const u8) MineError![][]u8 {
    var chunks = std.array_list.Managed([]u8).init(alloc);
    if (content.len <= CHUNK_SIZE) {
        if (content.len >= MIN_CHUNK)
            try chunks.append(alloc.dupe(u8, content) catch return MineError.OutOfMemory);
        return chunks.toOwnedSlice() catch return MineError.OutOfMemory;
    }

    var start: usize = 0;
    while (start < content.len) {
        var end = @min(start + CHUNK_SIZE, content.len);
        // Prefer paragraph boundary
        if (end < content.len) {
            if (std.mem.lastIndexOf(u8, content[start..end], "\n\n")) |p| {
                end = start + p + 2;
            } else if (std.mem.lastIndexOf(u8, content[start..end], "\n")) |p| {
                end = start + p + 1;
            }
        }
        const slice = content[start..end];
        if (slice.len >= MIN_CHUNK)
            try chunks.append(alloc.dupe(u8, slice) catch return MineError.OutOfMemory);
        if (end >= content.len) break;
        start = if (end > CHUNK_OVERLAP) end - CHUNK_OVERLAP else 0;
    }
    return chunks.toOwnedSlice() catch return MineError.OutOfMemory;
}

// ─── Room/Wing detection ──────────────────────────────────────────────────────

const KNOWN_ROOMS = [_][]const u8{
    "auth",      "billing",  "deploy",      "infra",  "frontend",   "backend",
    "api",       "database", "cache",       "queue",  "monitoring", "testing",
    "docs",      "security", "performance", "ci",     "cd",         "pipeline",
    "migration", "config",   "storage",     "search",
};

fn detectRoom(path: []const u8, filename: []const u8, content: []const u8) []const u8 {
    // Priority 1: path segment matches known room
    for (KNOWN_ROOMS) |r| {
        if (std.mem.indexOf(u8, path, r) != null) return r;
    }
    // Priority 2: filename stem
    const stem = std.fs.path.stem(filename);
    for (KNOWN_ROOMS) |r| {
        if (std.mem.eql(u8, stem, r)) return r;
    }
    // Priority 3: keyword frequency in first 2000 chars
    const scan = content[0..@min(content.len, 2000)];
    var best_room: []const u8 = "general";
    var best_count: u32 = 0;
    for (KNOWN_ROOMS) |r| {
        const cnt = countKeyword(scan, r);
        if (cnt > best_count) {
            best_count = cnt;
            best_room = r;
        }
    }
    if (best_count >= 2) return best_room;
    return "general";
}

fn detectWing(alloc: std.mem.Allocator, path: []const u8) MineError![]const u8 {
    // Use top-level directory component after base as wing name
    var parts = std.mem.splitScalar(u8, path, '/');
    var last_dir: []const u8 = "general";
    while (parts.next()) |p| {
        if (p.len > 0) last_dir = p;
    }
    const wing = try std.fmt.allocPrint(alloc, "wing_{s}", .{last_dir});
    return wing;
}

fn classifyHall(content: []const u8) storage.Hall {
    var max_score: u32 = 0;
    var best: storage.Hall = .general;

    inline for (.{
        .{ CATEGORY_KEYWORDS.decisions, storage.Hall.facts },
        .{ CATEGORY_KEYWORDS.preferences, storage.Hall.preferences },
        .{ CATEGORY_KEYWORDS.milestones, storage.Hall.events },
        .{ CATEGORY_KEYWORDS.problems, storage.Hall.discoveries },
        .{ CATEGORY_KEYWORDS.emotional, storage.Hall.advice },
    }) |pair| {
        var score: u32 = 0;
        for (pair[0]) |kw| score += countKeyword(content, kw);
        if (score > max_score) {
            max_score = score;
            best = pair[1];
        }
    }
    return best;
}

fn scoreImportance(content: []const u8) f32 {
    var score: f32 = 0.5;
    const IMPORTANT = [_][]const u8{ "decided", "critical", "never", "always", "shipped", "bug", "IMPORTANT", "TODO", "FIXME" };
    for (IMPORTANT) |kw| {
        if (std.mem.indexOf(u8, content, kw) != null) score += 0.1;
    }
    return @min(score, 1.0);
}

fn scoreEmotion(content: []const u8) f32 {
    const EMOTION_WORDS = [_][]const u8{ "frustrated", "excited", "confused", "worried", "annoyed" };
    var score: f32 = 0.0;
    for (EMOTION_WORDS) |kw| {
        if (std.mem.indexOf(u8, content, kw) != null) score += 0.2;
    }
    return @min(score, 1.0);
}

fn countKeyword(text: []const u8, kw: []const u8) u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i + kw.len <= text.len) {
        if (std.mem.eql(u8, text[i .. i + kw.len], kw)) {
            count += 1;
            i += kw.len;
        } else i += 1;
    }
    return count;
}

fn isSkipDir(name: []const u8) bool {
    for (SKIP_DIRS) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn isSupportedExtension(name: []const u8) bool {
    for (SUPPORTED_EXTENSIONS) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const max = 1024 * 1024; // 1 MB cap per file
    return file.readToEndAlloc(alloc, max);
}

fn isoNow(alloc: std.mem.Allocator) ![]u8 {
    const epoch_s = @divFloor(std.time.milliTimestamp(), 1000);
    // Correct Gregorian calendar from Unix epoch (civil_from_days algorithm)
    const z: i64 = @divFloor(epoch_s, 86400) + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = if (m <= 2) y + 1 else y;
    return std.fmt.allocPrint(alloc, "{d:04}-{d:02}-{d:02}", .{ year, m, d });
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "chunking short content" {
    const alloc = std.testing.allocator;
    const content = "Short content that fits in one chunk.";
    const chunks = try chunk(alloc, content);
    defer {
        for (chunks) |c| alloc.free(c);
        alloc.free(chunks);
    }
    try std.testing.expectEqual(@as(usize, 0), chunks.len); // too short (< 50)
}

test "chunking long content produces multiple chunks" {
    const alloc = std.testing.allocator;
    var buf: [2000]u8 = undefined;
    @memset(&buf, 'x');
    for (&buf, 0..) |*b, i| if (i % 80 == 79) {
        b.* = '\n';
    };
    const chunks = try chunk(alloc, &buf);
    defer {
        for (chunks) |c| alloc.free(c);
        alloc.free(chunks);
    }
    try std.testing.expect(chunks.len >= 2);
}

test "room detection from path" {
    try std.testing.expectEqualStrings("auth", detectRoom("/project/auth/middleware.py", "middleware.py", ""));
    try std.testing.expectEqualStrings("general", detectRoom("/project/misc/stuff.py", "stuff.py", ""));
}
