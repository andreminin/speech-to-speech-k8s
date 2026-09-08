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


---

## Update to `docs/deployment.md`

Replace the existing "Longhorn setup TODO" section (lines 32–41 in the raw view) with:

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

1. Build and push:
   ```bash
   ./scripts/build-and-push.sh <tag>
   ```
   (update `image:` in `k8s/stt/deployment.yaml` to match `<tag>` if not `latest`)
2. ```bash
   ./scripts/deploy.sh stt
    kubectl -n speech rollout status deployment/speech-stt
    ./scripts/smoke-test.sh stt /path/to/16khz-mono-sample.wav
    ./scripts/record-vram.sh $(kubectl get pods -n speech -l app=speech-stt -o jsonpath='{.items[0].metadata.name}')
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
