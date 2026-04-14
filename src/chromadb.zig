const std = @import("std");

pub const ChromaClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !ChromaClient {
        const base_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, port });
        return ChromaClient{
            .allocator = allocator,
            .base_url = base_url,
            .client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *ChromaClient) void {
        self.allocator.free(self.base_url);
        self.client.deinit();
    }

    pub fn addRoomMemory(
        self: *ChromaClient,
        collection_id: []const u8,
        room_id: []const u8,
        raw_text: []const u8,
        wing: []const u8,
        hall: []const u8,
    ) !void {
        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/api/v1/collections/{s}/add", .{ self.base_url, collection_id });
        defer self.allocator.free(endpoint);
        const uri = try std.Uri.parse(endpoint);

        var payload_string = std.ArrayList(u8).init(self.allocator);
        defer payload_string.deinit();

        const Meta = struct {
            wing: []const u8,
            hall: []const u8,
        };

        try std.json.stringify(.{
            .ids = [_][]const u8{room_id},
            .documents = [_][]const u8{raw_text},
            .metadatas = [_]Meta{.{ .wing = wing, .hall = hall }},
        }, .{}, payload_string.writer());

        var server_header_buffer: [4096]u8 = undefined;
        var req = try self.client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buffer,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = payload_string.items.len };
        try req.send();
        try req.writeAll(payload_string.items);
        try req.finish();
        try req.wait();

        if (req.response.status != .ok and req.response.status != .created) {
            std.debug.print("ChromaDB Error: HTTP {}\n", .{req.response.status});
            return error.ChromaDBRequestFailed;
        }
    }
};
