# Deployment

Do these in order. Each step's exit criteria must pass before moving on -
see the corresponding phase in the plan for the full rationale.

## Prerequisite: upstream checkout

`speech-gateway` and `speech-demo` (Phase E) build directly from a checkout
of `huggingface/speech-to-speech` rather than vendoring its code - only a
handful of files that need a local patch are vendored (`gateway/Dockerfile`,
`demo/Dockerfile`). `scripts/build-and-push.sh` defaults to
`../../huggingface/speech-to-speech`, resolved relative to wherever you run
it from - so clone it as a **sibling of this repo's parent directory**, e.g.
if this repo is at `~/workspace/speech-to-speech-k8s`:

https://github.com/andreminin/speech-to-speech project is forked https://github.com/huggingface/speech-to-speech

Clone https://github.com/huggingface/speech-to-speech project in the same folder as speech-to-speech-k8s:
```bash
cd ~/workspace/
git clone https://github.com/andreminin/speech-to-speech.git
```

Pass a different path as `build-and-push.sh`'s second argument if your
layout differs.

## Status

Current cluster layout: `node2 = speech-llm`, `node3 = speech-stt +
speech-tts` colocated in one Pod (`speech-stt-tts`), `node1 = speech-gateway
+ speech-demo` (+ Traefik, unpinned). This is the mirror image of the
documented "Option A" (`docs/architecture.md` names it `node2 = STT+TTS,
node3 = LLM`) - not a deliberately chosen option, just where things ended
up (node2 was briefly unavailable early on and speech-llm has been pinned
to node2 since Phase B; the two constraints together produced this layout).
The "Option B" shape (LLM+TTS colocated) hasn't been benchmarked.

All components deployed and individually verified:

- `speech-llm` (node2): `./scripts/smoke-test.sh llm` OK. VRAM 8731/16380 MiB.
- `speech-stt` + `speech-tts` (node3, colocated via
  `k8s/stt/deployment-colocated-with-tts.yaml` - two containers, one GPU
  request, since node3's single GPU can't satisfy two separate Deployments
  each requesting `nvidia.com/gpu: 1`): smoke-tested **concurrently**, both
  succeeded. Combined VRAM 6772/16311 MiB - comfortable headroom. Recorded
  in `docs/benchmarks.md`.
- `speech-gateway` (node1): `./scripts/smoke-test.sh gateway` OK - a real
  text-turn round trip through STT → LLM → TTS via the OpenAI Realtime
  protocol.
