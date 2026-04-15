const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared lib modules
    const storage_mod = b.addModule("storage", .{ .root_source_file = b.path("src/storage/lib.zig") });
    const search_mod = b.addModule("search", .{ .root_source_file = b.path("src/search/lib.zig") });
    const graph_mod = b.addModule("graph", .{ .root_source_file = b.path("src/graph/lib.zig") });
    const aaak_mod = b.addModule("aaak", .{ .root_source_file = b.path("src/aaak/lib.zig") });
    const mining_mod = b.addModule("mining", .{ .root_source_file = b.path("src/mining/lib.zig") });
    const mcp_mod = b.addModule("mcp", .{ .root_source_file = b.path("src/mcp/lib.zig") });

    // Wire dependencies between modules
    search_mod.addImport("storage", storage_mod);
    graph_mod.addImport("storage", storage_mod);
    mining_mod.addImport("storage", storage_mod);
    mining_mod.addImport("aaak", aaak_mod);
    mcp_mod.addImport("storage", storage_mod);
    mcp_mod.addImport("search", search_mod);
    mcp_mod.addImport("graph", graph_mod);
    mcp_mod.addImport("aaak", aaak_mod);

    // sqlite3 link helper
    const linkSqlite = struct {
        fn link(step: *std.Build.Step.Compile) void {
            step.linkSystemLibrary("sqlite3");
            step.linkLibC();
        }
    };

    const mod = b.addModule("fastmemo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Main CLI executable
    const exe = b.addExecutable(.{
        .name = "mempalace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fastmemo", .module = mod },
            },
        }),
    });

    exe.root_module.addImport("storage", storage_mod);
    exe.root_module.addImport("search", search_mod);
    exe.root_module.addImport("graph", graph_mod);
    exe.root_module.addImport("aaak", aaak_mod);
    exe.root_module.addImport("mining", mining_mod);
    exe.root_module.addImport("mcp", mcp_mod);
    linkSqlite.link(exe);
    b.installArtifact(exe);

    // MCP server binary (stdio transport)
    const mcp_server = b.addExecutable(.{
        .name = "mempalace-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcp/server_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    mcp_server.root_module.addImport("storage", storage_mod);
    mcp_server.root_module.addImport("search", search_mod);
    mcp_server.root_module.addImport("graph", graph_mod);
    mcp_server.root_module.addImport("aaak", aaak_mod);
    mcp_server.root_module.addImport("mcp", mcp_mod);
    b.installArtifact(mcp_server);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("storage", storage_mod);
    unit_tests.root_module.addImport("search", search_mod);
    unit_tests.root_module.addImport("graph", graph_mod);
    unit_tests.root_module.addImport("aaak", aaak_mod);
    unit_tests.root_module.addImport("mining", mining_mod);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
