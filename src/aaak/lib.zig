//! aaak/lib.zig — AAAK lossy abbreviation dialect
//! Deterministic, zero-alloc-on-hot-path compression for context loading.
//! Format: wing|room|date|source\n0:ENTITY+ENTITY|topic|"sentence"|emotion|FLAG

const std = @import("std");

pub const AaakError = error{ BufferTooSmall, OutOfMemory };

/// Decision-related keywords for scoring sentences and assigning flags.
const DECISION_KEYWORDS = [_][]const u8{ "decided", "chose", "selected", "switched", "migrated", "agreed", "approved", "rejected", "deprecated", "adopted" };
const EMOTION_KEYWORDS = [_]struct { kw: []const u8, code: []const u8 }{
    .{ .kw = "frustrated", .code = "*frust*" },
    .{ .kw = "excited", .code = "*excite*" },
    .{ .kw = "confused", .code = "*confuse*" },
    .{ .kw = "satisfied", .code = "*sat*" },
    .{ .kw = "concerned", .code = "*concern*" },
    .{ .kw = "worried", .code = "*worry*" },
    .{ .kw = "happy", .code = "*happy*" },
    .{ .kw = "annoyed", .code = "*annoy*" },
};
const FLAG_KEYWORDS = [_]struct { kw: []const u8, flag: []const u8 }{
    .{ .kw = "decided", .flag = "DECISION" },
    .{ .kw = "critical", .flag = "CORE" },
    .{ .kw = "never", .flag = "CORE" },
    .{ .kw = "always", .flag = "CORE" },
    .{ .kw = "bug", .flag = "BUG" },
    .{ .kw = "TODO", .flag = "TODO" },
    .{ .kw = "milestone", .flag = "MILESTONE" },
    .{ .kw = "shipped", .flag = "MILESTONE" },
};

pub const AaakEntry = struct {
    wing: []const u8,
    room: []const u8,
    date: []const u8, // YYYY-MM-DD
    source_stem: []const u8,
    entities: []const u8, // "ENT1+ENT2"
    topic: []const u8,
    key_sentence: []const u8, // truncated to 55 chars
    emotion: []const u8, // empty or "*code*"
    flag: []const u8, // empty or "DECISION" etc.

    /// Write AAAK line into buf. Returns bytes written.
    pub fn format(self: AaakEntry, buf: []u8) AaakError!usize {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        w.print("{s}|{s}|{s}|{s}\n0:{s}|{s}|\"{s}\"", .{
            self.wing,     self.room,  self.date,         self.source_stem,
            self.entities, self.topic, self.key_sentence,
        }) catch return AaakError.BufferTooSmall;
        if (self.emotion.len > 0) {
            w.print("|{s}", .{self.emotion}) catch return AaakError.BufferTooSmall;
        }
        if (self.flag.len > 0) {
            w.print("|{s}", .{self.flag}) catch return AaakError.BufferTooSmall;
        }
        w.writeByte('\n') catch return AaakError.BufferTooSmall;
        return fbs.pos;
    }
};

/// Compress a drawer's content into an AAAK entry. All output slices point
/// into caller-managed memory (alloc). Caller frees via AaakEntry fields.
pub fn compress(
    alloc: std.mem.Allocator,
    content: []const u8,
    wing: []const u8,
    room: []const u8,
    date: []const u8,
    source_stem: []const u8,
    known_entities: std.StringHashMap([]const u8), // name → 3-char code
) !AaakEntry {
    // 1. Entity detection
    var detected = std.ArrayList(u8).init(alloc);
    defer detected.deinit();
    var entity_count: u32 = 0;

    var words = std.mem.tokenizeAny(u8, content, " \t\n\r.,;:!?");
    while (words.next()) |word| {
        if (word.len < 2) continue;
        if (std.ascii.isUpper(word[0])) {
            if (known_entities.get(word)) |code| {
                if (entity_count > 0) try detected.appendSlice("+");
                try detected.appendSlice(code);
                entity_count += 1;
                if (entity_count >= 4) break;
            } else {
                // Auto-code: first 3 chars uppercase
                if (entity_count > 0) try detected.appendSlice("+");
                const end = @min(word.len, 3);
                for (word[0..end]) |ch| try detected.append(std.ascii.toUpper(ch));
                entity_count += 1;
                if (entity_count >= 4) break;
            }
        }
    }
    if (entity_count == 0) try detected.appendSlice("UNK");
    const entities = try detected.toOwnedSlice();

    // 2. Topic extraction: top-3 content words by frequency
    var freq = std.StringHashMap(u32).init(alloc);
    defer freq.deinit();
    var word_iter = std.mem.tokenizeAny(u8, content, " \t\n\r.,;:!?\"'()[]{}");
    while (word_iter.next()) |word| {
        if (word.len < 4) continue; // skip short words
        if (isStopWord(word)) continue;
        const entry = try freq.getOrPutValue(word, 0);
        entry.value_ptr.* += 1;
    }

    var best: [3]struct { word: []const u8, count: u32 } = .{
        .{ .word = "", .count = 0 },
        .{ .word = "", .count = 0 },
        .{ .word = "", .count = 0 },
    };
    var freq_iter = freq.iterator();
    while (freq_iter.next()) |kv| {
        if (kv.value_ptr.* > best[2].count) {
            best[2] = .{ .word = kv.key_ptr.*, .count = kv.value_ptr.* };
            // Bubble up
            if (best[2].count > best[1].count) std.mem.swap(@TypeOf(best[1]), &best[1], &best[2]);
            if (best[1].count > best[0].count) std.mem.swap(@TypeOf(best[0]), &best[0], &best[1]);
        }
    }
    var topic_buf = std.ArrayList(u8).init(alloc);
    defer topic_buf.deinit();
    for (best) |b| {
        if (b.word.len == 0) continue;
        if (topic_buf.items.len > 0) try topic_buf.appendSlice(".");
        try topic_buf.appendSlice(b.word);
    }
    if (topic_buf.items.len == 0) try topic_buf.appendSlice("general");
    const topic = try topic_buf.toOwnedSlice();

    // 3. Key sentence selection: highest decision-keyword score, truncated at 55
    var best_sentence: []const u8 = "";
    var best_score: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len < 10) continue;
        var score: u32 = 0;
        for (DECISION_KEYWORDS) |kw| {
            if (std.mem.indexOf(u8, trimmed, kw) != null) score += 2;
        }
        if (trimmed.len > 200) score += 2;
        if (score > best_score) {
            best_score = score;
            best_sentence = trimmed;
        }
    }
    // Fallback: first non-empty line
    if (best_sentence.len == 0) {
        var lb = std.mem.splitScalar(u8, content, '\n');
        while (lb.next()) |l| {
            const t = std.mem.trim(u8, l, " \t\r");
            if (t.len >= 10) {
                best_sentence = t;
                break;
            }
        }
    }
    const trunc_end = @min(best_sentence.len, 55);
    const key_sentence = try alloc.dupe(u8, best_sentence[0..trunc_end]);

    // 4. Emotion detection
    var emotion: []const u8 = "";
    for (EMOTION_KEYWORDS) |ek| {
        if (std.mem.indexOf(u8, content, ek.kw) != null) {
            emotion = ek.code;
            break;
        }
    }
    emotion = try alloc.dupe(u8, emotion);

    // 5. Flag detection
    var flag: []const u8 = "";
    for (FLAG_KEYWORDS) |fk| {
        if (std.mem.indexOf(u8, content, fk.kw) != null) {
            flag = fk.flag;
            break;
        }
    }
    flag = try alloc.dupe(u8, flag);

    return AaakEntry{
        .wing = try alloc.dupe(u8, wing),
        .room = try alloc.dupe(u8, room),
        .date = try alloc.dupe(u8, date),
        .source_stem = try alloc.dupe(u8, source_stem),
        .entities = entities,
        .topic = topic,
        .key_sentence = key_sentence,
        .emotion = emotion,
        .flag = flag,
    };
}

