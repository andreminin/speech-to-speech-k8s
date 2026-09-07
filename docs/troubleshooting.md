# Troubleshooting

## node1/node2/node3 `NotReady`

Confirm nodes are live : `kubectl describe node <name>` showed
`Ready: Unknown`, reason `NodeStatusUnknown - Kubelet stopped posting node
status`, and all three failed to respond to ICMP ping at all - consistent
with the machines being powered off, hung, or network-disconnected rather
than a kubelet software crash.

This is a physical/infrastructure issue, not something fixable from
`kubectl`. Check:
1. Power state of node1 (`192.168.10.31`)/node2 (`192.168.10.32`)/node3
   (`192.168.10.33`) - power on if off.
2. Console/IPMI if the machine is on but hung.
3. Once powered/responsive: `ping <node-ip>`, then `kubectl get nodes`
   should transition back to `Ready` within a couple of minutes once
   kubelet restarts and re-registers.
4. If a node comes back `Ready` but pods don't schedule, check
   `kubectl describe node <name>` for taints left over from the outage.

Nothing in `docs/deployment.md` will work until this is resolved.

## GPU visibility

`kubectl get nodes` returns

```bash
NAME    STATUS   ROLES                  AGE    VERSION
node0   Ready    control-plane,master   3d1h   v1.37.0
node1   Ready    <none>                 3d1h   v1.37.0
node2   Ready    <none>                 3d1h   v1.37.0
node3   Ready    <none>                 3d1h   v1.37.0
```

`kubectl apply -f k8s/smoke/nvidia-smi-node2.yaml` (and `-node3.yaml`) is
the standing diagnostic - isolates "is the GPU visible to *any* pod on this
node" from "is my application container correctly built." If this fails:
- Confirm the NVIDIA device plugin daemonset pods are `Running` in
  `kube-system`.
  - Confirm that `RuntimeClass nvidia` still exists: `kubectl get runtimeclass` returned 
    ```bash
       NAME     HANDLER   AGE
       nvidia   nvidia    16h
    ```
- Confirm smoke pod's image tag actually exists in
  `local-registry:5000` (`docker pull local-registry:5000/cuda-cudnn-runtime:...`
  from a machine with registry access).
   `https://local-registry:5000/v2/_catalog` returns
    ```json
     {"repositories":["container-toolkit","cuda","dcgm-exporter","driver","gpu-operator","k8s-device-plugin"]}
    ```

  `kubectl get pod -n speech` command returned 
   ```bash
   NAME               READY   STATUS      RESTARTS   AGE
    nvidia-smi-node1   0/1     Completed   0          5m20s
    nvidia-smi-node2   0/1     Completed   0          20m
    nvidia-smi-node3   0/1     Completed   0          13m
   ```
  `kubectl logs nvidia-smi-node1 -n speech` command should return respond like this
   ```bash
   Mon Sep  7 11:09:58 2026       
    +-----------------------------------------------------------------------------------------+
    | NVIDIA-SMI 595.84                 Driver Version: 595.84         CUDA Version: 13.2     |
    +-----------------------------------------+------------------------+----------------------+
    | GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
    | Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
    |                                         |                        |               MIG M. |
    |=========================================+========================+======================|
    |   0  NVIDIA GeForce GTX 1650        Off |   00000000:01:00.0 Off |                  N/A |
    |  0%   36C    P8            N/A  /   85W |     148MiB /   4096MiB |      0%      Default |
    |                                         |                        |                  N/A |
    +-----------------------------------------+------------------------+----------------------+
    
    +-----------------------------------------------------------------------------------------+
    | Processes:                                                                              |
    |  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
    |        ID   ID                                                               Usage      |
    |=========================================================================================|
    |  No running processes found                                                             |
    +-----------------------------------------------------------------------------------------+
   ```
  
   `kubectl logs nvidia-smi-node2 -n speech` command should return respond like this
   ```bash
     Mon Sep  7 10:53:30 2026       
    +-----------------------------------------------------------------------------------------+
    | NVIDIA-SMI 595.84                 Driver Version: 595.84         CUDA Version: 13.2     |
    +-----------------------------------------+------------------------+----------------------+
    | GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
    | Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
    |                                         |                        |               MIG M. |
    |=========================================+========================+======================|
    |   0  NVIDIA GeForce RTX 4060 Ti     Off |   00000000:01:00.0 Off |                  N/A |
    |  0%   35C    P8              5W /  165W |      18MiB /  16380MiB |      0%      Default |
    |                                         |                        |                  N/A |
    +-----------------------------------------+------------------------+----------------------+
    
    +-----------------------------------------------------------------------------------------+
    | Processes:                                                                              |
    |  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
    |        ID   ID                                                               Usage      |
    |=========================================================================================|
    |  No running processes found                                                             |
    +-----------------------------------------------------------------------------------------+
   ```
  `kubectl logs nvidia-smi-node3 -n speech` command should return respond like this
   ```bash
   Mon Sep  7 11:02:08 2026       
    +-----------------------------------------------------------------------------------------+
    | NVIDIA-SMI 595.84                 Driver Version: 595.84         CUDA Version: 13.2     |
    +-----------------------------------------+------------------------+----------------------+
    | GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
    | Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
    |                                         |                        |               MIG M. |
    |=========================================+========================+======================|
    |   0  NVIDIA GeForce RTX 5060 Ti     Off |   00000000:01:00.0 Off |                  N/A |
    |  0%   39C    P8              8W /  180W |      15MiB /  16311MiB |      0%      Default |
    |                                         |                        |                  N/A |
    +-----------------------------------------+------------------------+----------------------+
    
    +-----------------------------------------------------------------------------------------+
    | Processes:                                                                              |
    |  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
    |        ID   ID                                                               Usage      |
    |=========================================================================================|
    |  No running processes found                                                             |
    +-----------------------------------------------------------------------------------------+

   ```

## Registry pulls failing (`ImagePullBackOff`)

- Confirm that namespace-scoped secret exists in the **same namespace** as the pod - secrets
  `kubectl get secret local-registry-cred -n speech` returns
  ```bash
    NAME                  TYPE                             DATA   AGE
    local-registry-cred   kubernetes.io/dockerconfigjson   1      58m
  ```
  Re-run `./scripts/create-registry-secret.sh` if missing.
- Confirm if image pushed
  `docker pull local-registry:5000/<image>:<tag>` from any machine with
  registry access.
- Confirm if registry uses a self-signed cert (confirmed present on the master
  node - CN `local-registry`), and certificate is trusted by the
  container runtime on each node (containerd/docker's certs.d config), not
  just by local `docker` client.

## CUDA/cuDNN base image only available as `-base`, not `-cudnn-runtime`

`torch`/`nano-parakeet`/`faster-qwen3-tts` need cuDNN, which the bare
`nvidia/cuda:*-base-*` tags don't include. 
Confirm that docker registry `local-registry:5000`has mirrored both `-base` and `-cudnn-runtime` tags

Open in browser `https://local-registry:5000/v2/cuda/tags/list` it should return
```json
 {"name":"cuda","tags":["12.9.1-base-ubuntu24.04","12.9.1-cudnn-runtime-ubuntu24.04"]}
```

Use `./scripts/mirror-images.sh` if images are missing or build one locally from the matching
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
was written) - if synthesized audio comes out corrupted/silent, check the
actual per-chunk return type from that method against the installed
package version first.
