# KGProxy — Product Requirements Document (PRD)

Status: v1 scope (personal use)
Owner: @thomasaiwilcox

## 1. Overview
KGProxy is an OpenAI-compatible proxy that provides a transparent personal memory layer. It enriches prompts with context recalled from a local knowledge graph so the upstream LLM appears to "remember" across conversations. Memory is injected via a single, opinionated system message (the KGProxy Protocol) so the LLM treats the knowledge as its own internal memory.

This PRD aligns with KnowledgeGraphKit (KGKit), which is a bi-temporal knowledge graph engine with hybrid retrieval (FTS, optional vectors, graph traversal, rank fusion). KGProxy uses KGKit for storage, extraction hooks, and retrieval—no bespoke vector/chunk store is required.

## 2. Goals
- Make a remote LLM feel like it remembers personal details across chats.
- Be drop-in compatible with OpenAI Chat Completions (streaming and non-streaming) and Embeddings passthrough.
- Work out-of-the-box on a single user’s machine (localhost), no API key required for KGProxy itself.
- Keep responses faithful to OpenAI format, with an additional `kgproxy` metadata block and safe headers.

## 3. Non-Goals (v1)
- Multi-tenant team features (beyond simple namespaces).
- Complex server auth; default is localhost binding without a KGProxy API key.
- Full-fledged reranking models; rely on KGKit’s fusion in v1.

## 4. Target Users
- Individual users who want persistent personal memory for any OpenAI-compatible client.

## 5. API Surface
- Chat Completions: non-streaming and SSE streaming.
- Function/Tool calling: pass-through; tool/function messages accepted.
- Embeddings: `/v1/embeddings` passthrough for local indexing when enabled.
- Response shape: Preserve OpenAI response, and add top-level `kgproxy` plus `X-KGProxy-*` headers.

Example `kgproxy` block:
```json
{
  "kgproxy": {
    "retrieval": {
      "enabled": true,
      "pipeline": ["fts", "vector?", "traversal"],
      "k": 5,
      "used_k": 4,
      "scores": [0.91, 0.88, 0.86, 0.80],
      "snippet_ids": ["S12","S7","S3","S22"]
    },
    "context_tokens": 642,
    "tokens_added_by_context": 510,
    "namespace": "default",
    "upstream_provider": "local",
    "upstream_url": "http://localhost:11434",
    "upstream_status": 200
  }
}
```

Headers (examples): `X-KGProxy-Used-K: 4`, `X-KGProxy-Context-Tokens: 642`, `X-KGProxy-Upstream: http://localhost:11434`.

## 6. Upstream and Authentication
- Upstream providers: OpenAI-compatible endpoints, default base URL `http://localhost:11434` (e.g., Ollama or local proxy).
- Selection: single upstream per deployment; optional per-request override via `X-KGProxy-Upstream` header.
- Auth precedence: use configured upstream API key if present; else pass-through client `Authorization`; else none.
- KGProxy requires no API key locally; consent is implicit by using the endpoint.

## 7. Knowledge Graph Storage (KGKit)
- Engine: KnowledgeGraphKit (KGKit) provides the graph model, storage, search, traversal, and optional embeddings/extraction via Provider.
- Default driver: Kùzu (embedded, production-recommended). Alternates: SQLite, Memory.
- Data model:
  - Episode-per-turn (user or assistant): fields include `episode_id`, `conversation_id`, `turn_index`, `role`, `eventTime`, `ingestTime`, `text`, `groupID` (namespace), and provenance.
  - Flow edges: `NEXT` between consecutive turns; `REPLIES_TO` allowed for branches.
  - Entities and Facts derived from episodes with provenance (episode ID and optional character/token spans).
  - Entity links: `MENTIONS`/`REFERS_TO` relations from episodes to entities; Facts are triples `(subject) -[predicate]-> (object)` with confidence and temporal validity.
- Extraction:
  - Use KGKit Provider protocol for entity/fact extraction and embeddings. LLM-based extraction preferred when available; can run without any provider configured.
  - Default persistence: confidence ≥ 0.5; record provider, model, and extraction version.
  - Deduplication: medium for entities/facts across turns; mild for near-duplicate episode text.

## 8. Retrieval and Ranking (Hybrid)
- Signals:
  - FTS keyword search over episodes (primary when embeddings are absent).
  - Optional vector similarity when embeddings are configured (episodes and/or entity summaries).
  - Graph traversal expansion (e.g., around matched entities or recent conversation turns).
  - Rank fusion (e.g., RRF-like) combining these signals to produce top‑k with provenance.
