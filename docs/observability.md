# Observability

See `docs/architecture.md` "Observability: the HTTP-first tension" for why
this is header-based logging rather than OpenTelemetry tracing in this
milestone.

## Request-ID propagation

- `stt/app/main.py` and `tts/app/main.py` both read `X-Speech-Request-Id`
  from the incoming request (falling back to a freshly generated UUID if
  absent) and echo it back as a response header.
- Each logs one structured JSON line per request tagged with that ID:
  ```json
  {"component": "stt", "request_id": "...", "duration_ms": 210.4, "audio_seconds": 2.1, "text_len": 34}
  {"component": "tts", "request_id": "...", "duration_ms": 340.2, "ttfa_ms": 95.1, "text_len": 58, "audio_bytes": 65536}
  ```
- **The gateway does not yet send this header** — upstream's
  `--openai_stt_base_url`/`--openai_tts_base_url`/`--responses_api_base_url`
  clients don't expose a hook for custom outbound headers in the current
  CLI. Until that's wired up (a small patch to upstream's HTTP client calls,
  or a lightweight sidecar/proxy that injects the header), `stt`/`tts`
  request IDs are only self-generated per request, not shared with the
  gateway's own turn ID — still useful per-service, not yet a cross-service
  timeline. Fixing this is Phase F work, not yet done.
- `speech-llm` (llama.cpp, not our code) never sees this header — treat the
  whole LLM hop as one opaque round-trip time measured from the gateway
  side.

## Correlating one voice turn across logs

```bash
kubectl -n speech logs deploy/speech-stt | grep '"request_id": "<id>"'
kubectl -n speech logs deploy/speech-tts | grep '"request_id": "<id>"'
```
Once the gateway forwards a shared ID (Phase F), the same command pattern
reconstructs a full per-turn timeline across all three services.

## e2e TTFA

The one KPI measurable today without any cross-service correlation: time
from the gateway's last VAD-detected end-of-speech to the first audio byte
it forwards to the client. Log this from the gateway side manually during
Phase E/D benchmarking until it's automated.

## Future: OpenTelemetry

`opentelemetry-instrumentation-fastapi` / `-httpx` auto-instrumentation
would upgrade the above into real distributed traces with minimal code
(propagates `traceparent` automatically once added to the stt/tts images).
Genuine stretch goal — not required for the first milestone, and not yet
started.
