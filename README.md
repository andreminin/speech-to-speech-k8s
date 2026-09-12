# Speech to Speech on Kubernetes

![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=for-the-badge&logo=Kubernetes&logoColor=white)
[![PyPI](https://img.shields.io/pypi/v/speech-to-speech)](https://pypi.org/project/speech-to-speech/)
[![Python](https://img.shields.io/pypi/pyversions/speech-to-speech)](https://pypi.org/project/speech-to-speech/)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](./LICENSE)

A Kubernetes deployment of [Hugging Face Speech-to-Speech](https://github.com/huggingface/speech-to-speech): a low-latency, fully modular voice-agent pipeline built from interchangeable components:

**VAD → STT → LLM → TTS**

The pipeline exposes the core OpenAI Realtime GA event set over WebSocket and WebRTC. Every component is swappable, so the same architecture can be used with local models, OpenAI-compatible services, or future multimodal / omni-model backends.

This repository adapts that project to a small bare-metal Kubernetes home lab and is primarily a **research and test environment for Synanton's audio MCP / audio content processing work**.

## Approach

The upstream [Hugging Face Speech-to-Speech](https://github.com/huggingface/speech-to-speech) project implements a cascaded, modular voice-agent pipeline **VAD -> STT -> LLM -> TTS**

The upstream project keeps the stages independently replaceable. It supports multiple VAD, STT, LLM and TTS implementations and exposes a realtime interface compatible with the OpenAI Realtime protocol.

This repository adds the Kubernetes layer around that pipeline:

```text
Browser
   │
   │ HTTPS / WSS
   ▼
Speech Gateway
   │
   ├──────────────► STT
   │
   ├──────────────► LLM
   │
   └──────────────► TTS
   │
   └──────────────► MCP tools
```

The current deployment deliberately separates workloads between GPU nodes to study VRAM requirements, scheduling, latency and service boundaries.

## Why Kubernetes

The main purpose is not to build another speech framework. It is to have a realistic workload for experimenting with:

- GPU scheduling and placement
- heterogeneous NVIDIA GPUs
- model VRAM requirements
- cross-node inference latency
- STT / LLM / TTS service boundaries
- local model and container caching
- MCP tool calling from a voice interface
- WebSocket / WebRTC realtime transport
- future multimodal and omni-model serving
- infrastructure that can eventually support Synanton

The local registry is intentional. The lab is designed to continue working without depending on public container registries during every deployment and to reduce waiting time when images are rebuilt frequently.

## Home-lab cluster

The deployment runs on a four-node bare-metal Kubernetes cluster.

### As-built cluster — Sep 2026

| Node | Role | Kubernetes | CPU | RAM | GPU | VRAM | Internal IP |
|---|---|---|---:|---:|---|---:|---|
| `node0` | control-plane / master | v1.37.0 | 4 | 16 GiB | — | — | `192.168.10.30` |
| `node1` | worker | v1.37.0 | 16 | 64 GiB | GTX 1650 | 4 GiB | `192.168.10.31` |
| `node2` | worker | v1.37.0 | 20 | 64 GiB | RTX 4060 Ti | 16 GiB | `192.168.10.32` |
| `node3` | worker | v1.37.0 | 20 | 64 GiB | RTX 5060 Ti | 16 GiB | `192.168.10.33` |

The `192.168.10.x` network is the main 10 Gbit/s SFP+ cluster network. The nodes also have a separate `192.168.18.x` 1 Gbit/s network.

### Local container registry

`node0` hosts a Docker Registry outside Kubernetes:

```text
node0
  │
  └── local-registry:5000
```

Images are mirrored into this registry before deployment.

This has two purposes:

1. support an environment where the cluster cannot rely on public registries / an air-gapped-style setup;
2. avoid repeatedly pulling images over the Internet while rebuilding and testing the project.

See [`scripts/mirror-images.sh`](scripts/mirror-images.sh) and [`scripts/create-registry-secret.sh`](scripts/create-registry-secret.sh).

## Current deployment

The current workload placement is:

```text
node0 — control plane
└── local container registry

node1 — GTX 1650 / 4 GiB
├── speech gateway
├── MCP server
└── SearXNG

node2 — RTX 4060 Ti / 16 GiB
└── speech-llm
    └── llama.cpp

node3 — RTX 5060 Ti / 16 GiB
└── speech-stt-tts
    ├── Parakeet-STT
    └── Qwen3-TTS
```

STT and TTS are currently colocated because Kubernetes sees each physical GPU as one schedulable `nvidia.com/gpu` resource. Two independent Pods that each request one GPU cannot normally share the same physical GPU.

The placement is therefore a lab constraint and an experiment, not a recommendation that STT and TTS should always be colocated.

### Voice demo

After deployment, the browser demo is exposed through Traefik:

```text
https://<node-ip>:30443/
```

For example:

```text
https://192.168.10.31:30443/
```

The browser communicates with the gateway using HTTPS/WSS.

The end-to-end path is:

```text
Microphone
    │
    ▼
 Browser
    │
    ▼
 Gateway
    │
    ├──► STT
    │
    ├──► LLM
    │      │
    │      └──► MCP tools
    │
    └──► TTS
           │
           ▼
        Browser
           │
           ▼
        Speaker
```

## Synanton

The long-term target is [Synanton](https://github.com/synanton).

This repository is intentionally separate from Synanton. It is a **research and test tool** for exploring the voice/audio side of the platform, especially the future audio MCP and audio content-extraction components.

Potential Synanton use cases include:

- transcription of recorded conversations
- speaker turns and timing
- pauses and overlapping speech
- language detection
- structured transcripts
- semantic segmentation
- summaries and derived metadata
- MCP-based interaction with Synanton services
- voice access to search and knowledge-platform functionality

A future Synanton audio content extractor could use this environment to evaluate different combinations of STT, semantic processing and multimodal models before integrating them into the main platform.

## Future research: Omni models

The current deployment follows the modular VAD → STT → LLM → TTS architecture. A major future research direction is to compare this cascaded design with **omni models** that can process and generate multiple modalities in a more unified pipeline.

Candidates include:

- [MiniCPM-o](https://github.com/OpenBMB/MiniCPM-o)
- [Qwen3-Omni](https://github.com/QwenLM/Qwen3-Omni) served through [vLLM-Omni](https://github.com/vllm-project/vllm-omni)

vLLM-Omni is particularly interesting for this lab because it provides streaming, OpenAI-compatible serving and experimental full-duplex realtime audio input/output, while supporting omni models such as Qwen3-Omni and MiniCPM-o 4.5.

The research direction is:

```text
Current

Audio
  │
  ▼
VAD → STT → LLM → TTS
  │
  └── MCP / tools


Future

Audio / Video / Text
        │
        ▼
    Omni model
        │
        ├── text
        ├── audio
        └── tool / MCP interaction
```

The first target is **bidirectional voice conversation with MCP support**.

The second target is **audio transcription / analysis**, which is directly relevant to Synanton's audio content extractor.

The lab's two 16 GiB GPUs are useful for testing small or quantized models and distributed serving experiments, while larger models can be evaluated using multiple GPUs or external compute when required.

## Alternative pipeline: Pipecat

[Pipecat](https://github.com/pipecat-ai/pipecat) is another promising direction for the same research area.

Unlike this repository, Pipecat is not a Kubernetes deployment framework. It provides a mature voice-processing pipeline for building realtime voice and multimodal agents.

It is useful as a comparison point because it provides a more application-oriented pipeline abstraction while this repository focuses on:

- Kubernetes deployment
- GPU workload placement
- service boundaries
- local model infrastructure
- MCP integration
- reproducible home-lab experiments

A future experiment may therefore compare:

```text
Hugging Face Speech-to-Speech
        │
        ├── Kubernetes deployment
        └── modular VAD/STT/LLM/TTS


   Pipecat
        │
        └── mature realtime voice pipeline


Omni model / vLLM-Omni
        │
        └── unified multimodal inference
```

The goal is not to select one framework immediately, but to understand which architecture is most useful for Synanton.

## Deployment

The repository contains deployment scripts under [`scripts/`](scripts/).

### 1. Check the cluster

```bash
kubectl get nodes -o wide
```

Expected:

```text
node0   Ready
node1   Ready
node2   Ready
node3   Ready
```

Check GPU resources:

```bash
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
```

### 2. Create registry credentials

If required:

```bash
./scripts/create-registry-secret.sh
```

### 3. Deploy the application

Use the deployment script from the current checkout. The exact phases are documented in [`docs/deployment.md`](docs/deployment.md).

For a complete deployment, the current application phases are:

```bash
./scripts/deploy.sh scaffolding

./scripts/deploy.sh llm
kubectl -n speech rollout status deployment/speech-llm --timeout=10m

./scripts/deploy.sh stt_tts
kubectl -n speech rollout status deployment/speech-stt-tts --timeout=10m

./scripts/deploy.sh gateway
kubectl -n speech rollout status deployment/speech-gateway --timeout=5m

./scripts/deploy.sh traefik
kubectl -n speech rollout status deployment/traefik --timeout=5m

./scripts/deploy.sh searxng
kubectl -n speech rollout status deployment/searxng --timeout=5m

./scripts/deploy.sh speech_mcp
kubectl -n speech rollout status deployment/speech-mcp --timeout=5m

./scripts/deploy.sh demo
kubectl -n speech rollout status deployment/speech-demo --timeout=5m
```

### 4. Check the complete namespace

```bash
kubectl get pods -n speech -o wide
kubectl get deployments -n speech
kubectl get services -n speech
kubectl get ingress -n speech
```

Expected workloads are:

```text
speech-llm
speech-stt-tts
speech-gateway
speech-mcp
speech-demo
traefik
searxng
```

### 5. Open the demo

```text
https://192.168.10.31:30443/
```

The first visit may require accepting the lab's self-signed TLS certificate and granting microphone access.

### Cluster restart

For planned shutdowns and restarts of the home cluster, use:

```bash
./scripts/cluster-stop.sh
```

and after the machines are back:

```bash
./scripts/cluster-start.sh
```

The start script restores the application workloads after Kubernetes comes back. If a service was intentionally scaled to zero, check its deployment replica count before starting manual recovery.

## Status and logs

Check all workloads:

```bash
kubectl get pods -n speech -o wide
kubectl get deployments -n speech
```

Follow gateway logs:

```bash
kubectl -n speech logs -f deployment/speech-gateway
```

LLM:

```bash
kubectl -n speech logs -f deployment/speech-llm
```

STT/TTS:

```bash
kubectl -n speech logs -f deployment/speech-stt-tts
```

MCP:

```bash
kubectl -n speech logs -f deployment/speech-mcp
```

SearXNG:

```bash
kubectl -n speech logs -f deployment/searxng
```

Check recent Kubernetes events:

```bash
kubectl -n speech get events --sort-by='.lastTimestamp'
```

For infrastructure and GPU troubleshooting, see [`docs/troubleshooting.md`](docs/troubleshooting.md).

## Repository structure

```text
.
├── gateway/                 # speech-to-speech gateway
├── stt/                     # STT service
├── tts/                     # TTS service
├── llm/                     # LLM service configuration
├── speech-mcp/              # local MCP server
├── demo/                    # browser voice demo
├── k8s/                     # Kubernetes manifests
├── scripts/                 # deployment and test helpers
└── docs/
    ├── architecture.md
    ├── deployment.md
    ├── troubleshooting.md
    ├── benchmarks.md
    ├── observability.md
    └── longhorn-setup.md

```

## References

### Base project

- [Hugging Face Speech-to-Speech](https://github.com/huggingface/speech-to-speech)

### Omni / multimodal models

- [MiniCPM-o Demo](https://github.com/OpenBMB/MiniCPM-o-Demo)
- [MiniCPM-o](https://github.com/OpenBMB/MiniCPM-o)
- [MiniCPM](https://github.com/OpenBMB/MiniCPM)
- [MiniCPM-V](https://github.com/OpenBMB/MiniCPM-V)
- [MiniCPM-o 4.5 W8A16](https://huggingface.co/88plug/MiniCPM-o-4.5-W8A16)
- [Qwen3-Omni](https://github.com/QwenLM/Qwen3-Omni)
- [vLLM-Omni](https://github.com/vllm-project/vllm-omni)
- [Qwen3-Omni vLLM-Omni recipe](https://github.com/vllm-project/vllm-omni/blob/main/recipes/Qwen/Qwen3-Omni.md)
- [VoxCPM](https://github.com/OpenBMB/VoxCPM)

- [Pipecat](https://github.com/pipecat-ai/pipecat)

### Related project

- [Synanton](https://github.com/synanton)

## License

This repository contains deployment and integration work around the upstream Hugging Face project. See [`LICENSE`](LICENSE) and the upstream project's license and attribution requirements for the respective components.
