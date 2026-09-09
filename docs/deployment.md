# Deployment

Do these in order. Each step's exit criteria must pass before moving on -
see the corresponding phase in the plan for the full rationale.

## Status (2026-09-09)

- `node2` had a physical outage (kubelet stopped posting status, host
  unreachable to ping) and has since recovered - `kubectl get nodes` shows
  `Ready`, no leftover taints.
- `speech-tts` failed to start against the previously-built image
  (`voicefix1`): the `cudnn-runtime` base image has no C compiler, and
  `qwen_tts`'s rotary-embedding path JIT-compiles a Triton kernel at first
  inference, which needs one. Fixed in `tts/Dockerfile` by adding
  `build-essential`, `python3-dev` (Triton also needs `Python.h`), and `sox`
  (the `faster-qwen3-tts` package shells out to the `sox` binary). Rebuilt
  and pushed as `local-registry:5000/speech-tts:voicefix3`; `k8s/tts/deployment.yaml`
  now points at that tag.
- `scripts/smoke-test.sh`'s `pf()` helper backgrounded `kubectl port-forward`
  without redirecting its output, so it inherited the pipe backing
  `pid=$(pf ...)` and blocked the whole script forever (the port-forward
  process is long-running and never closes that pipe, so the command
  substitution never sees EOF). Fixed by redirecting the backgrounded
  process's stdout/stderr to `/dev/null`.
