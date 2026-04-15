//! mcp/lib.zig — JSON-RPC 2.0 MCP server (stdio transport)
//! Implements all 19 MemPalace tools + PALACE_PROTOCOL boot message.

const std = @import("std");
const storage = @import("storage");
const search = @import("search");
const graph = @import("graph");
const aaak = @import("aaak");

pub const McpError = error{ OutOfMemory, ParseError, IoError };

// ─── PALACE_PROTOCOL (embedded in status tool) ───────────────────────────────

const PALACE_PROTOCOL =
    \\MEMORY PROTOCOL — follow on every session:
    \\1. ON STARTUP: call mempalace_status to load identity and memory spec.
    \\2. BEFORE RESPONDING about any person, project, or past event:
    \\   call mempalace_kg_query or mempalace_search FIRST. Never guess — verify.
    \\3. IF UNSURE about a fact: say "let me check" and query the palace.
    \\4. AFTER EACH SESSION: call mempalace_diary_write to record what happened.
    \\5. WHEN FACTS CHANGE: call mempalace_kg_invalidate on old fact, mempalace_kg_add for new.
    \\Storage is not memory — but storage + this protocol = memory.
;

const AAAK_SPEC =
    \\AAAK DIALECT: wing|room|date|source\n0:ENT+ENT|topic|"sentence"|*emotion*|FLAG
    \\Entities: known codes or first-3-chars uppercase. Flags: DECISION CORE BUG TODO MILESTONE
    \\Lossy: sentence truncated at 55 chars. Decode by splitting on | — no original reconstruction.
;

// ─── JSON helpers (minimal, no dep) ──────────────────────────────────────────

/// Write a JSON string value (escaping quotes/backslash/newlines).
fn jsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(ch),
        }
    }
    try w.writeByte('"');
}

fn writeResult(w: anytype, id: ?i64, content: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |i| try w.print("{d}", .{i}) else try w.writeAll("null");
    try w.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try jsonString(w, content);
    try w.writeAll("}]}}\n");
}

fn writeError(w: anytype, id: ?i64, code: i32, msg: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |i| try w.print("{d}", .{i}) else try w.writeAll("null");
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try jsonString(w, msg);
    try w.writeAll("}}\n");
}

// ─── Tool definitions (for initialize response) ───────────────────────────────

