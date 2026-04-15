# MemPalace — Architecture Specification

**Version**: 3.1.0 (April 2026)  
**Repo**: https://github.com/MemPalace/mempalace  
**Stack**: Python 3.9+, ChromaDB, SQLite, MCP (JSON-RPC 2.0 over stdio)  
**Runtime deps**: `chromadb>=0.5.0,<0.7`, `pyyaml>=6.0`  
**No LLM required** at write time. Zero cloud calls.

---

## 1. Core Concept

"Store everything verbatim, then make it findable via spatial structure." Inspired by the **method of loci** — memories are organized into a navigable building of wings, rooms, halls, tunnels, closets, and drawers. The structure provides progressive scope-narrowing at query time; retrieval improvement comes entirely from metadata filtering, not novel algorithms.

---

## 2. Spatial Ontology

```
Palace
└── Wing          (person | project | topic)
    ├── Hall       (memory type, shared across all wings)
    │   └── hall_facts | hall_events | hall_discoveries | hall_preferences | hall_advice
    ├── Room       (named topic, e.g. "auth-migration", "ci-pipeline")
    │   ├── Closet (AAAK-abbreviated index pointers → drawers)
    │   └── Drawer (verbatim verbatim content chunk)
    └── Tunnel     (cross-wing link when same room name appears in 2+ wings)
```

**Implementation reality**: Wings, rooms, halls are metadata fields on ChromaDB documents, not separate collections or graph nodes. The "palace graph" is computed on-demand by scanning all metadata (O(n) batches of 1000). Tunnels = set intersection of room names across wings. No persistent graph structure exists.

---

## 3. Storage Layer

### 3.1 ChromaDB (`mempalace_drawers`)

Single persistent collection. No per-wing or per-room partitioning.

**Drawer document schema:**

| Field              | Type         | Notes               |
| ------------------ | ------------ | ------------------- |
| `wing`             | str          | Top-level grouping  |
| `room`             | str          | Named topic         |
| `hall`             | str          | Memory category     |
| `source_file`      | str          | Absolute path       |
| `chunk_index`      | int          | Position in file    |
| `added_by`         | str          | Agent ID            |
| `filed_at`         | ISO datetime |                     |
| `importance`       | float        | Used for L1 scoring |
| `emotional_weight` | float        | Fallback L1 score   |

**Document ID** (deterministic): `drawer_{wing}_{room}_{md5(source_file + chunk_index)[:16]}`

**Dedup**: File-level only in mining pipeline (skip entire file if `source_file` already exists). MCP `add_drawer` checks vector similarity before inserting.

### 3.2 SQLite Knowledge Graph (`knowledge_graph.sqlite3`)

Two tables:

```sql
entities (id TEXT PK, name TEXT, type TEXT, properties JSON)
triples  (
    subject TEXT, predicate TEXT, object TEXT,
    valid_from TEXT,  -- ISO date, nullable
    valid_to   TEXT,  -- ISO date, nullable
    confidence FLOAT,
    source_closet TEXT, source_file TEXT
)
```

Entity IDs are slugified names (`alice_obrien`). No entity resolution beyond exact slug matching. Temporal filtering uses ISO string comparison. No graph traversal — flat triple lookup only.