- Verified individually on `node3`, one at a time (see "GPU scheduling
  constraint" in `docs/architecture.md` - two separate Deployments each
  requesting `nvidia.com/gpu: 1` can't co-schedule on one physical GPU):
  - `speech-tts`: `./scripts/smoke-test.sh tts "hello from the home lab" /tmp/out.wav` → valid WAV returned.
  - `speech-stt`: `./scripts/smoke-test.sh stt wav/16000/test01_20s.wav` → correct transcript returned.
- `speech-llm` validated on `node2` (which is where it's always been pinned,
  since Phase B): `./scripts/smoke-test.sh llm` → `/health` OK and a real
  chat completion returned. VRAM: 8731 MiB / 16380 MiB.
- **STT+TTS colocation on `node3` tested and confirmed working** - see
  "Next plan" below (now done, kept for the rationale/manifest details).
  Both processes share `node3`'s one GPU concurrently via
  `k8s/stt/deployment-colocated-with-tts.yaml` (retargeted from `node2` to
  `node3`); STT and TTS smoke-tested **at the same time** and both
  succeeded. Combined VRAM: 6772 MiB / 16311 MiB - comfortable headroom.
  Recorded in `docs/benchmarks.md`.
- Current cluster layout: `node2 = speech-llm` alone, `node3 = speech-stt +
  speech-tts` colocated in one Pod (`speech-stt-tts`). This is the mirror
  image of the documented "Option A" (`docs/architecture.md` names it
  `node2 = STT+TTS, node3 = LLM`) - node labels swapped from what was
  written, because `speech-llm` has been pinned to `node2` since Phase B
  while `node2`'s outage separately forced STT+TTS onto `node3`. Not yet
  updated to relabel as a new named option; the LLM+TTS alternative
  ("Option B" shape) hasn't been benchmarked.
- Standalone `speech-stt`/`speech-tts` Deployments+Services were deleted in
  favor of the colocated `speech-stt-tts` Deployment (the colocated
  manifest's Services reuse the `speech-stt`/`speech-tts` names, so
  clients don't need to change anything). Restore the standalone manifests
  (`k8s/stt/deployment.yaml`, `k8s/tts/deployment.yaml`) if colocation needs
  to be abandoned.

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
2. **CUDA base image availability**: confirm `local-registry:5000` has a `base` and
   `cudnn-runtime`-flavored CUDA 12.9.x tag. Mirror images if missing:
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
   kubectl get pods -n speech -l test=gpu-coschedule -o wide
   # expect: gpu-coschedule-a Running, gpu-coschedule-b Pending
   # Look at the Events section. The key evidence should be a scheduler message containing:
   # Insufficient nvidia.com/gpu
   kubectl delete -f k8s/smoke/gpu-coschedule-test-node2.yaml
   ```
   Expected output from `get pods` - one node is Running, another is Pending:
   ```
    NAME               READY   STATUS    RESTARTS   AGE   IP              NODE     NOMINATED NODE   READINESS GATES
    gpu-coschedule-a   1/1     Running   0          18s   172.16.104.44   node2    <none>           <none>
    gpu-coschedule-b   0/1     Pending   0          18s   <none>          <none>   <none>           <none>
    ```
   If UnexpectedAdmissionError on -b pod, check status using
   `kubectl describe pod -n speech gpu-coschedule-b`
   Record the result - it determines whether Option A (node2=STT+TTS) later
   uses `k8s/stt/deployment-colocated-with-tts.yaml` instead of two separate
   Deployments.


## Longhorn Setup

Longhorn provides persistent block storage for model files and application data. Follow the dedicated setup guide:

👉 **[Longhorn Setup Guide](./longhorn-setup.md)**

This guide covers:

- Prerequisites (`open-iscsi`, kernel modules, storage directory)
- Helm installation with air-gapped registry overrides
- Mirroring all required container images
- Validating storage with a test PVC and pod
- Common troubleshooting scenarios

**Quick validation** – after completing the Longhorn setup, confirm storage works:

```bash
kubectl apply -f k8s/storage/longhorn-test-pvc.yaml
kubectl get pvc test-longhorn-pvc -n speech -w

# Wait for STATUS: Bound

kubectl apply -f k8s/storage/longhorn-test-pod.yaml
kubectl exec -it test-longhorn-pod -n speech -- touch /data/hello.txt
# Should succeed without error

kubectl delete pod test-longhorn-pod -n speech
kubectl delete pvc test-longhorn-pvc -n speech
```
Once STATUS: Bound, deploy a test pod to verify mounting:

`kubectl apply -f k8s/storage/longhorn-test-pod.yaml`
`kubectl exec -it test-longhorn-pod -n speech -- touch /data/hello.txt`
`kubectl exec -it test-longhorn-pod -n speech -- ls -la /data`

Once validated, proceed to Phase B below.

## Phase B - `speech-llm` standalone

The LLM uses a fast NVMe hostPath mount (/mnt/local-fast) rather than a PVC for maximum I/O performance and to avoid copying multi‑GB model files into Longhorn.

On the node that will run the LLM (we use node2 in this guide), download the GGUF model file:
```bash
# On node2 (or a machine with internet access, then scp the file to node2)
mkdir -p /mnt/local-fast/gemma-model
cd /mnt/local-fast/gemma-model

# Using huggingface-cli (hf) – install with `uv` if needed:
# uv venv -p 3.12 --seed
# source .venv/bin/activate
# uv pip install huggingface-hub
hf download ggml-org/gemma-4-E4B-it-GGUF --include "gemma-4-E4B-it-Q8_0.gguf" --local-dir .

# Alternatively, use wget if you know the direct URL:
# wget -O gemma-4-E4B-it-Q8_0.gguf https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q8_0.gguf
```
Make the file world‑readable so the container can access it:
```bash
sudo chmod -R a+rX /mnt/local-fast/gemma-model
```
Note: The Q8_0 quantisation uses ~8 GB of VRAM and offers higher accuracy than Q4_0. With 16 GB GPUs on node2/node3, this is the recommended trade‑off. If you have less VRAM, use the Q4_0 variant instead.

2. Configure the LLM deployment
Ensure k8s/configmaps/llm-config.yaml has the correct context size and parallelism:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: llm-config
  namespace: speech
data:
  LLM_CTX_SIZE: "65536"
  LLM_PARALLEL: "2"
```    
Update the deployment manifest k8s/llm/deployment.yaml. The critical parts are:

    nodeName: node2 – pin to the node where the model is stored

    hostPath volume pointing to /mnt/local-fast/gemma-model

    args using --model /models/gemma-4-E4B-it-Q8_0.gguf (local file, not -hf)
3. Deploy and validate
```bash
./scripts/deploy.sh llm
kubectl -n speech rollout status deployment/speech-llm
```
Once the pod is Running, test the endpoint:
```bash
kubectl run curl-test --namespace=speech --image=local-registry:5000/cuda:12.9.1-cudnn-runtime-ubuntu24.04 --rm -it --restart=Never --overrides='{"spec":{"imagePullSecrets":[{"name":"local-registry-cred"}],"containers":[{"name":"curl","image":"local-registry:5000/cuda:12.9.1-cudnn-runtime-ubuntu24.04","command":["curl","-s","-X","POST","http://speech-llm-service:8080/v1/completions","-H","Content-Type: application/json","-d","{\"prompt\":\"What is the capital of France?\",\"max_tokens\":30}"]}]}}'
```
```bash
   ./scripts/deploy.sh llm
   kubectl -n speech rollout status deployment/speech-llm
   ./scripts/smoke-test.sh llm
   ./scripts/record-vram.sh <speech-llm-pod-name>
   ```
4. Record VRAM in `docs/benchmarks.md` as the "LLM alone" row.

## Phase C - `speech-stt` standalone

1. On the node that will run STT (`node3` in this guide), pre-download the
   Parakeet `.nemo` checkpoint into the hostPath mount so the pod never has
   to hit the network at startup:
   ```bash
   # On node3 (or a machine with internet access, then scp the file to node3)
   mkdir -p /mnt/local-fast/parakeet-model
   HF_HOME=/mnt/local-fast/parakeet-model hf download nvidia/parakeet-tdt-0.6b-v3 \
     --include "*.nemo"
   chmod -R a+rX /mnt/local-fast/parakeet-model
   ```
   `nano-parakeet` resolves the file via `hf_hub_download`, which only looks
   inside the standard HF cache layout under `$HF_HOME` (i.e.
   `hub/models--nvidia--parakeet-tdt-0.6b-v3/snapshots/<rev>/...`) - a flat
   copy of the file dropped elsewhere in the mount won't be found. The
   Deployment also sets `HF_HUB_OFFLINE=1`/`TRANSFORMERS_OFFLINE=1`, so once
   the cache is populated this way the pod will never attempt a network
   call, even to revalidate - without that env var, `hf_hub_download` still
   reaches out to the Hub on every start even when the cache is warm, which
   can hang the pod (and get it killed as unhealthy) if the cluster has no
   route to huggingface.co.
2. Build and push:
   ```bash
   ./scripts/build-and-push.sh <tag>
   ```
   (update `image:` in `k8s/stt/deployment.yaml` to match `<tag>` if not `latest`)
3. ```bash
   ./scripts/deploy.sh stt
    kubectl -n speech rollout status deployment/speech-stt
    ./scripts/smoke-test.sh stt /path/to/16khz-mono-sample.wav
    ./scripts/record-vram.sh $(kubectl get pods -n speech -l app=speech-stt -o jsonpath='{.items[0].metadata.name}')
   ```
3. Record VRAM + latency in `docs/benchmarks.md` as "STT alone."

## Phase D - `speech-tts` standalone + placement benchmark

1. `speech-tts` image is already built/pushed by `build-and-push.sh` above.
   The base `cudnn-runtime` image ships no C compiler; `tts/Dockerfile`
   installs `build-essential`, `python3-dev`, and `sox` so Triton's
   JIT-compiled kernel and `faster-qwen3-tts`'s `sox` shell-out both work -
   see "Status" above if `Application startup failed` shows a missing
   `gcc`/`Python.h`/`sox` in the pod logs.
2. ```bash
   ./scripts/deploy.sh tts
   kubectl -n speech rollout status deployment/speech-tts
   ./scripts/smoke-test.sh tts "hello from the home lab" /tmp/out.wav
   ./scripts/record-vram.sh <speech-tts-pod-name>
   ```
3. Run the full benchmark matrix (see `docs/benchmarks.md`) - STT alone,
   TTS alone, LLM alone, STT+TTS co-located, LLM+TTS co-located - and
   decide Option A vs Option B. STT+TTS co-location is done, via
   `k8s/stt/deployment-colocated-with-tts.yaml` (retargeted to `node3` -
   see "Next plan" below); the separate `speech-stt`/`speech-tts`
   Deployments were deleted first since the combined manifest defines its
   own Services with the same names. LLM+TTS co-location (the "Option B"
   shape) and full-pipeline TTFA are still open - see `docs/benchmarks.md`.

## Next plan - cooperative GPU sharing for STT + TTS

**Update 2026-09-09: done and confirmed working** - see the "STT+TTS
colocation" bullet in "Status" above and the recorded row in
`docs/benchmarks.md`. Kept below for the reasoning and the options that
weren't needed.

`node3` hosts both `speech-stt` and `speech-tts`. Two separate Deployments
each requesting `nvidia.com/gpu: 1` can't both schedule on its one physical
GPU under the default (non-MIG, non-time-sliced) NVIDIA device-plugin
behavior - confirmed directly by the `UnexpectedAdmissionError ...
Available: 0` events seen when both tried to schedule that way. Options to
let them coexist, roughly in order of how much they change:

1. **Adapt `k8s/stt/deployment-colocated-with-tts.yaml` for `node3`**
   (lowest risk, no cluster-wide config change) - **this is what was
   applied.** This manifest implements the "one Pod, two containers, one
   GPU request" pattern - only the container that declares
   `nvidia.com/gpu: 1` needs the request, the other container gets the
   same GPU visibility for free via the Pod-level device-plugin grant. It
   originally targeted `node2`, a `models-node2` PVC, and
   `stt-config`/`tts-config` ConfigMaps that were stale relative to the
   working setup (`TTS_BACKEND: ggml` vs. the `torch` backend actually in
   use, `HF_HUB_OFFLINE: "0"`, PVC paths instead of `hostPath`). It's now
   retargeted: `nodeName: node3`, two `hostPath` volumes matching the
   former standalone Deployments' mounts (`/mnt/local-fast/parakeet-model`,
   `/mnt/local-fast/tts-model`), inline env vars matching those
   Deployments instead of the stale ConfigMaps, and the working
   `speech-tts:voicefix3` image tag. Result: `2/2 Running` in ~20s (model
   caches already warm), STT and TTS smoke-tested concurrently and both
   succeeded, combined VRAM 6772/16311 MiB.
2. **NVIDIA device-plugin time-slicing** (`replicas: N` in the plugin's
   `ConfigMap`, cluster-wide or per-node via a `nodeSelector`'d plugin
   pod) - not needed: option 1 already works and has comfortable VRAM
   headroom (6.8GB of 16GB used). Would still be worth revisiting only if
   STT and TTS ever need independent scaling/restart, since time-slicing
   lets them stay as two separate Deployments.
3. **NVIDIA MPS** (Multi-Process Service) - lower per-request overhead than
   plain time-sliced context switching for concurrent CUDA processes on one
   GPU, at the cost of extra daemonset/runtime setup. Not needed unless
   option 2 is revisited and shows contention/latency that MPS would fix.
4. **MIG is not available on this hardware** - the RTX 4060 Ti (`node2`)
   and RTX 5060 Ti (`node3`) are consumer GPUs without MIG support, so that
   isolation path (viable on datacenter GPUs like A100/H100) is off the
   table here.

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