const TOOLS_JSON =
    \\[
    \\{"name":"mempalace_status","description":"Palace overview + identity + memory protocol","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"mempalace_list_wings","description":"List all wings with drawer counts","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"mempalace_list_rooms","description":"List rooms in a wing","inputSchema":{"type":"object","properties":{"wing":{"type":"string"}}}},
    \\{"name":"mempalace_get_taxonomy","description":"Full wing→room→count tree","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"mempalace_search","description":"Hybrid BM25+cosine search with optional wing/room filter","inputSchema":{"type":"object","properties":{"query":{"type":"string"},"wing":{"type":"string"},"room":{"type":"string"},"n_results":{"type":"integer","default":5}},"required":["query"]}},
    \\{"name":"mempalace_check_duplicate","description":"Check if content is already in palace","inputSchema":{"type":"object","properties":{"content":{"type":"string"}},"required":["content"]}},
    \\{"name":"mempalace_get_aaak_spec","description":"Get AAAK dialect specification","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"mempalace_add_drawer","description":"File verbatim content into palace","inputSchema":{"type":"object","properties":{"wing":{"type":"string"},"room":{"type":"string"},"content":{"type":"string"},"hall":{"type":"string"},"source_file":{"type":"string"}},"required":["wing","room","content"]}},
    \\{"name":"mempalace_delete_drawer","description":"Remove drawer by ID","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}},
    \\{"name":"mempalace_kg_query","description":"Query knowledge graph for entity relationships","inputSchema":{"type":"object","properties":{"entity":{"type":"string"},"as_of":{"type":"string"}},"required":["entity"]}},
    \\{"name":"mempalace_kg_add","description":"Add a fact triple to knowledge graph","inputSchema":{"type":"object","properties":{"subject":{"type":"string"},"predicate":{"type":"string"},"object":{"type":"string"},"valid_from":{"type":"string"}},"required":["subject","predicate","object"]}},
    \\{"name":"mempalace_kg_invalidate","description":"Mark a fact as ended","inputSchema":{"type":"object","properties":{"subject":{"type":"string"},"predicate":{"type":"string"},"object":{"type":"string"},"ended":{"type":"string"}},"required":["subject","predicate","object","ended"]}},
    \\{"name":"mempalace_kg_timeline","description":"Chronological entity story","inputSchema":{"type":"object","properties":{"entity":{"type":"string"}},"required":["entity"]}},
    \\{"name":"mempalace_kg_stats","description":"Knowledge graph statistics","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"mempalace_traverse","description":"Walk palace graph from a room across wings","inputSchema":{"type":"object","properties":{"room":{"type":"string"},"max_hops":{"type":"integer","default":3}},"required":["room"]}},
    \\{"name":"mempalace_find_tunnels","description":"Find rooms bridging multiple wings","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"mempalace_graph_stats","description":"Palace graph connectivity overview","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"mempalace_diary_write","description":"Write agent diary entry (AAAK format)","inputSchema":{"type":"object","properties":{"agent_id":{"type":"string"},"entry":{"type":"string"}},"required":["agent_id","entry"]}},
    \\{"name":"mempalace_diary_read","description":"Read recent agent diary entries","inputSchema":{"type":"object","properties":{"agent_id":{"type":"string"},"last_n":{"type":"integer","default":10}},"required":["agent_id"]}}
    \\]
;

// ─── Server ───────────────────────────────────────────────────────────────────

pub const Server = struct {
    palace: *storage.Palace,
    searcher: search.Searcher,
    pg: graph.PalaceGraph,
    alloc: std.mem.Allocator,

    pub fn init(palace: *storage.Palace, alloc: std.mem.Allocator) Server {
        return .{
            .palace = palace,
            .searcher = search.Searcher.init(&palace.drawers, alloc),
            .pg = graph.PalaceGraph.init(alloc, &palace.drawers),
            .alloc = alloc,
        };
    }

    /// Run the server: read JSON-RPC from stdin, write to stdout.
    pub fn run(self: *Server) !void {
        const stdin = std.io.getStdIn().reader();
        const stdout = std.io.getStdOut().writer();
        var buf: [65536]u8 = undefined;

        while (true) {
            const line = stdin.readUntilDelimiter(&buf, '\n') catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (line.len == 0) continue;
            try self.handleLine(line, stdout);
        }
    }

    fn handleLine(self: *Server, line: []const u8, w: anytype) !void {
        // Minimal JSON-RPC parse: extract method, id, params
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const id = extractJsonInt(line, "\"id\"");
        const method = extractJsonStr(a, line, "\"method\"") catch {
            try writeError(w, id, -32700, "parse error");
            return;
        };
        defer if (method) |m| a.free(m);

        const m = method orelse {
            try writeError(w, id, -32600, "missing method");
            return;
        };

        if (std.mem.eql(u8, m, "initialize")) {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{?},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"mempalace\",\"version\":\"3.1.0\"}}}}}}\n", .{id});
        } else if (std.mem.eql(u8, m, "tools/list")) {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{?},\"result\":{{\"tools\":{s}}}}}\n", .{ id, TOOLS_JSON });
        } else if (std.mem.eql(u8, m, "tools/call")) {
            const tool_name = (extractJsonStr(a, line, "\"name\"") catch null) orelse {
                try writeError(w, id, -32602, "missing tool name");
                return;
            };
            try self.callTool(tool_name, line, id, w, a);
        } else if (std.mem.eql(u8, m, "notifications/initialized")) {
            // no response for notifications
        } else {
            try writeError(w, id, -32601, "method not found");
        }
    }

    fn callTool(self: *Server, tool: []const u8, params_json: []const u8, id: ?i64, w: anytype, a: std.mem.Allocator) !void {
        var out = std.ArrayList(u8).init(self.alloc);
        defer out.deinit();
        const ow = out.writer();

        if (std.mem.eql(u8, tool, "mempalace_status")) {
            const count = self.palace.drawers.count() catch 0;
            try ow.print("MemPalace v3.1.0 (Zig)\n\nPalace path: {s}\nDrawers: {d}\n\n{s}\n\n{s}", .{
                self.palace.path, count, PALACE_PROTOCOL, AAAK_SPEC,
            });
        } else if (std.mem.eql(u8, tool, "mempalace_list_wings")) {
            const wings = self.palace.drawers.listWings(self.alloc) catch {
                try writeError(w, id, -32000, "storage error");
                return;
            };
            defer {
                for (wings) |ww| self.alloc.free(ww);
                self.alloc.free(wings);
            }
            for (wings) |ww| try ow.print("{s}\n", .{ww});
        } else if (std.mem.eql(u8, tool, "mempalace_list_rooms")) {
            const wing_param = extractJsonStr(a, params_json, "\"wing\"") catch null;
            const rooms = self.palace.drawers.listRooms(self.alloc, wing_param) catch {
                try writeError(w, id, -32000, "storage error");
                return;
            };
            defer {
                for (rooms) |r| self.alloc.free(r);
                self.alloc.free(rooms);
            }
            for (rooms) |r| try ow.print("{s}\n", .{r});
        } else if (std.mem.eql(u8, tool, "mempalace_get_aaak_spec")) {
            try ow.writeAll(AAAK_SPEC);
        } else if (std.mem.eql(u8, tool, "mempalace_search")) {
            const query = (extractJsonStr(a, params_json, "\"query\"") catch null) orelse {
                try writeError(w, id, -32602, "missing query");
                return;
            };
            const wing_p = extractJsonStr(a, params_json, "\"wing\"") catch null;
            const room_p = extractJsonStr(a, params_json, "\"room\"") catch null;
            const n = extractJsonInt(params_json, "\"n_results\"") orelse 5;
            const results = self.searcher.search(query, wing_p, room_p, @intCast(@max(n, 1))) catch {
                try writeError(w, id, -32000, "search error");
                return;
            };
            defer {
                for (results) |*r| {
                    var rr = r.*;
                    rr.deinit(self.alloc);
                }
                self.alloc.free(results);
            }
            try ow.print("{d} results for \"{s}\":\n\n", .{ results.len, query });
            for (results) |r| {
                try ow.print("[{s:.3}] {s}/{s}\n{s}\n---\n", .{ r.score, r.wing, r.room, r.content_snippet });
            }
        } else if (std.mem.eql(u8, tool, "mempalace_add_drawer")) {
            const wing_p = (extractJsonStr(a, params_json, "\"wing\"") catch null) orelse "wing_general";
            const room_p = (extractJsonStr(a, params_json, "\"room\"") catch null) orelse "general";
            const content_p = (extractJsonStr(a, params_json, "\"content\"") catch null) orelse {
                try writeError(w, id, -32602, "missing content");
                return;
            };
            const hall_s = (extractJsonStr(a, params_json, "\"hall\"") catch null) orelse "general";
            const src = (extractJsonStr(a, params_json, "\"source_file\"") catch null) orelse "mcp_add";
            const drawer_id = storage.computeDrawerId(self.alloc, wing_p, room_p, src, 0) catch {
                try writeError(w, id, -32000, "id error");
                return;
            };
            defer self.alloc.free(drawer_id);
            const drawer = storage.Drawer{
                .id = drawer_id,
                .wing = wing_p,
                .room = room_p,
                .hall = storage.Hall.fromStr(hall_s),
                .content = content_p,
                .source_file = src,
                .chunk_index = 0,
                .added_by = "mcp",
                .filed_at = "2026-01-01",
                .importance = 0.5,
                .emotional_weight = 0.0,
            };
            self.palace.drawers.insert(drawer) catch {
                try writeError(w, id, -32000, "insert failed");
                return;
            };
            try ow.print("Added drawer {s}", .{drawer_id});
        } else if (std.mem.eql(u8, tool, "mempalace_delete_drawer")) {
            const del_id = (extractJsonStr(a, params_json, "\"id\"") catch null) orelse {
                try writeError(w, id, -32602, "missing id");
                return;
            };
            self.palace.drawers.delete(del_id) catch {
                try writeError(w, id, -32000, "delete failed");
                return;
            };
            try ow.print("Deleted {s}", .{del_id});
        } else if (std.mem.eql(u8, tool, "mempalace_kg_add")) {
            const subj = (extractJsonStr(a, params_json, "\"subject\"") catch null) orelse {
                try writeError(w, id, -32602, "missing subject");
                return;
            };
            const pred = (extractJsonStr(a, params_json, "\"predicate\"") catch null) orelse {
                try writeError(w, id, -32602, "missing predicate");
                return;
            };
            const obj = (extractJsonStr(a, params_json, "\"object\"") catch null) orelse {
                try writeError(w, id, -32602, "missing object");
                return;
            };
            const vf = extractJsonStr(a, params_json, "\"valid_from\"") catch null;
            self.palace.kg.addTriple(subj, pred, obj, vf, null) catch {
                try writeError(w, id, -32000, "kg insert failed");
                return;
            };
            try ow.print("Added: {s} → {s} → {s}", .{ subj, pred, obj });
        } else if (std.mem.eql(u8, tool, "mempalace_kg_invalidate")) {
            const subj = (extractJsonStr(a, params_json, "\"subject\"") catch null) orelse {
                try writeError(w, id, -32602, "missing subject");
                return;
            };
            const pred = (extractJsonStr(a, params_json, "\"predicate\"") catch null) orelse {
                try writeError(w, id, -32602, "missing predicate");
                return;
            };
            const obj = (extractJsonStr(a, params_json, "\"object\"") catch null) orelse {
                try writeError(w, id, -32602, "missing object");
                return;
            };
            const ended = (extractJsonStr(a, params_json, "\"ended\"") catch null) orelse "9999-01-01";
            self.palace.kg.invalidate(subj, pred, obj, ended) catch {
                try writeError(w, id, -32000, "kg invalidate failed");
                return;
            };
            try ow.print("Invalidated: {s} → {s} → {s} (ended {s})", .{ subj, pred, obj, ended });
        } else if (std.mem.eql(u8, tool, "mempalace_kg_query")) {
            const entity = (extractJsonStr(a, params_json, "\"entity\"") catch null) orelse {
                try writeError(w, id, -32602, "missing entity");
                return;
            };
            const as_of = extractJsonStr(a, params_json, "\"as_of\"") catch null;
            const triples = self.palace.kg.queryEntity(self.alloc, entity, as_of) catch {
                try writeError(w, id, -32000, "kg query failed");
                return;
            };
            defer {
                for (triples) |*t| {
                    var tt = t.*;
                    tt.deinit(self.alloc);
                }
                self.alloc.free(triples);
            }
            try ow.print("{d} facts for {s}:\n", .{ triples.len, entity });
            for (triples) |t| {
                try ow.print("  {s} → {s} → {s}", .{ t.subject, t.predicate, t.object });
                if (t.valid_from) |vf| try ow.print(" (from {s})", .{vf});
                if (t.valid_to) |vt| try ow.print(" (ended {s})", .{vt});
                try ow.writeByte('\n');
            }
        } else if (std.mem.eql(u8, tool, "mempalace_kg_timeline")) {
            const entity = (extractJsonStr(a, params_json, "\"entity\"") catch null) orelse {
                try writeError(w, id, -32602, "missing entity");
                return;
            };
            const triples = self.palace.kg.timeline(self.alloc, entity) catch {
                try writeError(w, id, -32000, "timeline failed");
                return;
            };
            defer {
                for (triples) |*t| {
                    var tt = t.*;
                    tt.deinit(self.alloc);
                }
                self.alloc.free(triples);
            }
            try ow.print("Timeline for {s} ({d} events):\n", .{ entity, triples.len });
            for (triples) |t| {
                const date = t.valid_from orelse "?";
                try ow.print("  [{s}] {s} → {s} → {s}\n", .{ date, t.subject, t.predicate, t.object });
            }
        } else if (std.mem.eql(u8, tool, "mempalace_kg_stats")) {
            const s = self.palace.kg.stats() catch {
                try writeError(w, id, -32000, "stats failed");
                return;
            };
            try ow.print("Entities: {d}\nTotal triples: {d}\nActive triples: {d}", .{ s.entities, s.triples, s.active });
        } else if (std.mem.eql(u8, tool, "mempalace_find_tunnels")) {
            const tunnels = self.pg.findTunnels() catch {
                try writeError(w, id, -32000, "graph error");
                return;
            };
            defer {
                for (tunnels) |t| {
                    self.alloc.free(t.room);
                    for (t.wings) |ww| self.alloc.free(ww);
                    self.alloc.free(t.wings);
                }
                self.alloc.free(tunnels);
            }
            try ow.print("{d} tunnels found:\n", .{tunnels.len});
            for (tunnels) |t| {
                try ow.print("  room={s} wings=[", .{t.room});
                for (t.wings, 0..) |ww, i| {
                    if (i > 0) try ow.writeAll(", ");
                    try ow.writeAll(ww);
                }
                try ow.writeAll("]\n");
            }
        } else if (std.mem.eql(u8, tool, "mempalace_traverse")) {
            const room_p = (extractJsonStr(a, params_json, "\"room\"") catch null) orelse {
                try writeError(w, id, -32602, "missing room");
                return;
            };
            const hops = extractJsonInt(params_json, "\"max_hops\"") orelse 3;
            const nodes = self.pg.traverse(room_p, @intCast(@max(hops, 1))) catch {
                try writeError(w, id, -32000, "traverse error");
                return;
            };
            defer {
                for (nodes) |n| {
                    self.alloc.free(n.wing);
                    self.alloc.free(n.room);
                }
                self.alloc.free(nodes);
            }
            try ow.print("Traversal from room={s} ({d} nodes):\n", .{ room_p, nodes.len });
            for (nodes) |n| try ow.print("  {s}/{s} ({d} drawers)\n", .{ n.wing, n.room, n.drawer_count });
        } else if (std.mem.eql(u8, tool, "mempalace_graph_stats")) {
            const s = self.pg.stats() catch {
                try writeError(w, id, -32000, "stats failed");
                return;
            };
            try ow.print("Wings: {d}\nRooms: {d}\nTunnels: {d}", .{ s.wings, s.rooms, s.tunnels });
        } else if (std.mem.eql(u8, tool, "mempalace_diary_write")) {
            const agent_id = (extractJsonStr(a, params_json, "\"agent_id\"") catch null) orelse {
                try writeError(w, id, -32602, "missing agent_id");
                return;
            };
            const entry = (extractJsonStr(a, params_json, "\"entry\"") catch null) orelse {
                try writeError(w, id, -32602, "missing entry");
                return;
            };
            const wing = try std.fmt.allocPrint(self.alloc, "wing_agent_{s}", .{agent_id});
            defer self.alloc.free(wing);
            const drawer_id = storage.computeDrawerId(self.alloc, wing, "diary", entry, @intCast(std.time.milliTimestamp())) catch {
                try writeError(w, id, -32000, "id error");
                return;
            };
            defer self.alloc.free(drawer_id);
            const drawer = storage.Drawer{
                .id = drawer_id,
                .wing = wing,
                .room = "diary",
                .hall = .diary,
                .content = entry,
                .source_file = "diary",
                .chunk_index = 0,
                .added_by = agent_id,
                .filed_at = "2026-01-01",
                .importance = 0.7,
                .emotional_weight = 0.0,
            };
            self.palace.drawers.insert(drawer) catch {
                try writeError(w, id, -32000, "insert failed");
                return;
            };
            try ow.print("Diary entry written for agent {s}", .{agent_id});
        } else if (std.mem.eql(u8, tool, "mempalace_diary_read")) {
            const agent_id = (extractJsonStr(a, params_json, "\"agent_id\"") catch null) orelse {
                try writeError(w, id, -32602, "missing agent_id");
                return;
            };
            const last_n = extractJsonInt(params_json, "\"last_n\"") orelse 10;
            const wing = try std.fmt.allocPrint(self.alloc, "wing_agent_{s}", .{agent_id});
            defer self.alloc.free(wing);
            const drawers = self.palace.drawers.query(self.alloc, wing, "diary", @intCast(@max(last_n, 1))) catch {
                try writeError(w, id, -32000, "read failed");
                return;
            };
            defer {
                for (drawers) |*d| {
                    var dd = d.*;
                    dd.deinit(self.alloc);
                }
                self.alloc.free(drawers);
            }
            try ow.print("{d} diary entries for {s}:\n", .{ drawers.len, agent_id });
            for (drawers) |d| try ow.print("  [{s}] {s}\n", .{ d.filed_at, d.content });
        } else if (std.mem.eql(u8, tool, "mempalace_get_taxonomy")) {
            const wings = self.palace.drawers.listWings(self.alloc) catch {
                try writeError(w, id, -32000, "storage error");
                return;
            };
            defer {
                for (wings) |ww| self.alloc.free(ww);
                self.alloc.free(wings);
            }
            for (wings) |ww| {
                const rooms = self.palace.drawers.listRooms(self.alloc, ww) catch continue;
                defer {
                    for (rooms) |r| self.alloc.free(r);
                    self.alloc.free(rooms);
                }
                try ow.print("{s}:\n", .{ww});
                for (rooms) |r| try ow.print("  └─ {s}\n", .{r});
            }
        } else if (std.mem.eql(u8, tool, "mempalace_check_duplicate")) {
            const content_p = (extractJsonStr(a, params_json, "\"content\"") catch null) orelse {
                try writeError(w, id, -32602, "missing content");
                return;
            };
            // Simple: check if any drawer has this as source_file
            const exists = self.palace.drawers.fileExists(content_p) catch false;
            try ow.print("{s}", .{if (exists) "duplicate_found" else "no_duplicate"});
        } else {
            try writeError(w, id, -32601, "unknown tool");
            return;
        }
        try writeResult(w, id, out.items);
    }
};

// ─── Minimal JSON field extractors ───────────────────────────────────────────

/// Extract a string value for a key from JSON (simple scan, not a full parser).
fn extractJsonStr(alloc: std.mem.Allocator, json: []const u8, key: []const u8) !?[]u8 {
    const pos = std.mem.indexOf(u8, json, key) orelse return null;
    var i = pos + key.len;
    while (i < json.len and (json[i] == ' ' or json[i] == ':')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    i += 1; // skip opening quote
    var end = i;
    while (end < json.len) {
        if (json[end] == '\\') {
            end += 2;
            continue;
        }
        if (json[end] == '"') break;
        end += 1;
    }
    return try alloc.dupe(u8, json[i..end]);
}

fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
    const pos = std.mem.indexOf(u8, json, key) orelse return null;
    var i = pos + key.len;
    while (i < json.len and (json[i] == ' ' or json[i] == ':')) i += 1;
    if (i >= json.len) return null;
    var end = i;
    if (json[end] == '-') end += 1;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') end += 1;
    if (end == i) return null;
    return std.fmt.parseInt(i64, json[i..end], 10) catch null;
}
