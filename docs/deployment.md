# Deployment

Do these in order. Each step's exit criteria must pass before moving on -
see the corresponding phase in the plan for the full rationale.

## Phase A0 - Cluster health

```bash
kubectl get nodes
```
`node0`-`node3` must all show `Ready`. If node1/node2/node3 are `NotReady`,
stop here and fix that first (check power/console/kubelet on each - see
`docs/troubleshooting.md`). Nothing below can schedule onto a `NotReady`
node.

## Phase A - Scaffolding

1. **Registry secret** (credentials are never stored in this repo):
   ```bash
   ./scripts/create-registry-secret.sh
   ```
2. **CUDA base image availability**: confirm `local-registry:5000` has a
   `cudnn-runtime`-flavored CUDA 12.8.x tag (not just a bare `-base` tag -
   torch/cuDNN need it). Mirror one if missing:
   ```bash
   ./scripts/mirror-images.sh local-registry:5000
   ```
3. **Namespace, storage, ConfigMaps**:
   ```bash
   ./scripts/deploy.sh scaffolding
   kubectl get pvc -n speech   # both models-node2 and models-node3 should be Bound
   ```
4. **GPU visibility smoke test** (one node at a time):
   ```bash
   kubectl apply -f k8s/smoke/nvidia-smi-node2.yaml
   kubectl logs -n speech nvidia-smi-node2
   kubectl apply -f k8s/smoke/nvidia-smi-node3.yaml
   kubectl logs -n speech nvidia-smi-node3
   kubectl delete -f k8s/smoke/nvidia-smi-node2.yaml -f k8s/smoke/nvidia-smi-node3.yaml
   ```
5. **GPU co-scheduling constraint** (see `docs/architecture.md`):
   ```bash
   kubectl apply -f k8s/smoke/gpu-coschedule-test-node2.yaml
   kubectl get pods -n speech -l test=gpu-coschedule
   # expect: gpu-coschedule-a Running, gpu-coschedule-b Pending
   kubectl delete -f k8s/smoke/gpu-coschedule-test-node2.yaml
   ```
   Record the result - it determines whether Option A (node2=STT+TTS) later
   uses `k8s/stt/deployment-colocated-with-tts.yaml` instead of two separate
   Deployments.

## Phase B - `speech-llm` standalone

1. Set the real GGUF model repo in `k8s/configmaps/llm-config.yaml`
   (`LLM_HF_REPO`), and the image tag in `k8s/llm/deployment.yaml` if you
   mirrored `llama.cpp:server-cuda` under a different tag.
2. ```bash
   ./scripts/deploy.sh llm
   kubectl -n speech rollout status deployment/speech-llm
   ./scripts/smoke-test.sh llm
   ./scripts/record-vram.sh <speech-llm-pod-name>
   ```
3. Record VRAM in `docs/benchmarks.md` as the "LLM alone" row.

## Phase C - `speech-stt` standalone

1. Build and push:
   ```bash
   ./scripts/build-and-push.sh <tag>
   ```
   (update `image:` in `k8s/stt/deployment.yaml` to match `<tag>` if not `latest`)
2. ```bash
   ./scripts/deploy.sh stt
   kubectl -n speech rollout status deployment/speech-stt
   ./scripts/smoke-test.sh stt /path/to/16khz-mono-sample.wav
   ./scripts/record-vram.sh <speech-stt-pod-name>
   ```
3. Record VRAM + latency in `docs/benchmarks.md` as "STT alone."

## Phase D - `speech-tts` standalone + placement benchmark

1. `speech-tts` image is already built/pushed by `build-and-push.sh` above.
2. ```bash
   ./scripts/deploy.sh tts
   kubectl -n speech rollout status deployment/speech-tts
   ./scripts/smoke-test.sh tts "hello from the home lab" /tmp/out.wav
   ./scripts/record-vram.sh <speech-tts-pod-name>
   ```
3. Run the full benchmark matrix (see `docs/benchmarks.md`) - STT alone,
   TTS alone, LLM alone, STT+TTS co-located, LLM+TTS co-located - and
   decide Option A vs Option B. If co-location wins, swap in
   `k8s/stt/deployment-colocated-with-tts.yaml` (delete the separate
   `speech-stt`/`speech-tts` Deployments+Services first - that combined
   manifest defines its own Services with the same names).

## Phase E - Gateway + first end-to-end voice round trip

1. Set the real `model_name` (matching `LLM_HF_REPO`'s served model id) in
   `k8s/configmaps/gateway-config.yaml`.
2. Build/push the gateway image (needs a sibling checkout of
   `huggingface/speech-to-speech`):
   ```bash
   ./scripts/build-and-push.sh <tag> /path/to/speech-to-speech-checkout
   ```
3. ```bash
   ./scripts/deploy.sh gateway
   kubectl -n speech rollout status deployment/speech-gateway
   ```
4. From a client machine on the LAN:
   ```bash
   pip install speech-to-speech
   speech-to-speech talk --url ws://<node1-ip>:30765/v1/realtime
   ```
   Speak a test utterance; confirm transcript, LLM response, and audible
   synthesized speech all round-trip correctly. If `talk` doesn't connect,
   fall back to a raw WebSocket client (`wscat`, or a short `websockets`
   script) to isolate which hop is failing.
5. Record the observed end-to-end TTFA in `docs/benchmarks.md`.

## Phase F - Probes/resources/observability

Already-applied probes and resource requests/limits can be tuned in place
(`kubectl edit deployment ...` or edit the YAML and re-`apply`) once real
Phase D/E numbers are in. Request-ID propagation and structured logging are
already built into `stt/app/main.py` and `tts/app/main.py` - see
`docs/observability.md` for how to use them.

## Phase G - Deferred

WebRTC, gRPC internal transport, OpenTelemetry, multi-replica/HA, the
optional `demo/` frontend. Not started - see `docs/architecture.md`.