**Known gap**: No contradiction detection. Conflicting triples accumulate silently. `fact_checker.py` exists as a standalone utility but is not wired into KG operations (tracked: Issue #27).

---

## 4. Write Path

### 4.1 Project Mining (`miner.py`)

- Walk dir recursively, 20 supported extensions
- Room assignment (4-priority cascade):
  1. Folder path segment matches a known room name
  2. Filename stem matches room name
  3. Keyword frequency scoring over first 2000 chars
  4. Fallback → `general`
- Chunking: 800-char chunks, 100-char overlap, paragraph/line boundary splits; discard <50 chars
- No LLM in this pipeline

### 4.2 Conversation Mining (`convo_miner.py`)

- Normalizes 5 chat formats → standard transcript: Claude Code JSONL, Claude.ai JSON, ChatGPT JSON, Slack JSON, plain text
- Chunks by exchange pair (user+assistant turn)
- Same room assignment and dedup as project mining
- `split_mega_files.py` pre-splits concatenated multi-session exports before mining

### 4.3 General Extractor

Rule-based classification into 5 categories (decisions, preferences, milestones, problems, emotional context) via regex scoring:

- Code lines stripped pre-scoring
- Segments >500 chars get +2 bonus; confidence = `min(1.0, max_score / 5.0)`
- Segments below 0.3 confidence are dropped
- Conflict resolution: problem + resolution keywords → reclassified as milestone

---

## 5. AAAK Compression (`dialect.py`)

**Status**: Experimental lossy abbreviation layer. Not the storage default. Used for L1 context loading and agent diaries.

**Algorithm** (entirely deterministic, no LLM):

1. Entity detection: known name→code mappings, or first-3-chars of capitalized words
2. Topic extraction: word frequency + proper noun boosting, top-3
3. Key sentence selection: decision-keyword scoring, truncated at **55 chars**
4. Emotion: keyword → abbreviated code
5. Flag: keyword → label (DECISION, CORE, etc.)

**Output format**: `wing|room|date|source_stem\n0:ENTITY+ENTITY|topic|"key sentence"|emotion|FLAG`

**Reality check**:

- "Lossless" claim is false — sentence truncation is irreversible
- Token counting uses `len(text) // 3` heuristic (not a real tokenizer)
- AAAK mode regresses LongMemEval from 96.6% → 84.2% R@5 (−12.4pp)
- Saves tokens only at scale with many repeated entities; incurs overhead at small scales

---

## 6. Read Path

### 6.1 4-Layer Memory Stack (`layers.py`)

| Layer | Content                                                                                           | ~Tokens   | When loaded      |
| ----- | ------------------------------------------------------------------------------------------------- | --------- | ---------------- |
| L0    | `~/.mempalace/identity.txt` (user-authored)                                                       | ~50–100   | Always           |
| L1    | Top-15 drawers scored by `importance`/`emotional_weight`, grouped by room, truncated at 200 chars | ~500–800  | Always           |
| L2    | Wing/room-scoped recall, 300-char snippets                                                        | ~200–500  | On topic trigger |
| L3    | Full semantic search across all closets                                                           | Unbounded | Explicit query   |

Wake-up (L0+L1) ≈ 170 tokens — a genuine differentiator for token economy.

**L1 bottleneck**: loads all metadata from ChromaDB to score top-15 → O(n) per wake-up. Degrades at scale.

### 6.2 Semantic Search (`searcher.py`)

```python
col.query(query_texts=[query], n_results=N, where=filter)
```

`where` filter options: `{"wing": w}`, `{"room": r}`, `{"$and": [{"wing": w}, {"room": r}]}`

Distance → similarity: `round(1 - dist, 3)`. No reranking, no BM25 in v3.0. **v3.1 adds hybrid search**: 60% vector + 40% BM25 (Okapi BM25 with Lucene IDF).

### 6.3 Palace Graph (`palace_graph.py`)

- Built on demand by scanning all ChromaDB metadata in 1000-item batches
- Rooms connected if they share a wing
- Tunnels = rooms appearing in 2+ wings
- No edge weights, no semantic similarity, no multi-hop in KG

---

## 7. MCP Server (`mcp_server.py`)

Transport: JSON-RPC 2.0 over stdin/stdout.  
Tools: **19 total** across 5 categories.

| Category        | Tools                                                                                              |
| --------------- | -------------------------------------------------------------------------------------------------- |
| Palace (read)   | `status`, `list_wings`, `list_rooms`, `get_taxonomy`, `check_duplicate`, `get_aaak_spec`, `search` |
| Palace (write)  | `add_drawer`, `delete_drawer`                                                                      |
| Knowledge Graph | `kg_query`, `kg_add`, `kg_invalidate`, `kg_timeline`, `kg_stats`                                   |
| Navigation      | `traverse`, `find_tunnels`, `graph_stats`                                                          |
| Agent Diary     | `diary_write`, `diary_read`                                                                        |

`mempalace_status` embeds `PALACE_PROTOCOL` — prompt text instructing the AI to call `mempalace_kg_query` or `mempalace_search` before answering questions about people/projects. This is the key hallucination-reduction mechanism.

Initialization:

```python
_config = MempalaceConfig()
_kg = KnowledgeGraph(db_path=palace_path / "knowledge_graph.sqlite3")
```

---

## 8. Specialist Agents

Agent definitions live in `~/.mempalace/agents/*.json` (focus, wing, diary location). Each agent:

- Has a dedicated wing in ChromaDB (distinguished by metadata)
- Writes AAAK diary entries via `mempalace_diary_write`
- Reads history via `mempalace_diary_read(agent_id, last_n=N)`
- Is discovered at runtime via `mempalace_list_agents` — CLAUDE.md needs only one line

Diary entries stored in the same `mempalace_drawers` collection, differentiated by `type: diary_entry` metadata.

---

## 9. Auto-Save Hooks

| Hook                        | Trigger                                       | Behavior                                                                 |
| --------------------------- | --------------------------------------------- | ------------------------------------------------------------------------ |
| `mempal_save_hook.sh`       | Claude Code `Stop` event (every ~15 messages) | Structured save: topics, decisions, quotes, code changes; regenerates L1 |
| `mempal_precompact_hook.sh` | Claude Code `PreCompact` event                | Emergency save before context compression                                |

Known issue (fixed in v3.1): shell injection vulnerability in save hook (#110).

Optional auto-ingest: set `MEMPAL_DIR` env var → hooks run `mempalace mine` in background on stop, synchronously on precompact.

---

## 10. Configuration

```
~/.mempalace/
├── config.json          # palace_path, collection_name, people_map
├── wing_config.json     # wing → type + keywords mapping (generated by init)
├── identity.txt         # L0 persona (user-authored)
└── agents/
    └── *.json           # specialist agent definitions
```

All commands accept `--palace <path>` to override default location.

---

## 11. Benchmarks (Honest Summary)

| Mode                | Benchmark               | Score     | Notes                                                              |
| ------------------- | ----------------------- | --------- | ------------------------------------------------------------------ |
| Raw (ChromaDB only) | LongMemEval R@5         | **96.6%** | Verbatim text + default embeddings. Palace structure NOT involved. |
| AAAK mode           | LongMemEval R@5         | 84.2%     | −12.4pp vs raw                                                     |
| Raw                 | LoCoMo R@10             | 60.3%     | Mediocre vs field                                                  |
| Raw (top-50)        | LoCoMo R@10             | 77.8%     | 5× more context                                                    |
| Wing+room filter    | Retrieval vs unfiltered | +34%      | Standard metadata filtering, not novel                             |

The 96.6% headline is essentially ChromaDB's embedding performance on LongMemEval — not a unique MemPalace capability. Benchmark scripts are reproducible (genuine strength).

---

## 12. Known Issues & Gaps

| Area                        | Issue                                                                   |
| --------------------------- | ----------------------------------------------------------------------- |
| **Contradiction detection** | Not implemented in KG; `fact_checker.py` exists but unwired             |
| **Scale**                   | O(n) palace graph build + L1 loading over full collection               |
| **Dedup**                   | File-level only; semantic dedup only in MCP write path                  |
| **Entity resolution**       | Naive slug matching; no disambiguation                                  |
| **KG fragility**            | Hardcoded column indices (`row[10]`, `row[11]`); string date comparison |
| **No memory decay**         | Memories accumulate without recency weighting or pruning                |
| **No provenance**           | No correction chains, no versioned updates                              |
| **ChromaDB range**          | Pin to `>=0.5.0,<0.7` (macOS ARM64 segfault on older versions: #74)     |
| **Security**                | MCP `add_drawer` has no write gating; prompt injection surface          |

---

## 13. Module Map

| Module                | Responsibility                                       |
| --------------------- | ---------------------------------------------------- |
| `cli.py`              | Argparse entry point for all CLI commands            |
| `config.py`           | Config loading, env var resolution, defaults         |
| `normalize.py`        | 5-format chat transcript normalizer                  |
| `miner.py`            | Project file ingest + chunking                       |
| `convo_miner.py`      | Conversation ingest (chunks by exchange pair)        |
| `split_mega_files.py` | Pre-split concatenated transcript files              |
| `searcher.py`         | ChromaDB query wrapper + hybrid BM25 (v3.1)          |
| `layers.py`           | 4-layer memory stack loader                          |
| `dialect.py`          | AAAK compression/abbreviation                        |
| `knowledge_graph.py`  | SQLite temporal entity-relationship graph            |
| `palace_graph.py`     | On-demand room navigation graph from metadata        |
| `mcp_server.py`       | JSON-RPC 2.0 MCP server + PALACE_PROTOCOL            |
| `onboarding.py`       | Guided init, AAAK bootstrap, wing config generation  |
| `entity_registry.py`  | Name→code mapping registry                           |
| `entity_detector.py`  | Auto-detect people/projects from content             |
| `fact_checker.py`     | Standalone assertion checker (not yet wired into KG) |
| `hooks/*.sh`          | Claude Code auto-save shell scripts                  |
