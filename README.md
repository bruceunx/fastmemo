# FastMemo — Zig Port

A full Zig implementation of the MemPalace AI memory system. Zero runtime dependencies beyond `sqlite3`.

## Requirements

- Zig 0.15.2
- `libsqlite3-dev` (system package)

```bash
# Ubuntu/Debian
sudo apt install libsqlite3-dev

# macOS
brew install sqlite
```

## Build

```bash
zig build                    # debug build
zig build -Doptimize=ReleaseFast   # optimized
zig build test               # run test suite
```

Produces two binaries in `zig-out/bin/`:

- `fastmemo` — CLI
- `fastmemo-mcp` — MCP server (JSON-RPC 2.0 over stdio)

## Usage

```bash
# Initialize and mine a project
fastmemo init ~/projects/myapp

# Mine conversation exports
fastmemo mine ~/chats/ --mode convos --wing myapp

# Search
fastmemo search "why did we switch to GraphQL"
fastmemo search "auth migration" --wing wing_myapp --n 10

# Status overview
fastmemo status

# Wake-up context (L0+L1, ~170 tokens)
fastmemo wake-up
fastmemo wake-up --wing wing_myapp

# Knowledge graph
fastmemo kg add "Alice" "works_on" "Orion" --from 2025-06-01
fastmemo kg query "Alice"
fastmemo kg query "Alice" --as-of 2026-01-01
fastmemo kg timeline "Orion"
fastmemo kg invalidate "Alice" "works_on" "Orion" --ended 2026-03-01
fastmemo kg stats

# MCP server
fastmemo mcp                        # shows setup command
fastmemo-mcp --palace ~/.fastmemo/palace   # run server
```

## MCP Integration (Claude Code / Cursor / etc.)

Add to your MCP config (`~/.claude/mcp_servers.json` or equivalent):

```json
{
  "fastmemo": {
    "command": "fastmemo-mcp",
    "args": ["--palace", "/home/you/.fastmemo/palace"]
  }
}
```

19 tools are available automatically. The `mempalace_status` tool embeds PALACE_PROTOCOL — Claude reads it on startup and knows to call `mempalace_search` / `mempalace_kg_query` before answering questions about past work.

## Architecture

```
src/
├── main.zig              CLI entry point
├── tests.zig             Integration test suite
├── storage/lib.zig       DrawerStore (SQLite) + KnowledgeGraph (SQLite)
├── search/lib.zig        Hybrid BM25 (40%) + cosine TF-IDF (60%)
├── aaak/lib.zig          AAAK lossy compression dialect
├── mining/lib.zig        File/convo ingest, chunking, room detection
├── graph/lib.zig         Palace graph (wings/rooms/tunnels), on-demand
└── mcp/
    ├── lib.zig           JSON-RPC 2.0 MCP server, all 19 tools
    └── server_main.zig   MCP binary entry point
```

### Storage

Two SQLite databases (no external vector DB required):

- `palace.sqlite3` — drawers table with full-text content + metadata
- `knowledge_graph.sqlite3` — temporal entity-relationship triples

### Search

Pure in-process hybrid retrieval. No `chromadb`, no Python:

- **BM25 (40%)**: Okapi BM25 with Lucene IDF, computed over candidate set
- **TF-IDF cosine (60%)**: per-query IDF × per-doc TF, cosine similarity

Retrieval quality is lower than embedding-based search but entirely offline,
zero external dependencies, and sub-millisecond on typical palace sizes.

For production embedding-based search, replace `search/lib.zig` with a
ChromaDB or Qdrant client via their C APIs.

### AAAK

Deterministic lossy abbreviation (matches Python implementation):

- Entity detection → 3-char codes
- Top-3 topics by word frequency
- Key sentence scored by decision keywords, truncated at 55 chars
- Emotion/flag detection from keyword lists

### Memory Stack

| Layer | Content                      | ~Tokens   | When       |
| ----- | ---------------------------- | --------- | ---------- |
| L0    | `~/.fastmemo/identity.txt`  | 50-100    | Always     |
| L1    | Top-15 drawers by importance | ~500      | Always     |
| L2    | Wing/room-scoped recall      | ~300      | On trigger |
| L3    | Full BM25+cosine search      | Unbounded | Explicit   |

### Differences from Python reference

| Feature      | Python                | Zig port            |
| ------------ | --------------------- | ------------------- |
| Vector store | ChromaDB (embeddings) | SQLite BM25+TF-IDF  |
| Embeddings   | sentence-transformers | None (lexical only) |
| Package deps | chromadb, pyyaml      | libsqlite3 only     |
| AAAK         | Identical algorithm   | ✓                   |
| KG           | SQLite                | ✓ identical         |
| MCP tools    | 19                    | 19 ✓                |
| Memory stack | 4-layer               | 4-layer ✓           |

The main trade-off: lexical search misses semantic similarity ("auth" doesn't
match "authentication" unless stemmed). Add a lightweight stemmer or integrate
a C embedding library (llama.cpp / onnxruntime) to recover this.

## build.zig.zon

```zig
.{
    .name = "fastmemory",
    .version = "3.1.0",
    .dependencies = .{},
    .paths = .{"."},
}
```

No external Zig packages — only system `libsqlite3`.

## Linking sqlite3

`build.zig` links system sqlite3. If your sqlite3 is in a non-standard path:

```bash
zig build -Doptimize=ReleaseFast \
  --search-prefix /usr/local \
  -- -lsqlite3
```

Or statically link the amalgamation by adding `sqlite3.c` to the executable:

```zig
exe.addCSourceFile(.{ .file = b.path("vendor/sqlite3.c"), .flags = &.{"-DSQLITE_THREADSAFE=0"} });
```
