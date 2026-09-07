# speech-to-speech-k8s

Distributed deployment of Hugging Face's [`speech-to-speech`](https://github.com/huggingface/speech-to-speech) pipeline across a home-lab Kubernetes cluster, splitting VAD/gateway, STT, LLM, and TTS across nodes by GPU role instead of requiring one large GPU.

## Why

See [`docs/proposal.md`](doc/Speech-to-Speech%20K8S%20Proposal.md) for the original design proposal and hardware rationale, and [`docs/architecture.md`](docs/architecture.md) for the as-built architecture (an HTTP-first revision of that proposal - see below).

## Architecture at a glance

```
Client (mic/speaker)
   │  WebSocket, OpenAI Realtime protocol
   ▼
speech-gateway   (node1, CPU only)   - VAD, session mgmt, orchestration
   │ HTTP                │ HTTP                  │ HTTP
   ▼                     ▼                       ▼
speech-stt (node2)  speech-llm (node3)      speech-tts (node2 or node3)
Parakeet-TDT         llama.cpp/GGUF          Qwen3-TTS
nano-parakeet        OpenAI-compatible       faster-qwen3-tts
```

Internal transport is plain OpenAI-compatible HTTP, reusing `speech-to-speech`'s own `--stt openai` / `--llm_backend responses-api` / `--tts openai` client support - no custom gRPC/protobuf layer in this milestone (see `docs/architecture.md` for why, and the deferred gRPC option).

## Repo layout

- `gateway/` - packages upstream `speech-to-speech`, runs `serve` pointed at the three internal services. No custom code.
- `stt/` - thin FastAPI wrapper exposing `/v1/audio/transcriptions`, backed by `nano-parakeet` (Parakeet-TDT).
- `tts/` - thin FastAPI wrapper exposing `/v1/audio/speech`, backed by `faster-qwen3-tts` (Qwen3-TTS).
- `llm/` - no code; documents the `llama.cpp` server-cuda image/args used (OpenAI-compatible out of the box).
- `k8s/` - namespace, storage, ConfigMaps, Deployments/Services for all four components, plus one-off smoke-test pods.
- `scripts/` - build/push/deploy/smoke-test helper scripts.
- `docs/` - architecture, deployment steps, benchmark results, observability, troubleshooting.

## Quick start

1. Confirm the cluster is healthy: `kubectl get nodes` should show `node0`-`node3` all `Ready`.
2. Follow [`docs/deployment.md`](docs/deployment.md) in order (registry secret → storage → LLM → STT → TTS → gateway).
3. Talk to it from a client on the LAN:
   ```bash
   pip install speech-to-speech
   speech-to-speech talk --url ws://<node1-ip>:30765/v1/realtime
   ```

## Status

Early build-out stage - component images/manifests exist, but the cluster's worker nodes (node1-node3) need to be back `Ready` before any of this can actually be deployed and benchmarked. See `docs/troubleshooting.md`.
