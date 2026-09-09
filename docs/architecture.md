# Architecture

## Why this deviates from `doc/Speech-to-Speech K8S Proposal.md`

The original proposal specified a custom gRPC/protobuf API between
gateway/STT/LLM/TTS. Research into upstream `speech-to-speech` found:

- Its VAD→STT→LLM→TTS pipeline runs as threads in **one process**, wired by
  in-memory `queue.Queue`s - not internally service-oriented, and there is
  no "serve STT only" / "serve TTS only" mode.
- It already ships **OpenAI-compatible HTTP client support** for remote STT
  (`--stt openai`), LLM (`--llm_backend responses-api`), and TTS
  (`--tts openai`), and its own `docker-compose.yml` already proves this
  exact pattern.

This project builds on that existing HTTP support instead of a custom
protocol. gRPC/protobuf remains a documented **future option** (Phase G) if
measured HTTP latency/TTFA under benchmarking proves inadequate - but isn't
built here.

## Components

```
Browser (mic/speaker)
   │  HTTPS (self-signed cert)
   ▼
Traefik   (Ingress, speech ns - node unpinned)
   │ /            │ /v1/realtime (wss, WS upgrade)
   ▼               ▼
speech-demo     speech-gateway   (both node1, CPU only, no GPU)
(upstream's        │  WebSocket, OpenAI Realtime protocol - also reachable
 own demo/ app,     │  directly as ws://<node1-ip>:30765/v1/realtime for the
 unmodified)        │  CLI client / scripted smoke test (no TLS needed there)
                    │ HTTP POST /v1/audio/transcriptions   │ HTTP POST /v1/responses   │ HTTP POST /v1/audio/speech
                    ▼                                      ▼                            ▼
              speech-stt (node3, colocated        speech-llm (node2)            speech-tts (node3, colocated
              with speech-tts - see "GPU           llama.cpp server-cuda,        with speech-stt)
              scheduling constraint" below)         serving a GGUF model         Qwen3-TTS via faster-qwen3-tts
              Parakeet-TDT via nano-parakeet        (no custom code)             (custom FastAPI wrapper)
              (custom FastAPI wrapper)
```

Node assignment above is the actual current layout (see
`docs/deployment.md`'s Status section for how it got here - it's the mirror
image of "Option A" below, not a deliberately chosen option). A CLI client
(`speech-to-speech talk`) or the smoke test can skip Traefik/TLS entirely
and hit the gateway's plain `ws://` NodePort directly; only the browser
demo needs the `wss://` path, because browsers require a secure context for
microphone access and then refuse a plain `ws://` connection from an
`https://` page as mixed content (see `docs/deployment.md` Phase E.2).

- **speech-gateway**: upstream `speech-to-speech` image, unmodified, run as
  `serve <config.json>` (a mounted ConfigMap, not CLI flags) with `stt:
  openai` / `llm_backend: responses-api` / `tts: openai` pointed at the
  three internal Services. See `gateway/Dockerfile` and
  `k8s/configmaps/gateway-config.yaml` for the exact config (verified against
  upstream's `arguments_classes/openai_stt_arguments.py` and
  `openai_tts_arguments.py`, not guessed).
