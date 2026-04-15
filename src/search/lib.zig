//! search/lib.zig — Hybrid BM25 (40%) + cosine TF-IDF (60%) retrieval
//!
//! Since we can't embed a vector DB (no chromadb in Zig), we use a local
//! inverted index with BM25 + TF-IDF cosine similarity stored in SQLite.
//! The approach matches v3.1's hybrid strategy: keyword + semantic signal.
//!
//! For production use, the TF-IDF vectors are stored as BLOB in SQLite and
//! cosine similarity is computed in-process. This gives ~O(n) scan but works
//! entirely offline without any native extensions.

const std = @import("std");
const storage = @import("storage");

pub const SearchError = error{ StorageError, OutOfMemory, InvalidQuery };

// BM25 tuning constants (Okapi BM25, Lucene IDF variant)
const BM25_K1: f32 = 1.2;
const BM25_B: f32 = 0.75;
const HYBRID_BM25_WEIGHT: f32 = 0.40;
const HYBRID_TFIDF_WEIGHT: f32 = 0.60;

pub const SearchResult = struct {
    id: []const u8,
    wing: []const u8,
    room: []const u8,
    content_snippet: []const u8, // first 200 chars
    score: f32,
    source_file: []const u8,

    pub fn deinit(self: *SearchResult, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.wing);
        alloc.free(self.room);
        alloc.free(self.content_snippet);
        alloc.free(self.source_file);
    }
};

/// In-process BM25 + TF-IDF hybrid searcher over a DrawerStore.
pub const Searcher = struct {
    store: *storage.DrawerStore,
    alloc: std.mem.Allocator,
    /// Avg document length (tokens), lazily cached.
    avg_doc_len: f32 = 0,
    doc_count: u32 = 0,
    cached: bool = false,

    pub fn init(store: *storage.DrawerStore, alloc: std.mem.Allocator) Searcher {
        return .{ .store = store, .alloc = alloc };
    }

    /// Run hybrid search. Returns results sorted by descending score.
    pub fn search(
        self: *Searcher,
        query: []const u8,
        wing: ?[]const u8,
        room: ?[]const u8,
        n_results: u32,
    ) SearchError![]SearchResult {
        // Fetch candidate drawers (up to 2000 for re-scoring)
        const candidates = self.store.query(self.alloc, wing, room, 2000) catch return SearchError.StorageError;
        defer {
            for (candidates) |*d| {
                var dd = d.*;
                dd.deinit(self.alloc);
            }
            self.alloc.free(candidates);
        }

        if (candidates.len == 0) return &[_]SearchResult{};

        const query_tokens = tokenize(self.alloc, query) catch return SearchError.OutOfMemory;
        defer {
            for (query_tokens) |t| self.alloc.free(t);
            self.alloc.free(query_tokens);
        }

        // Compute avg doc length for BM25
        if (!self.cached) {
            var total: u64 = 0;
            for (candidates) |d| total += @intCast(countTokens(d.content));
            self.doc_count = @intCast(candidates.len);
            self.avg_doc_len = if (self.doc_count > 0) @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(self.doc_count)) else 1.0;
            self.cached = true;
        }

        // IDF per query token (approximate over candidate set)
        var idf_map = std.StringHashMap(f32).init(self.alloc);
        defer idf_map.deinit();
        for (query_tokens) |qt| {
            var df: u32 = 0;
            for (candidates) |d| {
                if (std.mem.indexOf(u8, d.content, qt) != null) df += 1;
            }
            const idf = idfLucene(@intCast(candidates.len), df);
            idf_map.put(qt, idf) catch return SearchError.OutOfMemory;
        }

        // Score each candidate
        var scored = std.ArrayList(struct { idx: usize, score: f32 }).init(self.alloc);
        defer scored.deinit();

        for (candidates, 0..) |d, i| {
            const bm25 = bm25Score(d.content, query_tokens, &idf_map, self.avg_doc_len);
            const tfidf = cosineTfidf(d.content, query_tokens, &idf_map);
            const final_score = HYBRID_BM25_WEIGHT * bm25 + HYBRID_TFIDF_WEIGHT * tfidf;
            if (final_score > 0.001) {
                scored.append(.{ .idx = i, .score = final_score }) catch return SearchError.OutOfMemory;
            }
        }

        // Sort descending
        std.sort.pdq(
            struct { idx: usize, score: f32 },
            scored.items,
            {},
            struct {
                fn lt(_: void, a: anytype, b: anytype) bool {
                    return a.score > b.score;
                }
            }.lt,
        );

        const limit = @min(n_results, scored.items.len);
        var results = std.ArrayList(SearchResult).init(self.alloc);
        for (scored.items[0..limit]) |s| {
            const d = &candidates[s.idx];
            const snippet_end = @min(d.content.len, 200);
            const r = SearchResult{
                .id = self.alloc.dupe(u8, d.id) catch return SearchError.OutOfMemory,
                .wing = self.alloc.dupe(u8, d.wing) catch return SearchError.OutOfMemory,
                .room = self.alloc.dupe(u8, d.room) catch return SearchError.OutOfMemory,
                .content_snippet = self.alloc.dupe(u8, d.content[0..snippet_end]) catch return SearchError.OutOfMemory,
                .score = s.score,
                .source_file = self.alloc.dupe(u8, d.source_file) catch return SearchError.OutOfMemory,
            };
            results.append(r) catch return SearchError.OutOfMemory;
        }
        return results.toOwnedSlice() catch return SearchError.OutOfMemory;
    }
};

