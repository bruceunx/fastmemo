//! graph/lib.zig — Palace graph navigation
//! Built on-demand from drawer metadata. Wings, rooms, tunnels are computed
//! not stored. Matches MemPalace v3 design exactly.

const std = @import("std");
const storage = @import("storage");

pub const GraphError = error{ OutOfMemory, StorageError };

pub const RoomNode = struct {
    wing: []const u8,
    room: []const u8,
    hall: storage.Hall,
    drawer_count: u32,
};

pub const Tunnel = struct {
    room: []const u8, // shared room name
    wings: [][]const u8, // wings that contain this room
};

pub const PalaceGraph = struct {
    alloc: std.mem.Allocator,
    store: *storage.DrawerStore,

    pub fn init(alloc: std.mem.Allocator, store: *storage.DrawerStore) PalaceGraph {
        return .{ .alloc = alloc, .store = store };
    }

    /// Find all rooms where the same room name appears in ≥2 wings.
    pub fn findTunnels(self: *PalaceGraph) GraphError![]Tunnel {
        // Build room → [wings] map by scanning drawers
        const drawers = self.store.query(self.alloc, null, null, 10_000) catch return GraphError.StorageError;
        defer {
            for (drawers) |*d| {
                var dd = d.*;
                dd.deinit(self.alloc);
            }
            self.alloc.free(drawers);
        }

        // room_name → set of wings
        var room_wings = std.StringHashMap(std.StringHashMap(void)).init(self.alloc);
        defer {
            var it = room_wings.iterator();
            while (it.next()) |kv| kv.value_ptr.deinit();
            room_wings.deinit();
        }

        for (drawers) |d| {
            const gop = try room_wings.getOrPut(d.room);
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(self.alloc);
            try gop.value_ptr.put(d.wing, {});
        }

        var tunnels = std.ArrayList(Tunnel).init(self.alloc);
        var it = room_wings.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.count() < 2) continue;
            var wings_list = std.ArrayList([]const u8).init(self.alloc);
            var wit = kv.value_ptr.keyIterator();
            while (wit.next()) |w| try wings_list.append(try self.alloc.dupe(u8, w.*));
            try tunnels.append(Tunnel{
                .room = try self.alloc.dupe(u8, kv.key_ptr.*),
                .wings = try wings_list.toOwnedSlice(),
            });
        }
        return tunnels.toOwnedSlice();
    }

    /// BFS traversal from a room across wings via tunnels. Returns visited rooms.
    pub fn traverse(self: *PalaceGraph, start_room: []const u8, max_hops: u32) GraphError![]RoomNode {
        const tunnels = try self.findTunnels();
        defer {
            for (tunnels) |t| {
                self.alloc.free(t.room);
                for (t.wings) |w| self.alloc.free(w);
                self.alloc.free(t.wings);
            }
            self.alloc.free(tunnels);
        }

        var visited = std.StringHashMap(void).init(self.alloc);
        defer visited.deinit();
        var queue = std.ArrayList([]const u8).init(self.alloc);
        defer queue.deinit();

        try queue.append(start_room);
        try visited.put(start_room, {});

        var results = std.ArrayList(RoomNode).init(self.alloc);
        var hops: u32 = 0;

        while (queue.items.len > 0 and hops < max_hops) : (hops += 1) {
            const current = queue.orderedRemove(0);
            // Find all rooms reachable through tunnels from current
            for (tunnels) |t| {
                if (!std.mem.eql(u8, t.room, current)) continue;
                for (t.wings) |w| {
                    const key = try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ w, t.room });
                    defer self.alloc.free(key);
                    if (visited.contains(key)) continue;
                    try visited.put(key, {});
                    try queue.append(t.room);
                    // Count drawers in this wing+room
                    const dc = countDrawers(self.store, w, t.room);
                    try results.append(RoomNode{
                        .wing = try self.alloc.dupe(u8, w),
                        .room = try self.alloc.dupe(u8, t.room),
                        .hall = .general,
                        .drawer_count = dc,
                    });
                }
            }
        }
        return results.toOwnedSlice();
    }

    pub fn stats(self: *PalaceGraph) GraphError!struct { wings: usize, rooms: usize, tunnels: usize } {
        const wings = self.store.listWings(self.alloc) catch return GraphError.StorageError;
        defer {
            for (wings) |w| self.alloc.free(w);
            self.alloc.free(wings);
        }
        const rooms = self.store.listRooms(self.alloc, null) catch return GraphError.StorageError;
        defer {
            for (rooms) |r| self.alloc.free(r);
            self.alloc.free(rooms);
        }
        const tunnels = try self.findTunnels();
        defer {
            for (tunnels) |t| {
                self.alloc.free(t.room);
                for (t.wings) |w| self.alloc.free(w);
                self.alloc.free(t.wings);
            }
            self.alloc.free(tunnels);
        }
        return .{ .wings = wings.len, .rooms = rooms.len, .tunnels = tunnels.len };
    }
};

fn countDrawers(store: *storage.DrawerStore, wing: []const u8, room: []const u8) u32 {
    const drawers = store.query(store.alloc, wing, room, 100_000) catch return 0;
    defer {
        for (drawers) |*d| {
            var dd = d.*;
            dd.deinit(store.alloc);
        }
        store.alloc.free(drawers);
    }
    return @intCast(drawers.len);
}
