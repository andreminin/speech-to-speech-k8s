# speech-to-speech-k8s

**A Kubernetes home-lab project for learning distributed voice processing, GPU workloads, MCP tool calling and the foundations of future voice-enabled Synanton services.**

This repository deploys a distributed speech-to-speech pipeline across a small, heterogeneous Kubernetes cluster.
It is based on Hugging Face's [`speech-to-speech`](https://github.com/huggingface/speech-to-speech).

The project started as an experiment in running speech AI across several GPU nodes. 
It has evolved into a practical learning environment for:

- Kubernetes GPU scheduling and workload placement
- distributed speech-to-speech inference
- STT, LLM and TTS service separation
- GPU and VRAM constraints
- cross-node inference latency
- local model and container registries
- MCP (Model Context Protocol) tool calling
- local AI infrastructure without relying on external AI services for every component
- designing voice-processing components that can eventually be reused by the [Synanton](https://github.com/synanton) platform

> **This is a learning and experimentation project, not a production speech platform.**

------

## Current status

The core end-to-end system is working.

A user can open the browser demo, speak into a microphone, receive a transcription, have the request processed by the LLM and hear the generated response.

The demo can also invoke local MCP tools from a spoken conversation.

### Working today

-  Kubernetes deployment across three GPU workers
-  Distributed STT / LLM / TTS inference
-  Browser-based voice conversation
-  Microphone input
-  Speech-to-text
-  LLM response generation
-  Text-to-speech
-  HTTPS/WSS access through the Kubernetes ingress
-  Local MCP server
-  `local_time` MCP tool
-  Internet search through a local SearXNG instance
-  Voice-triggered MCP tool calls
-  GPU scheduling through the NVIDIA Kubernetes device plugin
-  STT + TTS colocated on a single GPU where Kubernetes GPU allocation requires it
-  Local container registry
-  Local model caching on the Kubernetes nodes


The MCP implementation intentionally keeps the gateway unchanged. 
Tool execution is handled by the demo/client side using the OpenAI Realtime tool-calling model.

------

# Why this project exists

This repository is deliberately more than a voice demo.

The goal is to use a real workload to learn how AI systems behave when deployed on a small Kubernetes cluster with heterogeneous hardware.

The home lab has:

- one small CPU-only control-plane node
- three GPU workers
- different NVIDIA GPUs
- 10 Gbit/s inter-node networking
- local container registry
- local model storage
- Kubernetes GPU scheduling
- Longhorn storage
- Calico networking

This makes it possible to experiment with questions that are difficult to answer on a single development machine:

- How should AI workloads be split between GPU nodes?
- How much VRAM does each model actually consume?
- Can multiple inference components share one GPU?
- When does Kubernetes scheduling become a constraint?
- How much latency is introduced by moving inference between nodes?
- Is HTTP sufficient for distributed speech processing?
- When would streaming gRPC become worthwhile?
- How should GPU workloads be scheduled based on model requirements?
- How should AI tools be exposed to a voice assistant?
- What parts of this experiment could eventually become reusable platform capabilities?

------

# Architecture

The current system is a distributed, turn-oriented speech pipeline:

```text
                         Home Kubernetes Cluster

                              ┌───────────────┐
                              │ speech-demo   │
                              │ Browser UI    │
                              └───────┬───────┘
                                      │
                                HTTPS / WSS
                                      │
                              ┌───────▼───────┐
                              │    Gateway    │
                              │   speech-to-  │
                              │    speech     │
                              └───────┬───────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    │                 │                 │
                    ▼                 ▼                 ▼
              ┌──────────┐     ┌───────────┐      ┌──────────┐
              │   STT    │     │   LLM     │      │   TTS    │
              │ Parakeet │     │ llama.cpp │      │  Qwen3   │
              └──────────┘     └───────────┘      └──────────┘
                    │                 │                 │
                    └─────────────────┼─────────────────┘
                                      │
                                      ▼
                                  Audio reply
```

The current implementation uses HTTP/OpenAI-compatible service boundaries.

A future implementation may investigate:

```text
             streaming audio
                    │
                    ▼
              streaming STT
                    │
             partial transcript
                    │
                    ▼
              streaming LLM
                    │
              text/token stream
                    │
                    ▼
              streaming TTS
                    │
                    ▼
              streaming audio
```

Streaming gRPC is therefore an experiment for the future, not a current requirement.

------

# Home-lab Kubernetes cluster

The system runs on a four-node bare-metal Kubernetes cluster.

## As-built cluster - 2026-09-09

| Node    | Role                   | Kubernetes | CPU  | RAM    | GPU         | GPU VRAM | Internal IP     |
| ------- | ---------------------- | ---------- | ---- | ------ | ----------- | -------- | --------------- |
| `node0` | control-plane / master | v1.37.0    | 4    | 16 GiB | -           | -        | `192.168.10.30` |
| `node1` | worker                 | v1.37.0    | 16   | 64 GiB | GTX 1650    | 4 GiB    | `192.168.10.31` |
| `node2` | worker                 | v1.37.0    | 20   | 64 GiB | RTX 4060 Ti | 16 GiB   | `192.168.10.32` |
| `node3` | worker                 | v1.37.0    | 20   | 64 GiB | RTX 5060 Ti | 16 GiB   | `192.168.10.33` |

The nodes also have a separate `192.168.18.x` network on 1 Gbit/s interface.

The `192.168.10.x` network is the 10 Gbit/s SFP+ network used for the main cluster traffic.

`node0` also hosts the local Docker registry (local-registry:5000).

------

# Kubernetes infrastructure

The cluster currently uses:

### Networking

[Calico](https://www.tigera.io/project-calico/) is the cluster CNI.

The cluster currently includes:

- `calico-node`
- `calico-apiserver`
- `calico-kube-controllers`
- `calico-typha`
- Goldmane / Whisker flow-log and observability components

Application-specific network policies live with the workloads.

------

### GPU support

The NVIDIA GPU Operator/device plugin exposes one GPU resource per GPU worker:

```text
node1: nvidia.com/gpu = 1
node2: nvidia.com/gpu = 1
node3: nvidia.com/gpu = 1
```

An important constraint of this lab is that a physical GPU is currently treated as a single schedulable Kubernetes GPU resource.

The two 16 GiB GPUs are **not combined into a virtual 32 GiB GPU**.

This has direct consequences for workload placement.

For example, two independent Pods each requesting:

```text
nvidia.com/gpu: 1
```

cannot normally be scheduled onto the same physical GPU.

This is why STT and TTS are currently colocated in one Pod on `node3`.

------

### Storage

Longhorn is installed for replicated block storage.

Current StorageClasses include:

```text
local-ssd
longhorn
longhorn-static
```

The speech workloads currently use node-local storage for model caches where low latency is more important than replicated storage.

Longhorn remains available for workloads that require persistent replicated storage.

See:

- `docs/longhorn-setup.md`
- `docs/deployment.md`

for details.

------

### Local container registry

The cluster uses a local Docker Registry running directly on `node0`.

```text
node0
  │
  └── docker-registry
          │
          └── local-registry:5000
```

The registry is intentionally outside Kubernetes.

This mimics on-prem / air-gapped environment where cluster nodes can't pull images from internet (public registries).

Images are mirrored into the local registry before deployment - see images list in [mirror-images.sh] (scripts/mirror-images.sh).

------

# Current workload placement

The current placement is:

```text
node0
└── Kubernetes control plane
    └── local container registry

node1 - GTX 1650 / 4 GiB
└── speech gateway
    └── MCP server
    └── SearXNG

node2 - RTX 4060 Ti / 16 GiB
└── speech-llm
    └── llama.cpp

node3 - RTX 5060 Ti / 16 GiB
└── speech-stt
    └── Parakeet / nano-parakeet
└── speech-tts
    └── Qwen3-TTS
```

The STT and TTS services share the GPU in the same Pod.

This is a deliberate Kubernetes scheduling experiment rather than an architectural claim that STT and TTS should always be colocated.

------

# Voice demo

The primary user interface is a browser-based voice chat.

After deployment, it is available at:

```text
https://<node-ip>:30443/
```
For example https://192.168.10.31:30443/

The browser communicates with the gateway over HTTPS/WSS.

The demo provides:

1. microphone input
2. speech detection
3. speech-to-text
4. LLM reasoning
5. optional MCP tool calls
6. text-to-speech
7. audio playback

A complete voice round trip has been verified:

```text
  Microphone
      ↓
  Browser
      ↓
  speech-gateway
      ↓
     STT
      ↓
     LLM
      ↓
     TTS
      ↓
   Browser
      ↓
   Speaker
```

------

# MCP experiment

One of the most useful additions to the project is a small local MCP server.

The goal is to experiment with what happens when a voice assistant can use real tools instead of only generating text.

The current MCP server exposes two tools:

```text
local_time
global_internet_search
```

The architecture is:

```text
                 Voice
                   │
                   ▼
              Browser demo
                   │
                   ▼
                  LLM
                   │
             tool selection
                   │
          ┌────────┴────────┐
          │                 │
          ▼                 ▼
     local_time       internet_search
          │                 │
          │              SearXNG
          │                 │
          └────────┬────────┘
                   ▼
               tool result
                   │
                   ▼
                  LLM
                   │
                   ▼
                  TTS
                   │
                   ▼
                 Voice
```

The search path uses a self-hosted SearXNG instance.

No external search API key is required for the local search experiment.

The important architectural property is that the speech gateway does not need to become an MCP framework.

Tool execution is handled by the client/demo according to the tool-calling model exposed by the voice protocol.

This keeps the speech gateway focused on speech processing.

See:

- `speech-mcp/README.md`
- `mcp/speech-mcp-mcp-experiment-proposal.md`

------

# Why MCP matters for the future

The MCP experiment is intentionally small, but it points toward a much more interesting future use case.

A future Synanton voice assistant could potentially use tools to interact with the platform:

```text
"How many GPU workers are available?"

"Is node3 healthy?"

"Show me running inference workloads."

"Restart the failed extractor."

"How much GPU capacity is available?"

"Why is this document still processing?"

"Start reprocessing the failed audio."

"Search my knowledge base for..."
```

The voice interface would not need to know how Kubernetes, GPU scheduling, content extraction, search, or platform APIs work.

Instead:

```text
      Voice
        ↓
 Speech processing
        ↓
  LLM / agent
        ↓
  MCP / platform tools
        ↓
  Synanton platform
```

This repository therefore provides a useful experimental front end for future voice interaction with:

- [`synanton/platform`](https://github.com/synanton/platform)
- [`synanton/content_extractor`](https://github.com/synanton/content_extractor)
- [`synanton/gpu-runtime`](https://github.com/synanton/gpu-runtime)

------

# Relationship to Synanton

This repository is intentionally separate from Synanton.

It is a **workload laboratory**, not another Synanton service.

The experiments here are expected to inform three future areas.

## 1. Synanton Content Extractor

The speech pipeline provides a practical environment for experimenting with audio processing:

```text
          Audio
            ↓
           STT
            ↓
 speaker / timing information
            ↓
 structured transcript
            ↓
 annotations / derived knowledge
```

Potential future extraction capabilities include:

- transcription
- speaker turns
- pauses
- overlapping speech
- timestamps
- language detection
- summaries
- semantic segments
- derived metadata

These capabilities can eventually feed the Synanton structured content extraction plane.

------

## 2. Synanton GPU Runtime

This repository is also a real heterogeneous GPU workload for experimenting with GPU execution.

Today:

```text
Gateway
   │
   ├── STT
   ├── LLM
   └── TTS
```

A future GPU runtime could abstract the execution layer:

```text
Voice workload
      │
      ▼
GPU Runtime API
      │
      ▼
Scheduler
   ┌──┼──┐
   ▼  ▼  ▼
 STT LLM TTS
```

The scheduler could eventually consider:

- model requirements
- VRAM requirements
- GPU type
- current GPU utilization
- queue depth
- workload priority
- latency requirements
- execution class
- locality

This repository provides a concrete workload against which such a runtime can be tested.

------

## 3. Synanton Platform voice assistants

The longer-term goal is to make voice another interface to the Synanton platform.

The desired separation is:

```text
                 Voice Assistant
                       │
              ┌────────┴────────┐
              │                 │
           speech             tools
              │                 │
              ▼                 ▼
       Content/Voice       Synanton APIs
        Processing              │
              │                 │
              └────────┬────────┘
                       ▼
                Synanton Platform
```

The voice assistant should not directly become the platform.

It should be another client/interface that uses platform capabilities through well-defined APIs and tools.

------

# Repository structure

The repository is intentionally divided into small components:

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
├── docs/
│   ├── architecture.md
│   ├── deployment.md
│   ├── troubleshooting.md
│   ├── benchmarks.md
│   ├── observability.md
│   └── longhorn-setup.md
└── mcp/
    └── speech-mcp-mcp-experiment-proposal.md
```

The service wrappers are intentionally thin.

They should adapt existing speech/inference components to Kubernetes rather than evolve into a second speech orchestration framework.

------

# Quick start

## Check the cluster

```bash
kubectl get nodes
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
  -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu
```

Check system workloads:

```bash
kubectl get pods -A
```

------

## Verify GPUs

Run the NVIDIA smoke tests:

```bash
kubectl apply -f k8s/smoke/nvidia-smi-node1.yaml
kubectl apply -f k8s/smoke/nvidia-smi-node2.yaml
kubectl apply -f k8s/smoke/nvidia-smi-node3.yaml
```

Then follow:

```text
docs/deployment.md
```

for the complete deployment process.

------

## Deploy

Create the registry credentials if required:

```bash
./scripts/create-registry-secret.sh
```

Deploy the application:

```bash
./scripts/install.sh
```

The installation script applies the Kubernetes manifests and waits for the required rollouts.

------

## Run the MCP smoke test

```bash
./scripts/smoke-test.sh mcp
```

This validates the local MCP tools independently of the browser interaction.

------

## Open the voice demo

Open:

```text
https://<node-ip>:30443/
```

The first visit may require accepting the self-signed TLS certificate.

The browser needs microphone permission.

------

## Clean up

```bash
./scripts/cleanup.sh
```

This removes the application namespace and related cluster-scoped resources.

Node-local model caches are intentionally left in place.

------
## K8S cluster stop and start scripts

To safely quiesce the cluster before powering the nodes off (planned reboot):
```bash
scripts/cluster-stop.sh
```

To bring cluster back into service after the nodes have rebooted:
```bash
scripts/cluster-start.sh
```

------

# Troubleshooting

Start with:

```
docs/troubleshooting.md
```

The recommended debugging order is deliberately infrastructure-first:

```text
1. Kubernetes nodes Ready?
          ↓
2. Network connectivity?
          ↓
3. NVIDIA GPU visible?
          ↓
4. nvidia-smi Pod works?
          ↓
5. Container image available?
          ↓
6. GPU resource schedulable?
          ↓
7. Model starts?
          ↓
8. Service health endpoint works?
          ↓
9. STT / LLM / TTS behavior
          ↓
10. End-to-end voice behavior
```

This ordering matters in a home lab.

A powered-off worker, broken kubelet, missing image, or unavailable GPU can look like an application problem even though the application never actually started.

------

# What has been verified

The following has been demonstrated on the current cluster:

### LLM

`speech-llm` runs successfully on `node2`.

Current observed VRAM usage:

```text
~8.7 GiB / 16 GiB
```

### STT + TTS

STT and TTS run concurrently in one Pod on `node3`.

Observed combined VRAM usage:

```text
~6.8 GiB / 16 GiB
```

This leaves substantial headroom on the 16 GiB GPU.

### End-to-end voice

A real browser session has successfully completed:

```text
  microphone
     ↓
    STT
     ↓
    LLM
     ↓
    TTS
     ↓
   speaker
```

### MCP

The browser demo can invoke the local MCP tools and incorporate their results into the voice conversation.

Verified tools:

```text
local_time
global_internet_search
```

------

# What has not been optimized yet

The project is working, but several important experiments remain.

## Streaming

The current pipeline is primarily turn-oriented:

```text
     audio
       ↓
      STT
       ↓
   transcript
       ↓
      LLM
       ↓
    response
       ↓
      TTS
       ↓
     audio
```

The desired future architecture is:

```text
   audio chunks
       ↓
  streaming STT
       ↓
 partial transcript
       ↓
  streaming LLM
       ↓
  text chunks
       ↓
  streaming TTS
       ↓
  audio chunks
```

------

## GPU placement

SST abd TTS located on one GPU

```text
Experiment A

node2: LLM
node3: STT + TTS
```

------

## Latency

Important measurements include:

- network latency
- STT latency
- LLM time-to-first-token
- TTS time-to-first-audio
- end-to-end time-to-first-audio
- total turn latency
- MCP tool-call overhead

------

# Future experiments

The project is likely to evolve through experiments in this order:

1. Improve observability and measure voice latency.
2. Measure STT / LLM / TTS resource usage.
3. Benchmark the alternative GPU placements.
4. Measure MCP tool-call latency.
5. Add cancellation / barge-in propagation.
6. Investigate true streaming between inference services.
7. Compare HTTP with streaming gRPC.
8. Measure concurrent sessions.
9. Experiment with more explicit GPU workload scheduling.
10. Investigate integration with a generic GPU execution runtime.
11. Use audio processing experiments to inform the Synanton content extraction plane.

------

# Related projects

This project is part of a larger set of experiments:

- [Synanton Platform](https://github.com/synanton/platform) - platform and knowledge infrastructure
- [Synanton Content Extractor](https://github.com/synanton/content_extractor) - structured content extraction, including future audio processing
- [Synanton GPU Runtime](https://github.com/synanton/gpu-runtime) - future GPU execution/runtime experiments
- [Hugging Face speech-to-speech](https://github.com/huggingface/speech-to-speech) - upstream speech-to-speech pipeline used by this project

------

# Documentation

Additional documentation:

- `docs/architecture.md` - current architecture
- `docs/deployment.md` - deployment procedure
- `docs/troubleshooting.md` - troubleshooting
- `docs/benchmarks.md` - benchmark results
- `docs/observability.md` - observability
- `docs/longhorn-setup.md` - Longhorn installation and troubleshooting
- `speech-mcp/README.md` - MCP server
- `mcp/speech-mcp-mcp-experiment-proposal.md` - MCP experiment design

------

# Project status

**Experimental / learning project - working end-to-end demo.**

The most important milestone has been reached:

> **A voice conversation can run through the home Kubernetes cluster and use local tools through MCP.**

------

## License

Apache-2.0