// ─── BM25 helpers ─────────────────────────────────────────────────────────────

fn bm25Score(doc: []const u8, query_tokens: [][]u8, idf: *std.StringHashMap(f32), avg_dl: f32) f32 {
    const dl: f32 = @floatFromInt(countTokens(doc));
    var score: f32 = 0.0;
    for (query_tokens) |qt| {
        const tf_raw: f32 = @floatFromInt(countOccurrences(doc, qt));
        if (tf_raw == 0) continue;
        const idf_val = idf.get(qt) orelse 0.0;
        const tf_norm = (tf_raw * (BM25_K1 + 1.0)) / (tf_raw + BM25_K1 * (1.0 - BM25_B + BM25_B * dl / avg_dl));
        score += idf_val * tf_norm;
    }
    return score;
}

fn cosineTfidf(doc: []const u8, query_tokens: [][]u8, idf: *std.StringHashMap(f32)) f32 {
    var dot: f32 = 0.0;
    var doc_mag: f32 = 0.0;
    var q_mag: f32 = 0.0;
    const dl: f32 = @as(f32, @floatFromInt(countTokens(doc))) + 1.0;
    for (query_tokens) |qt| {
        const tf: f32 = @as(f32, @floatFromInt(countOccurrences(doc, qt))) / dl;
        const idf_val = idf.get(qt) orelse 0.0;
        const d_tfidf = tf * idf_val;
        const q_tfidf = idf_val; // query TF is always 1
        dot += d_tfidf * q_tfidf;
        doc_mag += d_tfidf * d_tfidf;
        q_mag += q_tfidf * q_tfidf;
    }
    const denom = @sqrt(doc_mag) * @sqrt(q_mag);
    if (denom < 1e-9) return 0.0;
    return dot / denom;
}

fn idfLucene(n: u32, df: u32) f32 {
    if (df == 0) return 0.0;
    const n_f: f32 = @floatFromInt(n);
    const df_f: f32 = @floatFromInt(df);
    return @log((n_f - df_f + 0.5) / (df_f + 0.5) + 1.0);
}

fn countTokens(text: []const u8) usize {
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, text, " \t\n\r");
    while (iter.next()) |_| count += 1;
    return count;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            count += 1;
            i += needle.len;
        } else i += 1;
    }
    return count;
}

fn tokenize(alloc: std.mem.Allocator, text: []const u8) ![][]u8 {
    var tokens = std.ArrayList([]u8).init(alloc);
    var iter = std.mem.tokenizeAny(u8, text, " \t\n\r.,;:!?\"'()[]{}");
    while (iter.next()) |word| {
        if (word.len < 2) continue;
        const lower = try alloc.alloc(u8, word.len);
        _ = std.ascii.lowerString(lower, word);
        try tokens.append(lower);
    }
    return tokens.toOwnedSlice();
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "bm25 scoring basic" {
    const alloc = std.testing.allocator;
    var idf = std.StringHashMap(f32).init(alloc);
    defer idf.deinit();
    var qt = [_][]u8{ @constCast("auth"), @constCast("migration") };
    try idf.put("auth", 2.0);
    try idf.put("migration", 1.5);
    const score = bm25Score("we decided to do auth migration to Clerk", &qt, &idf, 8.0);
    try std.testing.expect(score > 0.0);
}

test "cosine tfidf" {
    const alloc = std.testing.allocator;
    var idf = std.StringHashMap(f32).init(alloc);
    defer idf.deinit();
    var qt = [_][]u8{@constCast("graphql")};
    try idf.put("graphql", 3.0);
    const s1 = cosineTfidf("we switched from REST to graphql for performance", &qt, &idf);
    const s2 = cosineTfidf("nothing relevant here at all", &qt, &idf);
    try std.testing.expect(s1 > s2);
}