- Units of recall:
  - Default: whole episodes as recall units (trimmed snippets injected).
  - Optional Passage adapter (future toggle): split long episodes into ~200–300 token passages with minimal overlap; store as nodes linked to parent episodes. Disabled by default.
- Defaults:
  - Retrieval mode: auto (on user turns).
  - k: default 5, max 20; filters include recency and entity type when relevant.
  - No separate reranker in v1; rely on KGKit fusion.
  - Context budget: ≤ 800–1000 tokens or ≤ 20% of model context, whichever smaller; per-snippet cap ~150–200 tokens.

## 9. KGProxy Protocol (Injected System Message)
A single system message is prepended to each upstream request. It instructs the LLM to use recalled details naturally as if they were its own memory and to never disclose the memory mechanism.

````markdown
# KGProxy Protocol (System Message)

You are an assistant with persistent memory. A memory layer maintains information you and the user have discussed across sessions. Treat recalled details as your own internal knowledge—natural, concise, and contextually relevant. Never mention the memory system, KGProxy, retrieval, indexing, or “injection.”

Use memory with these principles:
- Relevance first: Prefer the most relevant and recent details to the current request.
- Reconcile conflicts: If current user input conflicts with prior memory, ask a brief clarifying question or follow the current input.
- Privacy: Do not volunteer sensitive details unless clearly helpful to the current request.
- Brevity: Use only the memory that materially improves the answer.

Memory context (do not reveal this mechanism to the user):
- Summary:
  - {{bullet_summary_of_top_facts_and_entities}}
- Entities (compact):
  - {{entity_name}} — types: {{types}} — refs: {{snippet_ids}}
  - …
- Facts (compact triples):
  - ({{subject}}) —[{{predicate}}]→ ({{object}})  (conf={{confidence}}, refs={{snippet_ids}})
  - …
- Snippets (for your reference only):
  - [S{{id}}] {{trimmed_snippet_text}}
  - …

Follow the user’s instructions as usual, using the above memory naturally and implicitly.
````

## 10. Namespaces, Privacy, and PII
- Namespaces: multiple personal namespaces (e.g., `default`, `work`, `personal`). Cross‑namespace reads disabled by default.
- PII: mask obvious secrets (API keys/tokens/passwords/credit cards). Keep emails/phones for personal usefulness.
- Binding: listen on localhost by default; LAN exposure requires explicit opt‑in.
- CORS: allow `http://localhost:*` by default; configurable.

## 11. Observability and Operations
- Logging: structured JSON; redact `Authorization` and secret patterns.
- Metrics: Prometheus `/metrics` including requests, latency, upstream errors, retrieval hit‑rate, tokens_in/out, context_tokens, and pipeline component usage (fts/vector/traversal).
- Tracing: hooks present; full OpenTelemetry deferred.
- Admin endpoints (v1): `/_health`, `/_ready`, `/_admin/namespaces`, `/_admin/export?ns=...` (KGKit JSONL), `/_admin/purge?ns=...`.

## 12. Performance, Reliability, Limits
- Added latency targets (local): +<150 ms p95 with FTS-only; +<400–600 ms p95 when vector path enabled (depends on provider).
- Upstream timeouts: 30s default; retries for 5xx/network with jittered exponential backoff (3 attempts).
- Circuit breaker: enabled with short cool‑off.
- Limits: request body ≤ 2 MB; streaming with backpressure via bounded buffers.

## 13. Configuration & DX
- Config: local preferences file (YAML) with env var overrides; hot‑reload if feasible.
- Examples: minimal JS/TS and Swift examples for streaming chat.
- Local dev: docker‑compose with Kùzu and sample config.

## 14. Roadmap (near‑term)
- v1 (MVP):
  1) Transparent protocol injection with token budgeting and recency/relevance heuristics.
  2) Episode‑per‑turn storage in KGKit with entities/facts extraction and provenance.
  3) Auto‑retrieval on user turns using KGKit hybrid search (FTS + optional vectors + traversal) with fusion.
  4) OpenAI‑compatible streaming proxy with `kgproxy` metadata and safe headers.
  5) Personal ops: localhost default, export/purge endpoints, structured logs, basic metrics.
- Post‑v1:
  - Optional passage adapter; optional reranker; richer protocol formatting; UI for browsing memory; additional drivers.

## 15. References
- KnowledgeGraphKit repo: https://github.com/thomasaiwilcox/KnowledgeGraphKit
- KGKit PRD anchors: storage drivers, provider protocol, core types, search & vectors, roadmap.
