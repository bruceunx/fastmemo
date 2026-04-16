//! storage/lib.zig — Drawer store + Knowledge Graph
//! Uses SQLite via the C ABI (link with -lsqlite3).
//! Palace layout: Wing → Room → Hall → Drawer (verbatim chunk).

const std = @import("std");
const c = @cImport(@cInclude("sqlite3.h"));

pub const StorageError = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    StepFailed,
    NotFound,
    OutOfMemory,
    InvalidUtf8,
};

// ─── Drawer ──────────────────────────────────────────────────────────────────

pub const Hall = enum {
    facts,
    events,
    discoveries,
    preferences,
    advice,
    diary,
    general,

    pub fn fromStr(s: []const u8) Hall {
        const map = .{
            .{ "hall_facts", .facts },
            .{ "hall_events", .events },
            .{ "hall_discoveries", .discoveries },
            .{ "hall_preferences", .preferences },
            .{ "hall_advice", .advice },
            .{ "diary_entry", .diary },
        };
        inline for (map) |pair| {
            if (std.mem.eql(u8, s, pair[0])) return pair[1];
        }
        return .general;
    }

    pub fn toStr(self: Hall) []const u8 {
        return switch (self) {
            .facts => "hall_facts",
            .events => "hall_events",
            .discoveries => "hall_discoveries",
            .preferences => "hall_preferences",
            .advice => "hall_advice",
            .diary => "diary_entry",
            .general => "general",
        };
    }
};

pub const Drawer = struct {
    id: []const u8,
    wing: []const u8,
    room: []const u8,
    hall: Hall,
    content: []const u8,
    source_file: []const u8,
    chunk_index: u32,
    added_by: []const u8,
    filed_at: []const u8, // ISO8601
    importance: f32,
    emotional_weight: f32,

    pub fn deinit(self: *Drawer, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.wing);
        alloc.free(self.room);
        alloc.free(self.content);
        alloc.free(self.source_file);
        alloc.free(self.added_by);
        alloc.free(self.filed_at);
    }
};

/// Compute deterministic drawer ID: drawer_{wing}_{room}_{md5[:16]}
pub fn computeDrawerId(alloc: std.mem.Allocator, wing: []const u8, room: []const u8, source_file: []const u8, chunk_index: u32) ![]u8 {
    var hasher = std.crypto.hash.Md5.init(.{});
    hasher.update(source_file);
    var idx_buf: [16]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{chunk_index}) catch unreachable;
    hasher.update(idx_str);
    var digest: [16]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(alloc, "drawer_{s}_{s}_{s}", .{ wing, room, hex[0..16] });
}

// ─── DrawerStore ─────────────────────────────────────────────────────────────

