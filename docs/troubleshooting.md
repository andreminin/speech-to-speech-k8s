# Troubleshooting

## node1/node2/node3 `NotReady`

Confirmed live on 2026-09-07: `kubectl describe node <name>` showed
`Ready: Unknown`, reason `NodeStatusUnknown — Kubelet stopped posting node
status`, and all three failed to respond to ICMP ping at all — consistent
with the machines being powered off, hung, or network-disconnected rather
than a kubelet software crash.

This is a physical/infrastructure issue, not something fixable from
`kubectl`. Check:
1. Power state of node1 (`192.168.10.31`)/node2 (`192.168.10.32`)/node3
   (`192.168.10.33`) — power on if off.
2. Console/IPMI if the machine is on but hung.
3. Once powered/responsive: `ping <node-ip>`, then `kubectl get nodes`
   should transition back to `Ready` within a couple of minutes once
   kubelet restarts and re-registers.
4. If a node comes back `Ready` but pods don't schedule, check
   `kubectl describe node <name>` for taints left over from the outage.

Nothing in `docs/deployment.md` will work until this is resolved.

## GPU visibility

`kubectl apply -f k8s/smoke/nvidia-smi-node2.yaml` (and `-node3.yaml`) is
the standing diagnostic — isolates "is the GPU visible to *any* pod on this
node" from "is my application container correctly built." If this fails:
- Confirm the NVIDIA device plugin daemonset pods are `Running` in
  `kube-system`.
- Confirm the `RuntimeClass nvidia` still exists (`kubectl get runtimeclass`).
- Confirm the smoke pod's image tag actually exists in
  `local-registry:5000` (`docker pull local-registry:5000/cuda-cudnn-runtime:...`
  from a machine with registry access).

## Registry pulls failing (`ImagePullBackOff`)

- Confirm the secret exists in the **same namespace** as the pod — secrets
  are namespace-scoped (`kubectl get secret local-registry-cred -n speech`).
  Re-run `./scripts/create-registry-secret.sh` if missing.
- Confirm the image was actually pushed:
  `docker pull local-registry:5000/<image>:<tag>` from any machine with
  registry access.
- If the registry uses a self-signed cert (confirmed present on the master
  node — CN `local-registry`), make sure the certificate is trusted by the
  container runtime on each node (containerd/docker's certs.d config), not
  just by your local `docker` client.

## CUDA/cuDNN base image only available as `-base`, not `-cudnn-runtime`

`torch`/`nano-parakeet`/`faster-qwen3-tts` need cuDNN, which the bare
`nvidia/cuda:*-base-*` tags don't include. If `local-registry:5000` only
has a `-base` variant mirrored, either mirror the `-cudnn-runtime` tag
(`./scripts/mirror-images.sh`) or build one locally from the matching
`-base` tag by installing `libcudnn9` packages, before building
`stt/Dockerfile` / `tts/Dockerfile` / the gateway image.

## `speech-stt`/`speech-tts` pods stuck in `Pending`

Most likely the GPU co-scheduling constraint (see `docs/architecture.md`):
if another pod on the same node already holds the one `nvidia.com/gpu: 1`
device, a second Deployment requesting the same resource on that node stays
`Pending` indefinitely. Check `kubectl describe pod <name> -n speech` for
`Insufficient nvidia.com/gpu` events, and switch to
`k8s/stt/deployment-colocated-with-tts.yaml` if that's what you see.

## `faster-qwen3-tts` streaming API mismatch

`tts/app/model.py`'s `_to_pcm16_bytes` normalizes whatever
`generate_custom_voice_streaming` yields (assumed: numpy float32 samples in
`[-1, 1]`, or already-int16). This was not verified against a running
install of `faster-qwen3-tts` (the cluster wasn't reachable while this code
was written) — if synthesized audio comes out corrupted/silent, check the
actual per-chunk return type from that method against the installed
package version first.
