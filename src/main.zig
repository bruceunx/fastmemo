//! main.zig — MemPalace CLI
//! Commands: init, mine, search, status, kg, wake-up, mcp

const std = @import("std");
const storage = @import("storage");
const search = @import("search");
const graph = @import("graph");
const aaak = @import("aaak");
const mining = @import("mining");

const VERSION = "3.1.0";
const USAGE =
    \\fastmemo v{s} — local AI memory system (Zig port)
    \\
    \\Usage: fastmemo <command> [options]
    \\
    \\Commands:
    \\  init   <dir>                  Initialize palace in directory
    \\  mine   <dir> [--mode MODE] [--wing NAME]
    \\                                Mine files into palace
    \\                                MODE: projects (default), convos, general
    \\  search <query> [--wing W] [--room R] [--n N]
    \\                                Semantic search
    \\  status                        Palace overview
    \\  wake-up [--wing W]            Print L0+L1 context
    \\  kg     <subcommand>           Knowledge graph operations
    \\           add <subj> <pred> <obj> [--from DATE]
    \\           query <entity> [--as-of DATE]
    \\           timeline <entity>
    \\           invalidate <subj> <pred> <obj> --ended DATE
    \\           stats
    \\  mcp                           Print MCP server setup command
    \\  version                       Print version
    \\
    \\Options:
    \\  --palace PATH     Override palace path (default: ~/.fastmemo/palace)
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (args.len < 2) {
        try stdout.print(USAGE, .{VERSION});
        return;
    }

    // Parse --palace global option
    var palace_path_buf: [1024]u8 = undefined;
    var palace_path: []const u8 = blk: {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        break :blk try std.fmt.bufPrint(&palace_path_buf, "{s}/.fastmemo/palace", .{home});
    };
    var remaining = std.array_list.Managed([]const u8).init(alloc);
    defer remaining.deinit();
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--palace") and i + 1 < args.len) {
            palace_path = args[i + 1];
            i += 1;
        } else {
            try remaining.append(args[i]);
        }
    }

    const cmd = remaining.items[0];

    if (std.mem.eql(u8, cmd, "version")) {
        try stdout.print("fastmemo {s}\n", .{VERSION});
        return;
    }

    if (std.mem.eql(u8, cmd, "mcp")) {
        try stdout.print("fastmemo-mcp --palace {s}\n", .{palace_path});
        try stdout.writeAll("Add to your MCP config:\n");
        try stdout.print("  command: fastmemo-mcp\n  args: [\"--palace\", \"{s}\"]\n", .{palace_path});
        return;
    }

    if (std.mem.eql(u8, cmd, "init")) {
        const dir = if (remaining.items.len > 1) remaining.items[1] else ".";
        var palace = storage.Palace.open(alloc, palace_path) catch |err| {
            try stderr.print("Failed to open palace: {}\n", .{err});
            return;
        };
        defer palace.close();
        try stdout.print("Palace initialized at {s}\n", .{palace_path});
        try stdout.print("Mining {s}...\n", .{dir});
        var miner = mining.Miner.init(&palace.drawers, alloc);
        miner.mineDir(dir, .{ .mode = .projects }) catch |err| {
            try stderr.print("Mine error: {}\n", .{err});
        };
        try stdout.print("Done. {d} files, {d} chunks indexed.\n", .{
            miner.stats.files_seen, miner.stats.chunks_inserted,
        });
        return;
    }

    var palace = storage.Palace.open(alloc, palace_path) catch |err| {
        try stderr.print("Failed to open palace at {s}: {}\nRun: fastmemo init\n", .{ palace_path, err });
        return;
    };
    defer palace.close();

    if (std.mem.eql(u8, cmd, "mine")) {
        const dir = if (remaining.items.len > 1) remaining.items[1] else ".";
        var opts = mining.MineOptions{};
        var j: usize = 2;
        while (j < remaining.items.len) : (j += 1) {
            if (std.mem.eql(u8, remaining.items[j], "--mode") and j + 1 < remaining.items.len) {
                j += 1;
                opts.mode = if (std.mem.eql(u8, remaining.items[j], "convos")) .convos else if (std.mem.eql(u8, remaining.items[j], "general")) .general else .projects;
            } else if (std.mem.eql(u8, remaining.items[j], "--wing") and j + 1 < remaining.items.len) {
                j += 1;
                opts.wing = remaining.items[j];
            }
        }
        var miner = mining.Miner.init(&palace.drawers, alloc);
        try miner.mineDir(dir, opts);
        try stdout.print("Mined {d} files ({d} skipped), {d} chunks inserted.\n", .{
            miner.stats.files_seen,
            miner.stats.files_skipped,
            miner.stats.chunks_inserted,
        });
    } else if (std.mem.eql(u8, cmd, "search")) {
        if (remaining.items.len < 2) {
            try stderr.writeAll("Usage: fastmemo search <query>\n");
            return;
        }
        const query = remaining.items[1];
        var wing_filter: ?[]const u8 = null;
        var room_filter: ?[]const u8 = null;
        var n: u32 = 5;
        var j: usize = 2;
        while (j < remaining.items.len) : (j += 1) {
            if (std.mem.eql(u8, remaining.items[j], "--wing") and j + 1 < remaining.items.len) {
                j += 1;
                wing_filter = remaining.items[j];
            } else if (std.mem.eql(u8, remaining.items[j], "--room") and j + 1 < remaining.items.len) {
                j += 1;
                room_filter = remaining.items[j];
            } else if (std.mem.eql(u8, remaining.items[j], "--n") and j + 1 < remaining.items.len) {
                j += 1;
                n = std.fmt.parseInt(u32, remaining.items[j], 10) catch 5;
            }
        }
        var searcher = search.Searcher.init(&palace.drawers, alloc);
        const results = searcher.search(query, wing_filter, room_filter, n) catch |err| {
            try stderr.print("Search error: {}\n", .{err});
            return;
        };
        defer {
            for (results) |*r| {
                var rr = r.*;
                rr.deinit(alloc);
            }
            alloc.free(results);
        }
        try stdout.print("{d} results for \"{s}\":\n\n", .{ results.len, query });
        for (results, 1..) |r, idx| {
            try stdout.print("[{d}] score={d:.3} | {s}/{s}\n    {s}\n    file: {s}\n\n", .{
                idx, r.score, r.wing, r.room, r.content_snippet, r.source_file,
            });
        }
    } else if (std.mem.eql(u8, cmd, "status")) {
        const count = palace.drawers.count() catch 0;
        const wings = palace.drawers.listWings(alloc) catch &[_][]u8{};
        defer {
            for (wings) |w| alloc.free(w);
            alloc.free(wings);
        }
        const kg_stats = palace.kg.stats() catch blk: {
            break :blk @TypeOf(palace.kg.stats() catch unreachable){ .entities = 0, .triples = 0, .active = 0 };
        };
        try stdout.print(
            \\FastMemo {s}
            \\Palace: {s}
            \\Drawers: {d}
            \\Wings:   {d}
            \\KG entities: {d} | triples: {d} (active: {d})
            \\
        , .{ VERSION, palace_path, count, wings.len, kg_stats.entities, kg_stats.triples, kg_stats.active });
    } else if (std.mem.eql(u8, cmd, "wake-up")) {
        // L0: identity
        var identity_path_buf: [1024]u8 = undefined;
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const id_path = try std.fmt.bufPrint(&identity_path_buf, "{s}/.fastmemo/identity.txt", .{home});
        if (std.fs.cwd().readFileAlloc(alloc, id_path, 4096)) |identity| {
            defer alloc.free(identity);
            try stdout.print("=== L0: Identity ===\n{s}\n\n", .{identity});
        } else |_| {
            try stdout.writeAll("=== L0: Identity ===\n(no identity.txt found — create ~/.fastmemo/identity.txt)\n\n");
        }
        // L1: top-15 by importance
        var wing_filter: ?[]const u8 = null;
        if (remaining.items.len > 1 and std.mem.eql(u8, remaining.items[1], "--wing") and remaining.items.len > 2)
            wing_filter = remaining.items[2];
        const drawers = palace.drawers.query(alloc, wing_filter, null, 15) catch &[_]storage.Drawer{};
        defer {
            for (drawers) |*d| {
                var dd = d.*;
                dd.deinit(alloc);
            }
            alloc.free(drawers);
        }
        try stdout.print("=== L1: Critical Facts ({d} drawers) ===\n", .{drawers.len});
        for (drawers) |d| {
            const snip = d.content[0..@min(d.content.len, 150)];
            try stdout.print("[{s}/{s}] {s}\n", .{ d.wing, d.room, snip });
        }
    } else if (std.mem.eql(u8, cmd, "kg")) {
        if (remaining.items.len < 2) {
            try stderr.writeAll("Usage: fastmemo kg <add|query|timeline|invalidate|stats>\n");
            return;
        }
        const sub = remaining.items[1];
        if (std.mem.eql(u8, sub, "add")) {
            if (remaining.items.len < 5) {
                try stderr.writeAll("Usage: fastmemo kg add <subject> <predicate> <object> [--from DATE]\n");
                return;
            }
            const subj = remaining.items[2];
            const pred = remaining.items[3];
            const obj = remaining.items[4];
            var vf: ?[]const u8 = null;
            var j: usize = 5;
            while (j < remaining.items.len) : (j += 1) {
                if (std.mem.eql(u8, remaining.items[j], "--from") and j + 1 < remaining.items.len) {
                    j += 1;
                    vf = remaining.items[j];
                }
            }
            palace.kg.addTriple(subj, pred, obj, vf, null) catch |err| {
                try stderr.print("KG add error: {}\n", .{err});
                return;
            };
            try stdout.print("Added: {s} → {s} → {s}\n", .{ subj, pred, obj });
        } else if (std.mem.eql(u8, sub, "query")) {
            if (remaining.items.len < 3) {
                try stderr.writeAll("Usage: fastmemo kg query <entity> [--as-of DATE]\n");
                return;
            }
            const entity = remaining.items[2];
            var as_of: ?[]const u8 = null;
            var j: usize = 3;
            while (j < remaining.items.len) : (j += 1) {
                if (std.mem.eql(u8, remaining.items[j], "--as-of") and j + 1 < remaining.items.len) {
                    j += 1;
                    as_of = remaining.items[j];
                }
            }
            const triples = palace.kg.queryEntity(alloc, entity, as_of) catch |err| {
                try stderr.print("KG query error: {}\n", .{err});
                return;
            };
            defer {
                for (triples) |*t| {
                    var tt = t.*;
                    tt.deinit(alloc);
                }
                alloc.free(triples);
            }
            try stdout.print("{d} facts for {s}:\n", .{ triples.len, entity });
            for (triples) |t| {
                try stdout.print("  {s} → {s} → {s}", .{ t.subject, t.predicate, t.object });
                if (t.valid_from) |vf| try stdout.print(" (from {s})", .{vf});
                if (t.valid_to) |vt| try stdout.print(" (ended {s})", .{vt});
                try stdout.writeByte('\n');
            }
        } else if (std.mem.eql(u8, sub, "timeline")) {
            if (remaining.items.len < 3) {
                try stderr.writeAll("Usage: fastmemo kg timeline <entity>\n");
                return;
            }
            const entity = remaining.items[2];
            const triples = palace.kg.timeline(alloc, entity) catch |err| {
                try stderr.print("Timeline error: {}\n", .{err});
                return;
            };
            defer {
                for (triples) |*t| {
                    var tt = t.*;
                    tt.deinit(alloc);
                }
                alloc.free(triples);
            }
            try stdout.print("Timeline for {s}:\n", .{entity});
            for (triples) |t| {
                const date = t.valid_from orelse "?";
                try stdout.print("  [{s}] {s} → {s} → {s}\n", .{ date, t.subject, t.predicate, t.object });
            }
        } else if (std.mem.eql(u8, sub, "invalidate")) {
            if (remaining.items.len < 5) {
                try stderr.writeAll("Usage: fastmemo kg invalidate <subj> <pred> <obj> --ended DATE\n");
                return;
            }
            const subj = remaining.items[2];
            const pred = remaining.items[3];
            const obj = remaining.items[4];
            var ended: []const u8 = "9999-01-01";
            var j: usize = 5;
            while (j < remaining.items.len) : (j += 1) {
                if (std.mem.eql(u8, remaining.items[j], "--ended") and j + 1 < remaining.items.len) {
                    j += 1;
                    ended = remaining.items[j];
                }
            }
            palace.kg.invalidate(subj, pred, obj, ended) catch |err| {
                try stderr.print("Invalidate error: {}\n", .{err});
                return;
            };
            try stdout.print("Invalidated: {s} → {s} → {s}\n", .{ subj, pred, obj });
        } else if (std.mem.eql(u8, sub, "stats")) {
            const s = palace.kg.stats() catch blk: {
                break :blk @TypeOf(palace.kg.stats() catch unreachable){ .entities = 0, .triples = 0, .active = 0 };
            };
            try stdout.print("Entities: {d}\nTotal: {d}\nActive: {d}\n", .{ s.entities, s.triples, s.active });
        }
    } else {
        try stderr.print("Unknown command: {s}\n", .{cmd});
        try stdout.print(USAGE, .{VERSION});
    }
}
