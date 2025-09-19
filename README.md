# KGProxy — KnowledgeGraphKit-powered streaming memory proxy for LLMs

OpenAI-compatible proxy that:
- Streams responses passthrough (Server-Sent Events)
- Records prompts and responses as Episodes in KnowledgeGraphKit
- Injects KG-derived context ("auto" or "combined") before forwarding
- Works without MCP servers — point your client at this proxy

## Features
- Drop-in: just change your OpenAI base URL to this proxy
- Streaming passthrough with tee (captures assistant output while streaming to client)
- Modes: `conscious`, `auto`, `combined` via headers
- Per-user namespaces for isolation
- Kùzu embedded graph driver by default (fast, vector search, caching)

## Quick start

### Requirements
- Swift 5.9+, macOS 13+
- [Vapor 4](https://docs.vapor.codes/), [AsyncHTTPClient](https://github.com/swift-server/async-http-client)
- OpenAI API key (or pass client Authorization through)

### Configure
```bash
# Upstream (can be overridden by client Authorization headers)
export OPENAI_API_KEY="sk-..."
export OPENAI_BASE_URL="https://api.openai.com"

# KnowledgeGraphKit
export KG_DB_DIR="./data"
export KG_DRIVER="kuzu"   # options: kuzu | sqlite | memory
```

### Run
```bash
swift build
swift run KGProxy
# Server on http://localhost:8080
```

### Use with OpenAI SDKs (streaming)
- Python:
```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8080/v1", api_key="unused-or-your-openai-key")

stream = client.chat.completions.create(
  model="gpt-4o-mini",
  stream=True,
  messages=[{"role":"user","content":"Help me plan a trip to Kyoto"}],
  extra_headers={
    "X-KG-Consent": "true",
    "X-KG-User-ID": "alice",
    "X-KG-Namespace": "alice",
    "X-KG-Mode": "combined",
    "X-KG-Context-Limit": "5"
  }
)
for chunk in stream:
    print(chunk, flush=True)
```

- Curl:
```bash
curl -N http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -H "X-KG-Consent: true" \
  -H "X-KG-User-ID: alice" \
  -H "X-KG-Namespace: alice" \
  -H "X-KG-Mode: combined" \
  -H "X-KG-Context-Limit: 5" \
  -d '{
    "model":"gpt-4o-mini",
    "stream": true,
    "messages":[{"role":"user","content":"What did we decide about the API rollout?"}]
  }'
```

### Headers (KG extensions)
- `X-KG-Consent`: `true` to enable recording/context (required)
- `X-KG-User-ID`: string, user identity for grouping
- `X-KG-Namespace`: string, per-user/project database
- `X-KG-Mode`: `conscious` | `auto` | `combined` (default `combined`)
- `X-KG-Context-Limit`: integer, top-k from KG search

### Endpoints
- `POST /v1/chat/completions` — OpenAI-compatible (streaming and non-streaming)
- `GET /v1/memory/context?q=...` — KG search helper
- `POST /v1/memory/ingest` — ingest free text as an Episode

### Notes
- Streaming passthrough preserves upstream chunks and content-type `text/event-stream`.
- Assistant output is “teed” to reconstruct the final message for ingestion after stream ends.
- Post-response entity/fact extraction is left as a TODO hook to keep latency minimal.

## Roadmap
- Background “Conscious” promotion cache per namespace
- Full adapters pipeline (Text/Calendar with privacy rules)
- Python client utility for memory endpoints
- Basic dashboard for memory stats and deletions
