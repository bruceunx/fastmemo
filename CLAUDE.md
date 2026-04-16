# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build both binaries (mempalace CLI + mempalace-mcp server)
zig build

# Run all tests
zig build test

# Run a single test by name
zig build test -- --test-filter "drawer store open/insert/query"

# Run the CLI
zig build run -- <command> [args]

# Run with a custom palace path
./zig-out/bin/mempalace --palace /tmp/mypalace <command>
```

**System requirement**: `sqlite3` must be installed (`brew install sqlite3` on macOS). The build links against `libsqlite3` and `libc`.

**Minimum Zig version**: 0.15.2 (see `build.zig.zon`).

## Architecture Overview

This is a Zig port of **MemPalace v3.1.0**, a local AI memory system. It produces two binaries:

- `mempalace` — CLI with commands: `init`, `mine`, `search`, `status`, `wake-up`, `kg`, `mcp`, `version`
- `mempalace-mcp` — JSON-RPC 2.0 MCP server over stdio, exposing 19 tools to AI agents

### Module Dependency Graph

```
storage  ←── search
storage  ←── graph
storage  ←── mining  ←── aaak
storage  ←── mcp     ←── search, graph, aaak
```

`storage` is the only module with no imports; everything else depends on it.

### Spatial Ontology (the "palace" mental model)

Content is stored hierarchically: **Wing → Room → Hall → Drawer**. A drawer is a verbatim text chunk. Wings represent people/projects/topics; rooms are named topics within a wing; halls are memory categories (`facts`, `events`, `discoveries`, `preferences`, `advice`, `diary`, `general`). This hierarchy is metadata on SQLite rows — not separate tables.

### Storage Layer (`src/storage/lib.zig`)

Two SQLite databases opened together as `Palace`:

1. **`palace.sqlite3`** — `DrawerStore`: the `drawers` table with full-text content chunks. Drawer IDs are deterministic: `drawer_{wing}_{room}_{md5(source_file+chunk_index)[:16]}`. Dedup is file-level only (`fileExists` check). `query()` fetches up to N drawers ordered by `importance DESC`.

2. **`knowledge_graph.sqlite3`** — `KnowledgeGraph`: `entities` and `triples` tables. Triples are temporal (`valid_from`, `valid_to` as ISO strings). `queryEntity(entity, null)` returns only active triples (`valid_to IS NULL`). `invalidate()` sets `valid_to` on existing triples rather than deleting them.

### Search (`src/search/lib.zig`)

In-process hybrid retrieval — no vector DB. `Searcher.search()` fetches up to 2000 candidates from `DrawerStore`, then scores with **40% BM25 (Okapi/Lucene IDF) + 60% cosine TF-IDF**. All scoring is computed in Zig with `std.mem` token scanning. Results are sorted by combined score; only entries above `0.001` score are returned.

### Mining (`src/mining/lib.zig`)

`Miner.mineDir()` walks a directory recursively, chunks content (800-char chunks, 100-char overlap, paragraph/line boundary splits, discards <50 chars), assigns rooms via 4-priority Claude (folder path → filename stem → keyword frequency → `general`), and inserts into `DrawerStore`. Skips files already present by `source_file` path. Three modes: `projects`, `convos`, `general`.

### AAAK Compression (`src/aaak/lib.zig`)

Lossy abbreviation layer for L1 context loading. `compress()` is fully deterministic (no LLM): detects entities (known codes or first-3-chars of capitalized words), extracts top-3 topic words by frequency, selects the highest decision-keyword-scored sentence (truncated at 55 chars), detects emotion and flag keywords. Output format: `wing|room|date|source\n0:ENTITY+ENTITY|topic|"sentence"|emotion|FLAG`. The `parse()` function reverses this but cannot reconstruct the original content.

### MCP Server (`src/mcp/lib.zig`, `src/mcp/server_main.zig`)

Reads JSON-RPC 2.0 lines from stdin, writes to stdout. Uses a minimal hand-rolled JSON field extractor (`extractJsonStr`, `extractJsonInt`) — not a full parser. Tool dispatch is a flat `if/else` chain in `callTool()`. The `mempalace_status` tool embeds `PALACE_PROTOCOL` — the key prompt instructing agents to query before answering.

### Memory Pattern

All returned slices are caller-owned. Every struct that allocates has a `deinit(alloc)` method. The test suite (`src/tests.zig`) uses `std.testing.tmpDir` for isolated SQLite databases. Tests in `src/tests.zig` are integration-level; unit tests live inline in each module's `lib.zig`.

## CLI Command Reference

```
mempalace init <dir>                    # Initialize palace + mine dir
mempalace mine <dir> [--mode MODE] [--wing NAME]  # MODE: projects|convos|general
mempalace search <query> [--wing W] [--room R] [--n N]
mempalace status
mempalace wake-up [--wing W]            # Print L0 identity + L1 top-15 drawers
mempalace kg add <subj> <pred> <obj> [--from DATE]
mempalace kg query <entity> [--as-of DATE]
mempalace kg timeline <entity>
mempalace kg invalidate <subj> <pred> <obj> --ended DATE
mempalace kg stats
mempalace mcp                           # Print MCP server setup command
```

Default palace path: `~/.mempalace/palace`. Override with `--palace <path>` before the command.

## Known Limitations (from SPEC.md)

- **No contradiction detection** in KG — conflicting triples accumulate silently
- **O(n) L1 loading** — `DrawerStore.query()` scans full collection for top-15
- **AAAK regression** — AAAK mode drops LongMemEval R@5 from 96.6% to 84.2%
- **Naive JSON parsing** — `extractJsonStr` scans linearly, not a real JSON parser; will misparse keys appearing multiple times or in nested objects
- **Hardcoded `filed_at`** — MCP `add_drawer` and diary entries use `"2026-01-01"` as a placeholder instead of the actual current date
