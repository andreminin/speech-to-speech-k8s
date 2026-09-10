#!/usr/bin/env bash
# Per-service smoke tests for Phases B/C/D. Run via kubectl port-forward so
# it works from outside the cluster too.
#
# Usage: ./scripts/smoke-test.sh <llm|stt|tts|gateway|mcp> [args]
set -euo pipefail

NAMESPACE="${NAMESPACE:-speech}"
CMD="${1:-}"
shift || true

pf() {
  local svc="$1" local_port="$2" remote_port="$3"
  # Redirect stdout/stderr so this long-running background process doesn't
  # inherit the pipe backing `pid=$(pf ...)` — otherwise that command
  # substitution blocks forever waiting for EOF that never comes.
  kubectl -n "${NAMESPACE}" port-forward "svc/${svc}" "${local_port}:${remote_port}" >/dev/null 2>&1 &
  local pid=$!
  sleep 2
  echo "${pid}"
}

case "${CMD}" in
  llm)
    pid=$(pf speech-llm 18080 8080)
    trap 'kill "${pid}" 2>/dev/null || true' EXIT
    echo "-- /health"
    curl -sf http://localhost:18080/health
    echo
    echo "-- chat completion"
    curl -sf http://localhost:18080/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"local","messages":[{"role":"user","content":"Say hello in five words."}]}'
    echo
    ;;
  stt)
    wav_file="${1:?usage: smoke-test.sh stt <path-to-16khz-mono-wav>}"
    pid=$(pf speech-stt 18001 8001)
    trap 'kill "${pid}" 2>/dev/null || true' EXIT
    curl -sf -F "file=@${wav_file}" http://localhost:18001/v1/audio/transcriptions
    echo
    ;;
  tts)
    text="${1:-hello from the home lab}"
    out="${2:-/tmp/speech-tts-smoke.pcm}"
    pid=$(pf speech-tts 18002 8002)
    trap 'kill "${pid}" 2>/dev/null || true' EXIT
    curl -sf -X POST http://localhost:18002/v1/audio/speech \
      -H 'Content-Type: application/json' \
      -d "{\"input\": \"${text}\", \"voice\": \"aiden\", \"response_format\": \"wav\"}" \
      --output "${out}"
    echo "wrote ${out} ($(wc -c < "${out}") bytes) — play with: aplay ${out} (or any WAV player)"
    ;;
  gateway)
    # No /health route exists upstream (WS-only ASGI app) - drive the actual
    # OpenAI Realtime protocol instead. Uses a text turn (not audio) so this
    # is runnable without mic/speaker hardware. Requires: pip install websockets
    pid=$(pf speech-gateway 18765 8765)
    trap 'kill "${pid}" 2>/dev/null || true' EXIT
    python3 - <<'PY'
import asyncio, json

async def main():
    import websockets
    async with websockets.connect("ws://localhost:18765/v1/realtime") as ws:
        first = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
        assert first["type"] == "session.created", first
        print("-- session.created OK")
        await ws.send(json.dumps({
            "type": "conversation.item.create",
            "item": {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": "Say hello in five words."}],
            },
        }))
        await ws.send(json.dumps({"type": "response.create"}))
        for _ in range(200):
            evt = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
            if evt["type"] == "response.done":
                print("-- response.done OK")
                return
        raise AssertionError("no response.done received")

asyncio.run(main())
PY
    ;;
  mcp)
    # PoC-only: speech-mcp isn't wired into speech-gateway yet (see
    # speech-mcp/README.md), so this drives its tools directly.
    # Requires: pip install "mcp>=2,<3"
    pid=$(pf speech-mcp 18090 8080)
    trap 'kill "${pid}" 2>/dev/null || true' EXIT
    python3 - <<'PY'
import asyncio

async def main():
    from mcp import Client

    async with Client("http://localhost:18090/mcp") as client:
        tools = await client.list_tools()
        names = sorted(t.name for t in tools.tools)
        print("-- tools/list:", names)
        assert "local_time" in names and "global_internet_search" in names, names

        for tz in ("UTC", "Asia/Tokyo"):
            result = await client.call_tool("local_time", {"timezone": tz})
            print(f"-- local_time({tz}):", result.structured_content)

        result = await client.call_tool(
            "global_internet_search", {"query": "current weather forecast", "max_results": 3}
        )
        results = (result.structured_content or {}).get("results", [])
        print(f"-- global_internet_search: {len(results)} result(s)")
        for r in results:
            print("   -", r.get("title"), "|", r.get("url"))
        assert results, "expected at least one search result"
        print("-- mcp smoke test OK")

asyncio.run(main())
PY
    ;;
  *)
    echo "usage: $0 <llm|stt|tts|gateway|mcp> [args]" >&2
    exit 1
    ;;
esac