fn isStopWord(word: []const u8) bool {
    const stops = [_][]const u8{ "that", "this", "with", "from", "have", "been", "they", "will", "would", "could", "should", "about", "there", "their", "were", "when", "what", "then", "than", "into", "your", "more" };
    const lower_buf = blk: {
        var buf: [64]u8 = undefined;
        if (word.len > buf.len) break :blk word;
        break :blk std.ascii.lowerString(&buf, word);
    };
    for (stops) |s| {
        if (std.mem.eql(u8, lower_buf, s)) return true;
    }
    return false;
}

/// Parse an AAAK line back into components (lossy — no original reconstruction).
pub const ParsedAaak = struct {
    wing: []const u8,
    room: []const u8,
    date: []const u8,
    source_stem: []const u8,
    entities: []const u8,
    topic: []const u8,
    key_sentence: []const u8,
    emotion: []const u8,
    flag: []const u8,
};

pub fn parse(line: []const u8) ?ParsedAaak {
    // header: wing|room|date|source
    var parts = std.mem.splitScalar(u8, line, '\n');
    const header = parts.next() orelse return null;
    const body = parts.next() orelse return null;

    var hf = std.mem.splitScalar(u8, header, '|');
    const wing = hf.next() orelse return null;
    const room = hf.next() orelse return null;
    const date = hf.next() orelse return null;
    const source = hf.next() orelse return null;

    // body: 0:ENTITIES|topic|"sentence"|emotion|FLAG
    const body_trimmed = if (std.mem.startsWith(u8, body, "0:")) body[2..] else body;
    var bf = std.mem.splitScalar(u8, body_trimmed, '|');
    const entities = bf.next() orelse "";
    const topic = bf.next() orelse "";
    const raw_sent = bf.next() orelse "";
    const sentence = std.mem.trim(u8, raw_sent, "\"");
    const emotion = bf.next() orelse "";
    const flag = bf.next() orelse "";

    return ParsedAaak{
        .wing = wing,
        .room = room,
        .date = date,
        .source_stem = source,
        .entities = entities,
        .topic = topic,
        .key_sentence = sentence,
        .emotion = emotion,
        .flag = flag,
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "aaak compress round-trip smoke" {
    const alloc = std.testing.allocator;
    var entities = std.StringHashMap([]const u8).init(alloc);
    defer entities.deinit();
    try entities.put("Alice", "ALI");
    try entities.put("Bob", "BOB");

    const content = "Alice and Bob decided to migrate auth to Clerk because it was cheaper and easier.";
    const entry = try compress(alloc, content, "wing_project", "auth", "2026-04-01", "migration_notes", entities);

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

test "aaak format output" {
    const entry = AaakEntry{
        .wing = "wing_proj",
        .room = "auth",
        .date = "2026-01-15",
        .source_stem = "notes",
        .entities = "ALI+BOB",
        .topic = "auth.migrate.Clerk",
        .key_sentence = "decided to migrate auth to Clerk",
        .emotion = "",
        .flag = "DECISION",
    };
    var buf: [512]u8 = undefined;
    const n = try entry.format(&buf);
    try std.testing.expect(n > 0);
    const s = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, s, "DECISION") != null);
}