pub const DrawerStore = struct {
    db: *c.sqlite3,
    alloc: std.mem.Allocator,

    pub fn open(alloc: std.mem.Allocator, path: []const u8) StorageError!DrawerStore {
        var db: ?*c.sqlite3 = null;
        const cpath = alloc.dupeZ(u8, path) catch return StorageError.OutOfMemory;
        defer alloc.free(cpath);
        if (c.sqlite3_open(cpath.ptr, &db) != c.SQLITE_OK) return StorageError.OpenFailed;
        var store = DrawerStore{ .db = db.?, .alloc = alloc };
        try store.migrate();
        return store;
    }

    pub fn close(self: *DrawerStore) void {
        _ = c.sqlite3_close(self.db);
    }

    fn migrate(self: *DrawerStore) StorageError!void {
        const ddl =
            \\CREATE TABLE IF NOT EXISTS drawers (
            \\  id TEXT PRIMARY KEY,
            \\  wing TEXT NOT NULL,
            \\  room TEXT NOT NULL,
            \\  hall TEXT NOT NULL DEFAULT 'general',
            \\  content TEXT NOT NULL,
            \\  source_file TEXT NOT NULL,
            \\  chunk_index INTEGER NOT NULL DEFAULT 0,
            \\  added_by TEXT NOT NULL DEFAULT 'cli',
            \\  filed_at TEXT NOT NULL,
            \\  importance REAL NOT NULL DEFAULT 0.5,
            \\  emotional_weight REAL NOT NULL DEFAULT 0.0
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_drawers_wing ON drawers(wing);
            \\CREATE INDEX IF NOT EXISTS idx_drawers_room ON drawers(room);
            \\CREATE INDEX IF NOT EXISTS idx_drawers_wing_room ON drawers(wing, room);
            \\CREATE INDEX IF NOT EXISTS idx_drawers_source ON drawers(source_file);
        ;
        var errmsg: ?[*:0]u8 = null;
        if (c.sqlite3_exec(self.db, ddl, null, null, @ptrCast(&errmsg)) != c.SQLITE_OK) {
            return StorageError.ExecFailed;
        }
    }

    pub fn insert(self: *DrawerStore, d: Drawer) StorageError!void {
        const sql =
            \\INSERT OR REPLACE INTO drawers
            \\  (id,wing,room,hall,content,source_file,chunk_index,added_by,filed_at,importance,emotional_weight)
            \\VALUES (?,?,?,?,?,?,?,?,?,?,?)
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return StorageError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, d.id.ptr, @intCast(d.id.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, d.wing.ptr, @intCast(d.wing.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, d.room.ptr, @intCast(d.room.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, d.hall.toStr().ptr, @intCast(d.hall.toStr().len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 5, d.content.ptr, @intCast(d.content.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 6, d.source_file.ptr, @intCast(d.source_file.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int(stmt, 7, @intCast(d.chunk_index));
        _ = c.sqlite3_bind_text(stmt, 8, d.added_by.ptr, @intCast(d.added_by.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 9, d.filed_at.ptr, @intCast(d.filed_at.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_double(stmt, 10, d.importance);
        _ = c.sqlite3_bind_double(stmt, 11, d.emotional_weight);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return StorageError.StepFailed;
    }

    pub fn fileExists(self: *DrawerStore, source_file: []const u8) StorageError!bool {
        const sql = "SELECT 1 FROM drawers WHERE source_file=? LIMIT 1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return StorageError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, source_file.ptr, @intCast(source_file.len), c.SQLITE_STATIC);
        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }

    pub fn delete(self: *DrawerStore, id: []const u8) StorageError!void {
        const sql = "DELETE FROM drawers WHERE id=?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return StorageError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return StorageError.StepFailed;
    }

    /// Fetch all drawers optionally filtered by wing/room. Caller owns returned slice.
    pub fn query(
        self: *DrawerStore,
        alloc: std.mem.Allocator,
        wing: ?[]const u8,
        room: ?[]const u8,
        limit: u32,
    ) StorageError![]Drawer {
        var sql_buf: [512]u8 = undefined;
        var sql_len: usize = 0;

        const base = "SELECT id,wing,room,hall,content,source_file,chunk_index,added_by,filed_at,importance,emotional_weight FROM drawers";
        @memcpy(sql_buf[0..base.len], base);
        sql_len = base.len;

        if (wing != null and room != null) {
            const cond = " WHERE wing=? AND room=?";
            @memcpy(sql_buf[sql_len..][0..cond.len], cond);
            sql_len += cond.len;
        } else if (wing != null) {
            const cond = " WHERE wing=?";
            @memcpy(sql_buf[sql_len..][0..cond.len], cond);
            sql_len += cond.len;
        } else if (room != null) {
            const cond = " WHERE room=?";
            @memcpy(sql_buf[sql_len..][0..cond.len], cond);
            sql_len += cond.len;
        }
        const lim = std.fmt.bufPrint(sql_buf[sql_len..], " ORDER BY importance DESC LIMIT {d}", .{limit}) catch return StorageError.ExecFailed;
        sql_len += lim.len;
        sql_buf[sql_len] = 0;

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, &sql_buf, @intCast(sql_len + 1), &stmt, null) != c.SQLITE_OK)
            return StorageError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        var bind_idx: c_int = 1;
        if (wing) |w| {
            _ = c.sqlite3_bind_text(stmt, bind_idx, w.ptr, @intCast(w.len), c.SQLITE_STATIC);
            bind_idx += 1;
        }
        if (room) |r| {
            _ = c.sqlite3_bind_text(stmt, bind_idx, r.ptr, @intCast(r.len), c.SQLITE_STATIC);
        }

        var list = std.array_list.Managed(Drawer).init(alloc);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const drawer = try rowToDrawer(alloc, stmt.?);
            try list.append(drawer);
        }
        return list.toOwnedSlice();
    }

    pub fn listWings(self: *DrawerStore, alloc: std.mem.Allocator) StorageError![][]u8 {
        const sql = "SELECT DISTINCT wing FROM drawers ORDER BY wing";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return StorageError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var list = std.array_list.Managed([]u8).init(alloc);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const raw = c.sqlite3_column_text(stmt, 0);
            const s = std.mem.span(raw);
            try list.append(try alloc.dupe(u8, s));
        }
        return list.toOwnedSlice();
    }

    pub fn listRooms(self: *DrawerStore, alloc: std.mem.Allocator, wing: ?[]const u8) StorageError![][]u8 {
        var stmt: ?*c.sqlite3_stmt = null;
        if (wing) |w| {
            const sql = "SELECT DISTINCT room FROM drawers WHERE wing=? ORDER BY room";
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return StorageError.PrepareFailed;
            _ = c.sqlite3_bind_text(stmt, 1, w.ptr, @intCast(w.len), c.SQLITE_STATIC);
        } else {
            const sql = "SELECT DISTINCT room FROM drawers ORDER BY room";
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return StorageError.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);
        var list = std.array_list.Managed([]u8).init(alloc);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const raw = c.sqlite3_column_text(stmt, 0);
            const s = std.mem.span(raw);
            try list.append(try alloc.dupe(u8, s));
        }
        return list.toOwnedSlice();
    }

    pub fn count(self: *DrawerStore) StorageError!i64 {
        const sql = "SELECT COUNT(*) FROM drawers";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return StorageError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return c.sqlite3_column_int64(stmt, 0);
    }

    fn rowToDrawer(alloc: std.mem.Allocator, stmt: *c.sqlite3_stmt) StorageError!Drawer {
        const col = struct {
            fn text(s: *c.sqlite3_stmt, idx: c_int, a: std.mem.Allocator) StorageError![]u8 {
                const raw = c.sqlite3_column_text(s, idx);
                if (raw == null) return a.dupe(u8, "") catch return StorageError.OutOfMemory;
                return a.dupe(u8, std.mem.span(raw)) catch return StorageError.OutOfMemory;
            }
        };
        return Drawer{
            .id = try col.text(stmt, 0, alloc),
            .wing = try col.text(stmt, 1, alloc),
            .room = try col.text(stmt, 2, alloc),
            .hall = Hall.fromStr(std.mem.span(c.sqlite3_column_text(stmt, 3))),
            .content = try col.text(stmt, 4, alloc),
            .source_file = try col.text(stmt, 5, alloc),
            .chunk_index = @intCast(c.sqlite3_column_int(stmt, 6)),
            .added_by = try col.text(stmt, 7, alloc),
            .filed_at = try col.text(stmt, 8, alloc),
            .importance = @floatCast(c.sqlite3_column_double(stmt, 9)),
            .emotional_weight = @floatCast(c.sqlite3_column_double(stmt, 10)),
        };
    }
};

// ─── Knowledge Graph ──────────────────────────────────────────────────────────

pub const Triple = struct {
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    valid_from: ?[]const u8,
    valid_to: ?[]const u8,
    confidence: f32,

    pub fn deinit(self: *Triple, alloc: std.mem.Allocator) void {
        alloc.free(self.subject);
        alloc.free(self.predicate);
        alloc.free(self.object);
        if (self.valid_from) |v| alloc.free(v);
        if (self.valid_to) |v| alloc.free(v);
    }
};

pub const KnowledgeGraph = struct {
    db: *c.sqlite3,
    alloc: std.mem.Allocator,

    pub fn open(alloc: std.mem.Allocator, path: []const u8) StorageError!KnowledgeGraph {
        var db: ?*c.sqlite3 = null;
        const cpath = alloc.dupeZ(u8, path) catch return StorageError.OutOfMemory;
        defer alloc.free(cpath);
        if (c.sqlite3_open(cpath.ptr, &db) != c.SQLITE_OK) return StorageError.OpenFailed;
        var kg = KnowledgeGraph{ .db = db.?, .alloc = alloc };
        try kg.migrate();
        return kg;
    }

    pub fn close(self: *KnowledgeGraph) void {
        _ = c.sqlite3_close(self.db);
    }

    fn migrate(self: *KnowledgeGraph) StorageError!void {
        const ddl =
            \\CREATE TABLE IF NOT EXISTS entities (
            \\  id TEXT PRIMARY KEY,
            \\  name TEXT NOT NULL,
            \\  type TEXT NOT NULL DEFAULT 'unknown'
            \\);
            \\CREATE TABLE IF NOT EXISTS triples (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  subject TEXT NOT NULL,
            \\  predicate TEXT NOT NULL,
            \\  object TEXT NOT NULL,
            \\  valid_from TEXT,
            \\  valid_to TEXT,
            \\  confidence REAL NOT NULL DEFAULT 1.0,
            \\  source_file TEXT
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_triples_subject ON triples(subject);
            \\CREATE INDEX IF NOT EXISTS idx_triples_predicate ON triples(predicate);
            \\CREATE INDEX IF NOT EXISTS idx_triples_valid ON triples(valid_from, valid_to);
        ;
        var errmsg: ?[*:0]u8 = null;
        if (c.sqlite3_exec(self.db, ddl, null, null, @ptrCast(&errmsg)) != c.SQLITE_OK)
            return StorageError.ExecFailed;
    }

    pub fn addTriple(self: *KnowledgeGraph, subject: []const u8, predicate: []const u8, object: []const u8, valid_from: ?[]const u8, source_file: ?[]const u8) StorageError!void {
        const sql =
            \\INSERT INTO triples (subject,predicate,object,valid_from,confidence,source_file)
            \\VALUES (?,?,?,?,1.0,?)
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return StorageError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, subject.ptr, @intCast(subject.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, predicate.ptr, @intCast(predicate.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, object.ptr, @intCast(object.len), c.SQLITE_STATIC);
        if (valid_from) |v| {
            _ = c.sqlite3_bind_text(stmt, 4, v.ptr, @intCast(v.len), c.SQLITE_STATIC);
        } else {
            _ = c.sqlite3_bind_null(stmt, 4);
        }
        if (source_file) |sf| {
            _ = c.sqlite3_bind_text(stmt, 5, sf.ptr, @intCast(sf.len), c.SQLITE_STATIC);
        } else {
            _ = c.sqlite3_bind_null(stmt, 5);
        }
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return StorageError.StepFailed;
    }

    pub fn invalidate(self: *KnowledgeGraph, subject: []const u8, predicate: []const u8, object: []const u8, ended: []const u8) StorageError!void {
        const sql = "UPDATE triples SET valid_to=? WHERE subject=? AND predicate=? AND object=? AND valid_to IS NULL";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return StorageError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, ended.ptr, @intCast(ended.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, subject.ptr, @intCast(subject.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, predicate.ptr, @intCast(predicate.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, object.ptr, @intCast(object.len), c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return StorageError.StepFailed;
    }

    /// Query triples for an entity. Pass as_of=null for current-only.
    pub fn queryEntity(self: *KnowledgeGraph, alloc: std.mem.Allocator, entity: []const u8, as_of: ?[]const u8) StorageError![]Triple {
        var stmt: ?*c.sqlite3_stmt = null;
        if (as_of) |date| {
            const sql =
                \\SELECT subject,predicate,object,valid_from,valid_to,confidence FROM triples
                \\WHERE (subject=? OR object=?)
                \\  AND (valid_from IS NULL OR valid_from <= ?)
                \\  AND (valid_to IS NULL OR valid_to >= ?)
                \\ORDER BY valid_from ASC
            ;
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return StorageError.PrepareFailed;
            _ = c.sqlite3_bind_text(stmt, 1, entity.ptr, @intCast(entity.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, 2, entity.ptr, @intCast(entity.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, 3, date.ptr, @intCast(date.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, 4, date.ptr, @intCast(date.len), c.SQLITE_STATIC);
        } else {
            const sql =
                \\SELECT subject,predicate,object,valid_from,valid_to,confidence FROM triples
                \\WHERE (subject=? OR object=?) AND valid_to IS NULL
                \\ORDER BY valid_from ASC
            ;
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return StorageError.PrepareFailed;
            _ = c.sqlite3_bind_text(stmt, 1, entity.ptr, @intCast(entity.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, 2, entity.ptr, @intCast(entity.len), c.SQLITE_STATIC);
        }
        defer _ = c.sqlite3_finalize(stmt);
        return collectTriples(alloc, stmt.?);
    }

    pub fn timeline(self: *KnowledgeGraph, alloc: std.mem.Allocator, entity: []const u8) StorageError![]Triple {
        const sql =
            \\SELECT subject,predicate,object,valid_from,valid_to,confidence FROM triples
            \\WHERE subject=? OR object=?
            \\ORDER BY COALESCE(valid_from,'') ASC
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return StorageError.PrepareFailed;
        _ = c.sqlite3_bind_text(stmt, 1, entity.ptr, @intCast(entity.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, entity.ptr, @intCast(entity.len), c.SQLITE_STATIC);
        defer _ = c.sqlite3_finalize(stmt);
        return collectTriples(alloc, stmt.?);
    }

    pub fn stats(self: *KnowledgeGraph) StorageError!struct { entities: i64, triples: i64, active: i64 } {
        var ec: i64 = 0;
        var tc: i64 = 0;
        var ac: i64 = 0;
        {
            const sql = "SELECT COUNT(*) FROM entities";
            var s: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &s, null) == c.SQLITE_OK) {
                if (c.sqlite3_step(s) == c.SQLITE_ROW) ec = c.sqlite3_column_int64(s, 0);
                _ = c.sqlite3_finalize(s);
            }
        }
        {
            const sql = "SELECT COUNT(*) FROM triples";
            var s: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &s, null) == c.SQLITE_OK) {
                if (c.sqlite3_step(s) == c.SQLITE_ROW) tc = c.sqlite3_column_int64(s, 0);
                _ = c.sqlite3_finalize(s);
            }
        }
        {
            const sql = "SELECT COUNT(*) FROM triples WHERE valid_to IS NULL";
            var s: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &s, null) == c.SQLITE_OK) {
                if (c.sqlite3_step(s) == c.SQLITE_ROW) ac = c.sqlite3_column_int64(s, 0);
                _ = c.sqlite3_finalize(s);
            }
        }
        return .{ .entities = ec, .triples = tc, .active = ac };
    }

    fn collectTriples(alloc: std.mem.Allocator, stmt: *c.sqlite3_stmt) StorageError![]Triple {
        var list = std.array_list.Managed(Triple).init(alloc);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const t = Triple{
                .subject = try dupeCol(alloc, stmt, 0),
                .predicate = try dupeCol(alloc, stmt, 1),
                .object = try dupeCol(alloc, stmt, 2),
                .valid_from = blk: {
                    const raw = c.sqlite3_column_text(stmt, 3);
                    if (raw == null) break :blk null;
                    break :blk try alloc.dupe(u8, std.mem.span(raw));
                },
                .valid_to = blk: {
                    const raw = c.sqlite3_column_text(stmt, 4);
                    if (raw == null) break :blk null;
                    break :blk try alloc.dupe(u8, std.mem.span(raw));
                },
                .confidence = @floatCast(c.sqlite3_column_double(stmt, 5)),
            };
            list.append(t) catch return StorageError.OutOfMemory;
        }
        return list.toOwnedSlice() catch return StorageError.OutOfMemory;
    }

    fn dupeCol(alloc: std.mem.Allocator, stmt: *c.sqlite3_stmt, idx: c_int) StorageError![]u8 {
        const raw = c.sqlite3_column_text(stmt, idx);
        if (raw == null) return alloc.dupe(u8, "") catch return StorageError.OutOfMemory;
        return alloc.dupe(u8, std.mem.span(raw)) catch return StorageError.OutOfMemory;
    }
};

// ─── Palace (combined handle) ─────────────────────────────────────────────────

pub const Palace = struct {
    drawers: DrawerStore,
    kg: KnowledgeGraph,
    alloc: std.mem.Allocator,
    path: []u8,

    pub fn open(alloc: std.mem.Allocator, palace_path: []const u8) !Palace {
        try std.fs.cwd().makePath(palace_path);
        const drawer_path = try std.fs.path.join(alloc, &.{ palace_path, "palace.sqlite3" });
        defer alloc.free(drawer_path);
        const kg_path = try std.fs.path.join(alloc, &.{ palace_path, "knowledge_graph.sqlite3" });
        defer alloc.free(kg_path);

        return Palace{
            .drawers = try DrawerStore.open(alloc, drawer_path),
            .kg = try KnowledgeGraph.open(alloc, kg_path),
            .alloc = alloc,
            .path = try alloc.dupe(u8, palace_path),
        };
    }

    pub fn close(self: *Palace) void {
        self.drawers.close();
        self.kg.close();
        self.alloc.free(self.path);
    }
};
