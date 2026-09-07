# speech-llm

No custom code or Dockerfile here on purpose. `speech-llm` reuses
[`llama.cpp`'s `server-cuda` image](https://github.com/ggml-org/llama.cpp)
directly, exactly matching upstream `speech-to-speech`'s own
`docker-compose.yml` pattern — it already speaks an OpenAI-compatible
`/v1/chat/completions` / `/v1/responses`-ish API and is proven to
interoperate with `--llm_backend responses-api`.

## Image

Public image: `ghcr.io/ggml-org/llama.cpp:server-cuda`

If node3 has no direct internet egress, mirror it first:

```bash
./scripts/mirror-images.sh local-registry:5000
```

which pushes it to `local-registry:5000/llama-cpp-server-cuda:<tag>`.
Update `k8s/llm/deployment.yaml`'s `image:` field to match whichever you use.

## Model choice

Pick a GGUF model + quantization that fits comfortably in 16GB with headroom
for the Phase D benchmark's LLM+TTS co-location trial (a 7-8B class model at
Q4_K_M/Q5_K_M is a reasonable starting point). Record the actual choice and
measured VRAM/TTFT in `docs/benchmarks.md` once benchmarked — don't guess
here.

## Server arguments

Mirrors upstream's own `docker-compose.yml`:

```
-hf <org/model-GGUF-repo>
-np 2
-c 65536
-fa on
--swa-full
--host 0.0.0.0
--port 8080
```

`-hf` pulls the model into the container's HF cache on first start — mount a
PVC at `/root/.cache` (see `k8s/llm/pvc.yaml`, backed by `/mnt/models/llm` on
node3) so it isn't re-downloaded on every pod restart.

## Health

llama.cpp's server exposes a built-in `GET /health` — used directly as the
Deployment's readiness/liveness probe.

## vLLM alternative

vLLM offers better throughput/batching under concurrent requests, but weaker
GGUF support (favors AWQ/GPTQ or unquantized weights, more VRAM pressure) —
a worse fit for a single-user home-lab pipeline where this GPU may also host
TTS. Revisit only if benchmarking shows llama.cpp's decode speed is the TTFA
bottleneck.
