# Smoke tests

One-off diagnostic pods, not part of the running deployment. Use these
whenever debugging GPU visibility or scheduling, not just once in Phase A.

- `nvidia-smi-node2.yaml` / `nvidia-smi-node3.yaml` — confirm the GPU is
  visible to *any* pod on that node, isolating driver/device-plugin/
  runtimeClass issues from application-container issues.
- `gpu-coschedule-test-node2.yaml` — confirms whether two separate pods,
  each requesting `nvidia.com/gpu: 1`, can both schedule onto node2's one
  physical GPU. Expected: the second stays `Pending`. This result decides
  whether Option A (node2 = STT+TTS) uses
  `k8s/stt/deployment-colocated-with-tts.yaml` instead of two independent
  Deployments — see `docs/architecture.md`.

Apply, check `kubectl get pods -n speech`, then delete when done — these
aren't meant to stay running.