- `speech-demo` (node1) + Traefik (TLS, self-signed cert): deployed,
  `1/1 Running`. Full manual browser verification done (Phase E.2 step 7) -
  a real human, over the LAN, spoke into the mic and got a real answer back
  as text. One early false alarm along the way: the first reply looked like
  it ignored the question ("Hi there, what can I help you with today?") -
  that's the demo's own `STARTUP_GREETING` firing automatically on session
  open (a fixed prompt, unrelated to anything the user says), not a pipeline
  bug. Disabled it (`STARTUP_GREETING: ""` in `k8s/demo/deployment.yaml`) so
  the first reply is always an actual answer.
  **RESOLVED - voice audio now confirmed audible in the browser.** The
  browser SDK's `_onAudio` callback was never firing despite the backend
  correctly sending `response.output_audio.delta` events (see "Next: voice
  output in the browser" below for the full trace of that investigation) -
  this stopped reproducing once a home-lab network issue was fixed (a
  workstation NIC left on DHCP instead of static, causing IP churn that
  rippled into node2/node3 kubelet flapping - see the pod-storm incident
  note further down). Correlation, not a proven single root cause, but the
  symptom has not recurred since. If it ever comes back, resume from that
  section's decision tree.
- **Voice selection bug found and fixed**: the demo's UI lets you pick a
  voice (Aiden/Ryan/Dylan/Eric/Ono_Anna/Serena/Sohee/Uncle_Fu/Vivian -
  Qwen3-TTS-CustomVoice's real built-in presets), but `tts/app/main.py` only
  ever allowlisted `["aiden"]` (a side effect of the earlier voice-casing
  fix), so every voice except Aiden silently fell back to Aiden. Two parts
  to the fix:
  1. `tts/app/main.py`: `AVAILABLE_VOICES` now defaults to all 9 real
     presets, matched case-insensitively; only falls back to the default
     voice for a genuinely unrecognized name now (logged as
     `voice_fallback` when it happens). `tts/Dockerfile`'s baked-in
     `TTS_VOICES=aiden` default updated too.
  2. **The actual blocker in practice**: `k8s/stt/deployment-colocated-with-tts.yaml`
     explicitly sets `TTS_VOICES` as a container env var, which overrides
     whatever the image/code defaults to - it still said `"aiden"` alone
     even after fixing the code, so voice selection kept silently failing
     until that env var was updated too (now lists all 9 presets
     explicitly, with a comment explaining why, so this doesn't quietly
     regress again).

  Along the way, rebuilding `speech-tts` at all (unrelated to this fix -
  triggered by any `COPY app ./app` layer change) exposed a **separate,
  unrelated dependency-drift bug**: `tts/pyproject.toml` never pinned
  `transformers` (a transitive dep via `faster-qwen3-tts`), so a fresh
  `pip install .` picked up `transformers` 5.17.0 instead of the
  previously-working 5.16.1, and 5.17.0's `MimiConfig` refactor broke
  `qwen_tts`'s RoPE compat shim (`AttributeError: 'MimiConfig' object has
  no attribute 'rope_theta'`) - the model failed to load at all. Fixed by
  pinning `transformers==5.16.1` in `tts/pyproject.toml`. Final working
  image: `speech-tts:voicefix6`.
- **`speech-demo` is back on the clean `v1` image tag** (not the
  `debug2` build used during the audio investigation - see below).
- New `scripts/install.sh` / `scripts/cleanup.sh` - one-command bring-up
  (applies every manifest via `deploy.sh`, waits for rollouts, prints
  access URLs) and tear-down (deletes the `speech` namespace plus
  Traefik's cluster-scoped RBAC/IngressClass; node-local model caches are
  untouched). `scripts/deploy.sh`'s `stt`/`tts` phases were also fixed to
  apply the colocated manifest that's actually running, instead of the
  stale standalone `k8s/stt/deployment.yaml` + `k8s/tts/deployment.yaml`.

Standalone `speech-stt`/`speech-tts` Deployments+Services
(`k8s/stt/deployment.yaml`, `k8s/tts/deployment.yaml`) are **not applied** -
replaced by the colocated `speech-stt-tts` Deployment, whose Services reuse
the same names so nothing else had to change. Restore the standalone
manifests if colocation ever needs to be abandoned.

Not yet done: the LLM+TTS co-location benchmark and latency/TTFA
measurements. The full end-to-end browser voice test (mic → transcript →
LLM → audible synthesized speech) is now done - see "Voice output in the
browser" below for the (resolved) investigation and
`docs/troubleshooting.md` for the DHCP/node-flapping incident that
coincided with it.

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

**Done (2026-09-09).** `speech-gateway`'s three k8s manifests had drifted out
of sync with each other and with `gateway/Dockerfile` (wrong node, wrong
port, unused env vars, the `gateway-config` ConfigMap never actually
mounted, a placeholder `model_name`, and a third conflicting embedded
`Service`) - none of it worked before this pass. Fixed:

1. `k8s/configmaps/gateway-config.yaml`: `model_name` set to
   `/models/gemma-4-E4B-it-Q8_0.gguf` (the literal string llama.cpp reports
   as `"model"` in its chat-completion response - confirmed via
   `./scripts/smoke-test.sh llm`).
2. `k8s/gateway/deployment.yaml` rewritten: `nodeName: node1` (was `node0`,
   the control-plane node - `nodeName` pinning bypasses the scheduler's
   taint check, so that pod would have landed there rather than been
   rejected), `containerPort: 8765` (was 8080), `gateway-config` mounted at
   `/etc/speech-to-speech` and passed as `args: ["serve",
   "/etc/speech-to-speech/config.json"]` (upstream's `parse_arguments` only
   takes the JSON-config path when it's the single positional arg - no
   `--host`/`--port` alongside it), `tcpSocket` readiness/liveness probes
   (no `/health` route exists upstream - confirmed by reading
   `api/openai_realtime/server.py` in the pinned checkout), and the
   duplicate embedded `Service` block deleted (`k8s/gateway/service.yaml` +
   `service-nodeport.yaml` already covered ClusterIP 8765 / NodePort 30765
   correctly).
3. Build/push (see "Prerequisite: upstream checkout" above):
   ```bash
   ./scripts/build-and-push.sh <tag> /path/to/speech-to-speech-checkout
   ```
4. ```bash
   ./scripts/deploy.sh gateway
   kubectl -n speech rollout status deployment/speech-gateway
   ./scripts/smoke-test.sh gateway
   ```
   The `gateway` smoke test drives the actual OpenAI Realtime protocol over
   the WebSocket with a **text** turn (no mic/speaker hardware needed) -
   requires `pip install websockets` on whatever host runs it.
5. **Known gotcha**: on cold start the gateway downloads the Silero VAD
   model from GitHub via `torch.hub.load` - this failed with DNS resolution
   errors several times in a row before succeeding (`node1` clearly has
   real internet access - confirmed directly via SSH - so this looks like a
   transient in-pod DNS flake, not a hard block). Kubernetes' restart policy
   retried it into working. If this becomes a recurring problem, pre-seed
   `/root/.cache/torch/hub` via a hostPath volume (same pattern as the
   STT/TTS/LLM model caches) rather than relying on retries.
6. Manual verification with a real client (needs a human with a mic - not
   scriptable):
   ```bash
   pip install speech-to-speech
   speech-to-speech talk --url ws://<node1-ip>:30765/v1/realtime
   ```
   Speak a test utterance; confirm transcript, LLM response, and audible
   synthesized speech all round-trip correctly.
7. Record the observed end-to-end TTFA in `docs/benchmarks.md`.

## Phase E.2 - Browser voice-chat UI

**Done (2026-09-09).** Reuses upstream's own `demo/` app (a browser
voice-chat UI already speaking the same OpenAI Realtime protocol) rather
than building custom UI code - matches this repo's "thin wrapper around
upstream" convention. Two things had to be solved beyond just deploying it:

- **TLS**: browsers refuse microphone access (`getUserMedia()`) over plain
  `http://<lan-ip>` - only `https://` or `localhost` count as a secure
  context. `kubernetes/ingress-nginx` was archived in March 2026 (no
  further releases/security fixes) so it's not something to newly install;
  **Traefik** is used instead (`k8s/traefik/deployment.yaml` - static
  manifests, no Helm, deployed into the `speech` namespace to reuse the
  existing `local-registry-cred` secret) with a self-signed cert (SANs for
  all 4 node IPs) as a k8s `Secret`.
- **Mixed content**: once the demo page is served over `https://`, browsers
  block a plain `ws://` connection dialed from it as mixed active content -
  and `SPEECH_TO_SPEECH_URL` is dialed **client-side by the browser itself**
  (confirmed from the demo's own README), not proxied through the demo
  server. So the gateway's WebSocket also has to be reachable as `wss://`
  through the *same* Ingress/cert, not just the demo's static page -
  `k8s/traefik/ingress.yaml` routes both `/v1/realtime` (→ `speech-gateway`)
  and `/` (→ `speech-demo`) under one TLS block.

**Known gotcha (cost real debugging time - documented so it isn't repeated)**:
declaring `--entrypoints.websecure.address=:8443` alone is not enough. The
entrypoint will still opportunistically complete a TLS handshake (serving
*some* cert), and the Traefik API will show the Ingress-derived routers and
services as fully `"enabled"`/`"UP"` - but every real request 404s anyway,
because the entrypoint was never told to actually terminate TLS for its
routers. The fix is `--entrypoints.websecure.http.tls=true` (already in
`k8s/traefik/deployment.yaml`). Confirmed by testing the exact same
router/rule through a second, plain-HTTP entrypoint (worked immediately)
before finding this flag - if a `wss://`/`https://` Ingress path 404s
despite `/api/http/routers` and `/api/http/services` looking correct, this
flag is the first thing to check.

Steps:

1. Mirror Traefik (`traefik` entry added to `scripts/mirror-images.sh`):
   ```bash
   docker pull docker.io/library/traefik:v3.3
   docker tag docker.io/library/traefik:v3.3 local-registry:5000/traefik:v3.3
   docker push local-registry:5000/traefik:v3.3
   ```
2. Self-signed cert + Secret (regenerate if node IPs ever change):
   ```bash
   openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
     -keyout tls.key -out tls.crt -subj "/CN=speech-demo.local" \
     -addext "subjectAltName=IP:192.168.10.30,IP:192.168.10.31,IP:192.168.10.32,IP:192.168.10.33,DNS:speech-demo.local"
   kubectl -n speech create secret tls speech-demo-tls --cert=tls.crt --key=tls.key
   ```
3. ```bash
   ./scripts/deploy.sh traefik
   kubectl -n speech rollout status deployment/traefik
   ```
4. Build/push the demo image - only `demo/Dockerfile` is vendored in this
   repo (a patched copy of upstream's own; see that file's header comment
   for why), the rest of `demo/`'s app code is *not* copied in, build
   context is the upstream checkout's `demo/` subfolder:
   ```bash
   ./scripts/build-and-push.sh <tag> /path/to/speech-to-speech-checkout
   ```
5. `k8s/demo/deployment.yaml`'s `SPEECH_TO_SPEECH_URL` must be the
   Ingress's `wss://<node-ip>:30443/v1/realtime` address (matching whatever
   `nodePort` `k8s/traefik/deployment.yaml`'s Service uses) - **not** the
   plain gateway NodePort and **not** a cluster-internal Service DNS name,
   for the mixed-content reason above.
   ```bash
   ./scripts/deploy.sh demo
   kubectl -n speech rollout status deployment/speech-demo
   ```
6. Protocol-level check (scriptable, no mic needed) - confirms the `wss://`
   path through the Ingress actually completes the OpenAI Realtime
   handshake, isolating Traefik/TLS/routing from the browser/audio layer:
   ```bash
   python3 -c "
   import asyncio, json, ssl, websockets
   async def main():
       ctx = ssl.create_default_context()
       ctx.check_hostname = False
       ctx.verify_mode = ssl.CERT_NONE
       async with websockets.connect('wss://<node-ip>:30443/v1/realtime', ssl=ctx) as ws:
           evt = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
           assert evt['type'] == 'session.created', evt
           print('OK')
   asyncio.run(main())
   "
   ```
7. Manual verification (needs a human with a mic on the LAN - not
   scriptable): open `https://<node-ip>:30443/`, accept the self-signed
   cert warning once per device, click the orb, speak, confirm the transcript
   + LLM reply + synthesized audio all round-trip. **Done - full round trip
   including audible synthesized speech confirmed working.**

## Voice output in the browser (RESOLVED)

**Update: resolved.** Full voice round trip (mic → transcript → LLM →
audible synthesized speech) now confirmed working in a real browser, voice
selection included. The investigation below is kept as a record - the
symptom stopped reproducing once a home-lab network issue (a workstation
NIC left on DHCP, causing IP churn that rippled into node2/node3 kubelet
flapping - see `docs/troubleshooting.md`) was fixed, but that's a
correlation observed during debugging, not a proven single root cause -
if the symptom (`_onAudio` never firing despite the backend correctly
sending `response.output_audio.delta`) ever recurs, resume from "Next
debugging step" below.

Original framing while this was still open: mic input worked,
text/transcript output worked reliably, but synthesized speech was not
heard even on a clean, uninterrupted turn.

### Found and fixed along the way (real bugs, keep these)

- **TTS voice-name case mismatch (real bug, fixed)**: `tts/app/main.py` used
  to hard-reject any `voice` not exactly matching `AVAILABLE_VOICES`
  (`["aiden"]`) with HTTP 400. The gateway's realtime session lets the
  client (the browser SDK) override the voice per-turn
  (`openai_compatible_handler.py`'s `_resolve_voice`), and the real browser
  session sent `"Aiden"` (capitalized) - a **case mismatch**, not a
  different voice - causing every real TTS call from the gateway to fail
  with 400 (confirmed directly in `speech-tts` logs:
  `POST /v1/audio/speech HTTP/1.1" 400 Bad Request`, repeated). Fixed by
  falling back to the configured default voice on any unrecognized name
  instead of rejecting (`tts/app/main.py`, logs a `voice_fallback` line
  when it happens). Rebuilt/pushed as
  `local-registry:5000/speech-tts:voicefix4`;
  `k8s/stt/deployment-colocated-with-tts.yaml` now points at that tag.
  **Confirmed fixed**: TTS calls now return 200 OK and real audio bytes
  flow (verified both via a scripted client and live gateway logs showing
  `audio=210.38s` of cumulative synthesized audio across a real browser
  session).
- Despite that fix, **audio is still not heard in the browser** on a clean
  turn (confirmed by the user: "No audio, but text worked"). This is a
  second, separate bug - browser-side, not backend.

### Diagnosis of the still-open browser-side silence

Tracing the browser-side code in the upstream checkout's `demo/` (not
vendored into this repo, except `demo/Dockerfile`):

- `demo/s2s-realtime-client.js` subscribes to the pinned
  `@openai/agents-realtime` SDK's **session-level** `"audio"` event
  (`this._session.on("audio", ...)`) - the wire-event → `"audio"`-callback
  translation happens inside the vendored, minified SDK bundle
  (`demo/vendor/openai-realtime-agents.umd.js`), not in readable source.
- `_onAudio` is a silent no-op unless `transport === "websocket"` **and**
  `this._playbackNode` exists. Since mic capture works (same
  `_setupAudio()` gate creates both worklets together), that rules out the
  transport/setup-never-ran branches.
- **Confirmed via temporary instrumentation** (a `console.log` added at
  the top of `_onAudio`, deployed as `local-registry:5000/speech-demo:debug2`
  - see below): the log **never appears**, even on a clean turn with no
  errors and confirmed text output. So `_onAudio` itself is never being
  invoked by the SDK for `response.output_audio.delta` events, even though
  those events are proven to arrive over the wire with real payloads (a
  raw scripted `websockets` client sees them fine - this is purely about
  what the SDK's internal parser does with them).
- Two confounding side-issues surfaced during testing, now understood and
  **not** the main bug:
  - The gateway's realtime server supports exactly **one session at a
    time** (`pool size 1`, a single long-lived pipeline reused across
    reconnects, not per-connection). My own scripted diagnostic
    connections were colliding with the user's live browser session
    (`1008 policy violation: All session slots are in use`, and at least
    one observed mid-session disconnect) - don't run test scripts while a
    real browser session might be active.
  - A Firefox console capture showed a *stale cached* build (still
    referencing the old `audio-24k-v1` asset version, not the current
    `debug2`) failing to load the vendor SDK bundle - that's Firefox's own
    cache being sticky, unrelated to server behavior (the file serves
    fine directly: `curl` gets `HTTP 200`, correct `text/javascript`
    type, 4.8MB). Needs a hard-refresh in Firefox specifically if picked
    up again; not investigated further since Chrome (current code) shows
    a cleaner, different symptom.

### Debug instrumentation used (now rolled back)

`k8s/demo/deployment.yaml` briefly pointed at
`local-registry:5000/speech-demo:debug2` (two temporary `console.log`
lines - module-load confirmation + `_onAudio` entry logging - patched
into a local copy of `demo/s2s-realtime-client.js` in the upstream
checkout, never committed anywhere). **Rolled back to the clean `v1` tag**
now that the investigation is resolved. If reproducing this again, the
patch pattern (and a leftover `s2s-realtime-client.js.orig` backup) is
still in `/home/aminin/workspace/huggingface/speech-to-speech/demo/` on
the machine this was debugged from - or just redo it fresh from this
section's description.

### Next debugging step if this recurs

Since `_onAudio` itself never fires, the next-most-direct check is one
level up: `s2s-realtime-client.js` also has a raw catch-all
`this._transport.on("*", ...)` handler (around line 202) that already
handles some raw wire events (transcripts/status). Add logging there to
print **every** event type the transport actually delivers to the browser,
which will show definitively whether `response.output_audio.delta` reaches
the transport layer at all (as opposed to being recognized-but-not-routed
by the higher-level session object) - that's the one thing not yet
directly observed in-browser. Depending on what that shows:
- If `response.output_audio.delta` never appears at the transport's
  catch-all either → something is dropping it between the WebSocket and
  the transport's own event dispatch (a real SDK bug or version mismatch
  worth reporting/patching).
- If it does appear there but `_onAudio` still never fires → the
  session-level object (built on top of the transport) isn't wiring
  `"audio"` correctly for this transport/session shape, which would want
  a closer look at whatever session-config negotiation
  (`session.update`) happens right after `session.created`.

## Phase F - Probes/resources/observability

Already-applied probes and resource requests/limits can be tuned in place
(`kubectl edit deployment ...` or edit the YAML and re-`apply`) once real
Phase D/E numbers are in. Request-ID propagation and structured logging are
already built into `stt/app/main.py` and `tts/app/main.py` - see
`docs/observability.md` for how to use them.

## Phase G - Deferred

WebRTC, gRPC internal transport, OpenTelemetry, multi-replica/HA. Not
started - see `docs/architecture.md`. (The browser `demo/` frontend
previously listed here is done - see Phase E.2 above.)

## Phase H - MCP support

**Server PoC done (2026-09-10); wired into the voice pipeline (Phase 4,
demo-side) same day.** Full proposal - tool set, security model,
benchmark plan - at
[`mcp/speech-mcp-mcp-experiment-proposal.md`](../mcp/speech-mcp-mcp-experiment-proposal.md);
day-to-day usage in [`speech-mcp/README.md`](../speech-mcp/README.md).

What's running: a Go MCP server (`speech-mcp`, `k8s/speech-mcp/`) on
`node1`, exposing two tools over MCP Streamable HTTP -
- `local_time` (pure computation, no dependencies)
- `global_internet_search`, backed by a self-hosted SearXNG instance
  (`k8s/searxng/` - open-source metasearch, JSON API enabled, no API
  key/account needed, ClusterIP-only)

Verified directly via `./scripts/smoke-test.sh mcp` (the official Python
MCP client, `pip install "mcp>=2,<3"`): `tools/list` shows both tools,
`local_time` returns correct offsets for different timezones (e.g. UTC
vs `Asia/Tokyo`, a 9-hour difference), and `global_internet_search`
returns real, relevant, structured results from live search engines.

**Gateway/voice integration (Phase 4) - demo-side, not a gateway patch.**
Investigating upstream `speech_to_speech`'s actual source showed that
`speech-gateway`'s LLM handler already fully supports `tools`/
`tool_choice` end-to-end (forwarding whatever `tools` the client supplies
via the Realtime protocol's `session.update`/`response.create`, and
already parsing `ResponseFunctionToolCall` items into a structured
`ToolCall` event) - but tool **execution** is explicitly the client's
job under the OpenAI Realtime protocol, not the gateway's. The demo app
already had a complete, generic client-side tool-execution framework
(`TOOL_DEFS`/`runTool`/`activeToolDefs`, previously powering `web_search`
and `camera_snapshot`), so Phase 4 extends that instead of patching
`speech-gateway` - keeping the gateway an unmodified implementation of
the protocol, per this project's usual convention.

Concretely: `speech-mcp` now runs with
`StreamableHTTPOptions.JSONResponse: true` (plain JSON `tools/call`
responses, not SSE), and this repo vendors patched copies of upstream's
`demo/server.py` (a new `/api/mcp/call` proxy route, mirroring how
`/api/search` already holds the Serper key server-side - see that
file's header comment) and `demo/main.js` (`local_time` and
`global_internet_search` added to `TOOL_DEFS`, dispatched in `runTool`,
always included in `activeToolDefs`) alongside the already-vendored
`demo/Dockerfile`, injected via a second, named Docker build context
(`--build-context patches=...`) since the main build context is still
the upstream checkout. `k8s/demo/deployment.yaml` adds
`MCP_SERVER_URL=http://speech-mcp:8080/mcp`.

**Deliberately deferred, not part of this PoC**:
- `local_cluster_search` - would need Kubernetes RBAC +
  `k8s.io/client-go`; neither of the two PoC tools touches the
  Kubernetes API at all, so none of that plumbing exists yet.
- Metrics, correlation IDs, auth (proposal §24-25, §34 "Future" list).
- A Settings-panel toggle for the two new tools (they're unconditionally
  on, matching the existing toggle-less pattern until one is needed).

Build/deploy:
```bash
./scripts/build-and-push.sh <tag>   # builds+pushes speech-mcp (own Dockerfile)
# searxng is a third-party image - mirror it instead (scripts/mirror-images.sh's
# `searxng` entry, or manually: docker pull/tag/push docker.io/searxng/searxng:<tag>)
./scripts/deploy.sh searxng
./scripts/deploy.sh speech_mcp
./scripts/smoke-test.sh mcp

# speech-demo picks up the new /api/mcp/call route + tools on its next
# rebuild (build-and-push.sh already passes the extra --build-context):
./scripts/build-and-push.sh <tag>
./scripts/deploy.sh demo
```

Manual verification (no mic/browser needed): through Traefik,
```bash
curl -k -X POST https://<node-ip>:30443/api/mcp/call \
  -H 'Content-Type: application/json' \
  -d '{"name":"local_time","arguments":{"timezone":"Asia/Tokyo"}}'
```
should return `{"output": "..."}` with the current time. Full
confirmation that the model actually calls the tools needs a real
voice question in the browser (e.g. "what time is it in Tokyo?").