- **speech-demo**: upstream's own browser voice-chat UI (`demo/` in the
  upstream checkout), unmodified app code - only `demo/Dockerfile` is
  vendored here (as a patched copy, see that file's header comment), not
  the rest of `demo/`. Speaks the same OpenAI Realtime protocol as the CLI
  client, dialed directly from the browser (not proxied server-side) - see
  "Security" below for why that puts a TLS requirement on the gateway too.
- **Traefik**: Ingress controller terminating TLS with a self-signed cert,
  fronting both `speech-demo` and `speech-gateway`'s WebSocket under one
  cert/host. Chosen over `kubernetes/ingress-nginx` because that project
  was archived in March 2026 (no further releases/security fixes).
- **speech-stt**: no standalone STT-serve mode exists upstream, so this is
  new code (`stt/`) - a thin FastAPI service loading `nano-parakeet` once at
  startup and exposing `/v1/audio/transcriptions`, mirroring exactly how
  upstream's own `parakeet_tdt_handler.py` drives the model.
- **speech-llm**: no custom code at all - `ghcr.io/ggml-org/llama.cpp:server-cuda`
  serving a GGUF model, exactly matching upstream's own `docker-compose.yml`.
- **speech-tts**: same situation as STT - new code (`tts/`) wrapping
  `faster-qwen3-tts`, exposing `/v1/audio/speech`.

## GPU scheduling constraint

Kubernetes sees GPU **count** (`nvidia.com/gpu: 1` per node), not VRAM size -
the 4GB/16GB/16GB sizing from the original proposal is real hardware but
invisible to the scheduler. Consequences:

- Never request `nvidia.com/gpu: 2` anywhere expecting pooled VRAM across
  nodes - that's not how it works.
- Two **separate** Deployments each requesting `nvidia.com/gpu: 1` cannot
  both schedule onto the same single-GPU node under default (non-MIG,
  non-time-sliced) device-plugin behavior. Validate this directly with
  `k8s/smoke/gpu-coschedule-test-node2.yaml` before relying on any
  co-located placement.
- If the Phase D benchmark picks co-location (e.g. node2 = STT+TTS), use
  `k8s/stt/deployment-colocated-with-tts.yaml` (one Pod, two containers,
  one GPU request) instead of two independent Deployments.

## Storage

Local SSD paths per node (`/mnt/models` on node2 and node3), exposed as
local `PersistentVolume`s (`k8s/storage/`) rather than hostPath directly, so
capacity/binding is tracked properly. One PV+PVC per node backs multiple
components' model caches via `subPath` (`parakeet/`, `qwen3-tts/`, `llm/`) -
a PV can only bind to one PVC, so this is simpler than a PV per subdirectory
and works because same-node pods can share one `ReadWriteOnce` PVC.

## Observability: the HTTP-first tension

The original proposal's KPI list (`stt_queue_ms`, `llm_ttft_ms`,
`tts_ttfa_ms`, etc.) assumed a custom gRPC contract where every hop carries
trace context natively. Plain OpenAI-compatible HTTP has no such field, and
extending the request *body* with custom fields would break compatibility
with the very upstream clients this project relies on.

Pragmatic substitute (Phase F): the gateway generates one ID per turn and
sends it as a custom HTTP **header** (`X-Speech-Request-Id`) - headers don't
break OpenAI-API-shape compatibility. `speech-stt`/`speech-tts` (code we
control) read it and log a structured JSON line per request; `speech-llm`
(llama.cpp, not our code) is treated as one opaque round-trip time from the
gateway's perspective. This gets most of the original tracing value without
an OpenTelemetry pipeline or a custom gRPC contract - full OpenTelemetry
auto-instrumentation (FastAPI + httpx) is a stretch goal, not required for
the first milestone.

## Security

`/v1/realtime` and any `--enable_llm_proxy` endpoint are unauthenticated
upstream; `speech-stt`/`speech-llm`/`speech-tts` are plain unauthenticated
HTTP services by design in this milestone. Acceptable for home-network-only
exposure (`NodePort`, not a public `LoadBalancer`) - `k8s/network-policy/`
restricts the internal services to gateway-only ingress as defense in
depth. Revisit before any exposure beyond the home network.

## Failure model - no HA by design

`replicas: 1` everywhere is intentional. With exactly one 16GB GPU per role,
a crashed `speech-stt`/`speech-llm`/`speech-tts` pod has nowhere else to
reschedule to with a GPU attached except its pinned node. This phase
optimizes for distributed experimentation and learning real VRAM/latency
tradeoffs, not production availability - revisit only after hardware
expansion (the original proposal's own stated purpose is partly to
determine whether 2x16GB is even sufficient before buying more).
