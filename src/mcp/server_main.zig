//! mcp/server_main.zig — MCP server binary entry point.
//! Usage: mempalace-mcp [--palace PATH]
//! Reads JSON-RPC 2.0 from stdin, writes to stdout.

const std = @import("std");
const storage = @import("storage");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var palace_path_buf: [512]u8 = undefined;
    var palace_path: []const u8 = blk: {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        break :blk try std.fmt.bufPrint(&palace_path_buf, "{s}/.mempalace/palace", .{home});
    };

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--palace") and i + 1 < args.len) {
            palace_path = args[i + 1];
            i += 1;
        }
    }

    var palace = try storage.Palace.open(alloc, palace_path);
    defer palace.close();

    var server = mcp.Server.init(&palace, alloc);
    try server.run();
}
