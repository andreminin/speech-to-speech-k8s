# speech-mcp

Experimental Go MCP (Model Context Protocol) server for
`speech-to-speech-k8s`. See
[`mcp/speech-mcp-mcp-experiment-proposal.md`](../mcp/speech-mcp-mcp-experiment-proposal.md)
for the full design rationale, security model, and benchmark plan.

**Status**: wired into the voice pipeline (Phase 4). Both tools are called
by the browser demo (`demo/main.js`'s `TOOL_DEFS`/`runTool`, proxied
server-side by `demo/server.py`'s `/api/mcp/call` route) - not by
`speech-gateway` itself, which stays an unmodified implementation of the
OpenAI Realtime protocol (tool execution is the client's job under that
protocol; see `docs/deployment.md` Phase H for the full rationale). Also
verified directly via `./scripts/smoke-test.sh mcp`.

The server runs with `StreamableHTTPOptions.JSONResponse: true`
(`cmd/speech-mcp/main.go`) so `tools/call` responses come back as plain
`application/json` rather than SSE-framed (`event: message\ndata: ...`) -
simpler for `server.py`'s proxy, which does a single request/response
call and has no need for a streaming connection.

## Tools

- **`local_time`** - current date/time for a given IANA timezone (or the
  server's `MCP_DEFAULT_TIMEZONE` if omitted). Pure computation, no
  external dependencies.
- **`global_internet_search`** - searches the public internet via a
  self-hosted [SearXNG](https://docs.searxng.org/) instance
  (`k8s/searxng/`) and returns concise, structured results
  (title/url/snippet/source). Bounded result count and snippet length;
  SearXNG's response is treated as untrusted data, never as instructions.

Deliberately **not** included in this PoC: `local_cluster_search` (would
need Kubernetes RBAC + `k8s.io/client-go` - see the proposal for why it's
deferred).

## Running locally

```bash
go build ./... && go vet ./...

# Point at a local or port-forwarded SearXNG instance:
export SEARCH_API_URL=http://localhost:18081/search
go run ./cmd/speech-mcp
```

Then, with the official Python MCP client (`pip install "mcp>=2,<3"`):

```python
import asyncio
from mcp import Client

async def main():
    async with Client("http://localhost:8080/mcp") as client:
        print(await client.list_tools())
        print(await client.call_tool("local_time", {"timezone": "Asia/Tokyo"}))
        print(await client.call_tool("global_internet_search", {"query": "current weather in Tokyo"}))

asyncio.run(main())
```

Or just run `./scripts/smoke-test.sh mcp` from the repo root, which does
the same thing against the in-cluster deployment via port-forward.

## Configuration

| Env var | Default | Meaning |
|---|---|---|
| `MCP_HTTP_ADDR` | `:8080` | Listen address for `/mcp` and `/health/*` |
| `SEARCH_API_URL` | `http://searxng:8080/search` | SearXNG search endpoint (JSON format must be enabled there) |
| `TOOL_MAX_RESULTS` | `5` | Default `global_internet_search` result count (capped at 10 regardless of request) |
| `TOOL_TIMEOUT` | `5s` | Timeout for calls to SearXNG |
| `MCP_DEFAULT_TIMEZONE` | `UTC` | `local_time`'s default when no timezone is given |

## Building/deploying

```bash
./scripts/build-and-push.sh <tag>          # builds+pushes speech-mcp and searxng
./scripts/deploy.sh speech_mcp             # or: ./scripts/deploy.sh searxng
kubectl -n speech rollout status deployment/speech-mcp
kubectl -n speech rollout status deployment/searxng
./scripts/smoke-test.sh mcp
```
