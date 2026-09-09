# speech-to-speech-k8s

Distributed deployment of Hugging Face's [`speech-to-speech`](https://github.com/huggingface/speech-to-speech) pipeline across a small home-lab Kubernetes cluster with local Docker registry imitating no-air on-prem cluster setup.

The project is intentionally a **sandbox / playground for distributed AI inference experiments**. It is not intended to be a production-ready speech platform. The goal is to use the hardware that is already available, learn where the practical boundaries are, and experiment with splitting an AI pipeline across heterogeneous GPU nodes.

## Why this project exists

The starting point is a home Kubernetes lab with three GPU worker nodes:

| Node | GPU | VRAM | Intended role |
|---|---|---:|---|
| `node1` | NVIDIA GeForce GTX 1650 | 4 GB | gateway / VAD / lightweight workloads |
| `node2` | NVIDIA GeForce RTX 4060 Ti | 16 GB | STT and/or TTS |
| `node3` | NVIDIA GeForce RTX 5060 Ti | 16 GB | LLM and/or TTS |

The nodes are connected by a **10 Gbit/s network**.

This hardware is deliberately heterogeneous. There is no single large GPU with enough VRAM to comfortably host every component of the fully-local speech-to-speech stack. Instead of treating that as a limitation, this project uses it as the reason to experiment with **distributed pipeline execution**.

The important distinction is:

> The 16 GB GPUs are not combined into a virtual 32 GB GPU.

Each model runs on a GPU that can hold it, and the pipeline passes intermediate results between Kubernetes services:

```text
Client
  │
  │ WebSocket / OpenAI Realtime
  ▼
speech-gateway                         node1
  │
  ├──────── HTTP ──────► speech-stt    node2
  │                         │
  │                         ▼ transcript
  │
  ├──────── HTTP ──────► speech-llm   node3
  │                         │
  │                         ▼ response text
  │
  └──────── HTTP ──────► speech-tts   node2 or node3
                            │
                            ▼ audio
                         Client
```

The current implementation deliberately uses **OpenAI-compatible HTTP** between services. This keeps the first experiment close to the upstream `speech-to-speech` interfaces and avoids introducing a custom RPC protocol before there is evidence that one is needed.

A future experiment may replace HTTP with streaming gRPC if measurements show that transport overhead or streaming semantics are limiting the system.

## What this project is for

The repository is primarily a laboratory for answering practical questions such as:

- Can a speech-to-speech pipeline be split across several small GPU nodes?
- Which stages fit comfortably into 16 GB of VRAM?
- Can STT and TTS share one 16 GB GPU?
- Is it better to place TTS beside STT or beside the LLM?
- How much latency is introduced by crossing the network between pipeline stages?
- Is 10 Gbit/s sufficient for realtime audio and inference traffic?
- Where is the real bottleneck: VRAM, GPU compute, model loading, CPU, network latency, or inference throughput?
- When does HTTP become a meaningful limitation compared with streaming gRPC?
- How should the same workloads eventually be represented by a more general GPU scheduling/execution layer?

The project therefore favors **small, measurable experiments over premature platform engineering**.

## Architecture

The current architecture is an HTTP-first distributed pipeline:

```text
                         Kubernetes

  ┌──────────────────────────────────────────────────────────┐
  │                                                          │
  │  node1                    node2              node3       │
  │  4 GB GPU                 16 GB GPU           16 GB GPU  │
  │                                                          │
  │  ┌──────────────┐       ┌──────────────┐  ┌───────────┐  │
  │  │    Gateway   │──────►│     STT      │  │    LLM    │  │
  │  │              │       │ Parakeet-TDT │  │ llama.cpp │  │
  │  └──────┬───────┘       └──────┬───────┘  └─────┬─────┘  │
  │         │                      │                 │       │
  │         │                      └──── transcript ─┘       │
  │         │                                                │
  │         └──────────────────────────────────────────────► │
  │                                  TTS                     │
  │                            Qwen3-TTS                     │
  │                                                          │
  └──────────────────────────────────────────────────────────┘
```

The exact TTS placement is intentionally experimental:

```text
Option A:
  node2 = STT + TTS
  node3 = LLM

Option B:
  node2 = STT
  node3 = LLM + TTS
```

Kubernetes GPU scheduling treats a GPU as a device resource (`nvidia.com/gpu: 1`), not as an arbitrary amount of VRAM. Therefore two independent pods requesting one GPU cannot simply share the same physical GPU under the normal device-plugin model. When STT and TTS need to share one GPU, they can be colocated in the same workload.

See [`docs/architecture.md`](docs/architecture.md) for the current as-built design and [`docs/proposal.md`](docs/proposal.md) for the original design rationale.

**Current placement is the mirror image of "Option A", not a resolved choice**: `speech-llm` is pinned to `node2` (since Phase B) and `speech-stt` + `speech-tts` are colocated in one Pod on `node3` (`k8s/stt/deployment-colocated-with-tts.yaml`) - `node3`'s single GPU can't satisfy two separate `nvidia.com/gpu: 1` requests, so STT and TTS share it as two containers in one Pod instead of two Deployments. Confirmed working with both smoke-tested concurrently; combined VRAM 6.8GB of 16GB. The "Option B" shape (LLM+TTS colocated) hasn't been benchmarked. See [Status](docs/deployment.md#status-2026-09-09) in the deployment guide and the results in [`docs/benchmarks.md`](docs/benchmarks.md).

## Current implementation

The repository contains:

- `gateway/` — packages upstream `speech-to-speech` and runs its `serve` command against the distributed inference services.
- `stt/` — thin FastAPI adapter exposing `/v1/audio/transcriptions`, backed by Parakeet-TDT / `nano-parakeet`.
- `tts/` — thin FastAPI adapter exposing `/v1/audio/speech`, backed by Qwen3-TTS / `faster-qwen3-tts`.
- `llm/` — configuration/documentation for an OpenAI-compatible `llama.cpp` server.
- `k8s/` — Kubernetes namespace, storage, ConfigMaps, Deployments, Services, and GPU smoke-test pods.
- `scripts/` — image build/push, deployment, and smoke-test helpers.
- `docs/` — proposal, architecture, deployment, benchmarks, observability, and troubleshooting documentation.

The wrappers are intentionally thin. They adapt the upstream/OpenAI-compatible APIs to independently deployable inference services; they are not intended to become a second S2S orchestration framework.

## Current milestone

The current milestone is **distributed, turn-oriented execution**, not yet a fully optimized cross-node streaming implementation:

```text
audio turn
   ↓
STT
   ↓
transcript
   ↓
LLM
   ↓
response text
   ↓
TTS
   ↓
audio
```

The longer-term target is:

```text
audio chunks
   ↓
streaming STT
   ↓
partial/final transcript
   ↓
streaming LLM
   ↓
token/text chunks
   ↓
streaming TTS
   ↓
audio chunks
```

Streaming gRPC is a possible future optimization, but it will be introduced only if benchmarks show that the current HTTP-based design is the limiting factor.

## Hardware and networking assumptions

The lab is intentionally modest:

- 3 Kubernetes GPU worker nodes
- 1 × 4 GB GPU
- 2 × 16 GB GPUs
- 10 Gbit/s inter-node networking
- NVIDIA Container Toolkit
- Kubernetes NVIDIA GPU device plugin / GPU support
- local model/image storage where practical

The 10 Gbit/s network is important because the experiment is specifically about **cross-node inference**. The expected traffic between stages is relatively small compared with the capacity of a 10 Gbit/s link; therefore the interesting measurement is likely to be latency and streaming behavior rather than raw network bandwidth.

## Quick start

First verify that Kubernetes and the GPUs are healthy:

```bash
kubectl get nodes
kubectl get pods -A
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu
```

Run the GPU smoke tests before troubleshooting application containers:

```bash
kubectl apply -f k8s/smoke/nvidia-smi-node1.yaml
kubectl apply -f k8s/smoke/nvidia-smi-node2.yaml
kubectl apply -f k8s/smoke/nvidia-smi-node3.yaml
```

Then follow [`docs/deployment.md`](docs/deployment.md) in order.

For a client on the LAN, the intended entry point is:

```bash
pip install speech-to-speech
speech-to-speech talk --url ws://<node1-ip>:30765/v1/realtime
```

## Troubleshooting

Start with [`docs/troubleshooting.md`](docs/troubleshooting.md).

The troubleshooting guide deliberately starts with infrastructure rather than application code:

1. Are the Kubernetes nodes `Ready`?
2. Can the nodes be reached over the network?
3. Does Kubernetes expose the NVIDIA GPU?
4. Can a simple `nvidia-smi` pod run on each GPU node?
5. Can the nodes pull the required CUDA/cuDNN images?
6. Can the inference pods acquire their GPU resource?
7. Only then debug STT/TTS/model behavior.

This ordering is important in a home lab: a powered-off or unreachable worker can look like an application failure even though Kubernetes never had a chance to start the workload.

The troubleshooting guide also records known issues around:

- `NotReady` workers and kubelet/node availability
- NVIDIA device-plugin and `RuntimeClass`
- local registry authentication and TLS
- CUDA/cuDNN image availability
- GPU co-scheduling / `Insufficient nvidia.com/gpu`
- Qwen3-TTS streaming API compatibility

## Experiments

The project is expected to evolve through measurements rather than assumptions.

Useful experiments include:

### GPU placement

```text
A: node2 = STT + TTS
   node3 = LLM

B: node2 = STT
   node3 = LLM + TTS
```

### Latency

Measure:

- STT latency
- LLM time-to-first-token
- TTS time-to-first-audio
- end-to-end time-to-first-audio
- network latency between nodes

### Resource usage

Measure:

- VRAM usage
- GPU utilization
- CPU utilization
- model load time
- peak memory
- steady-state memory
- concurrent sessions

### Scaling

Start with one conversation and increase concurrency until latency or VRAM becomes unacceptable.

The goal is not to produce a generic benchmark. The goal is to understand how this particular heterogeneous home-lab cluster behaves.

## Why not use one larger GPU?

Because the purpose of the project is not simply to run the model.

A single larger GPU would answer:

> Can this model run on a sufficiently large machine?

This lab is intended to answer a different question:

> Can a realistic AI pipeline be decomposed into independently deployable inference stages and executed efficiently across a small Kubernetes cluster of heterogeneous GPUs?

That question is more useful for experimenting with distributed inference, GPU scheduling, workload isolation, and eventually a general GPU execution plane.

## Relationship to a future GPU execution platform

This project can also serve as a small experimental workload for a more general GPU execution architecture.

Today:

```text
S2S Gateway
   ├── HTTP → STT
   ├── HTTP → LLM
   └── HTTP → TTS
```

A future execution layer could become:

```text
S2S Gateway
      │
      ▼
GPU Execution API
      │
      ▼
Scheduler
   ┌──┼──┐
   ▼  ▼  ▼
 STT LLM TTS
```

The scheduler could eventually make placement decisions using:

- required model
- GPU VRAM
- GPU type
- current utilization
- queue depth
- execution class
- latency requirements

This repository is deliberately small enough to experiment with those ideas without first building a complete GPU platform.

## Project status

This is an **experimental home-lab project**.

It should be considered:

- useful for learning and prototyping
- useful for testing distributed GPU workloads
- useful for evaluating model/runtime combinations
- useful as a sandbox for Kubernetes inference experiments

It should **not** currently be considered:

- a production S2S platform
- a highly available inference service
- a benchmark representing datacenter hardware
- a general-purpose GPU scheduler

The cluster itself is part of the experiment.

### Verified so far

- `speech-llm` confirmed `Running`/`Ready` and smoke-tested on `node2`
  (`/health` OK, chat completion returned real output). VRAM: 8.7GB/16GB.
- `speech-stt` and `speech-tts` colocated in one Pod on `node3`
  (`k8s/stt/deployment-colocated-with-tts.yaml`), confirmed `2/2 Running`,
  and smoke-tested **concurrently** - both succeeded at the same time on
  the shared GPU. Combined VRAM: 6.8GB/16GB, comfortable headroom.
- Not yet done: the LLM+TTS colocation alternative ("Option B" shape),
  latency/TTFA measurements, and the full gateway end-to-end round trip
  (Phase E).

See [`docs/deployment.md`](docs/deployment.md#status-2026-09-09) for the
detailed status and [`docs/benchmarks.md`](docs/benchmarks.md) for the
recorded VRAM numbers.

## Future actions

The GitHub issue tracker is the working backlog for the next experiments and improvements. The current backlog contains **11 open issues**, covering the path from basic GPU/service validation through observability, benchmarking, security, packaging, and developer tooling. See the [open issues](https://github.com/andreminin/speech-to-speech-k8s/issues).

The intended order is roughly:

### Phase 1 — get every inference component working

- **STSK8-001** — deploy and validate the `speech-llm` component on a GPU node.
- **STSK8-002** — deploy and validate `speech-stt` and `speech-tts` on GPU nodes.
- **STSK8-003** — validate Kubernetes Cluster DNS and service-to-service HTTP communication.

These issues establish the basic distributed execution primitives before attempting the complete S2S path.

### Phase 2 — prove the complete pipeline

- **STSK8-004** — run the full end-to-end smoke test across the gateway, STT, LLM, and TTS components.
- **STSK8-005** — add structured error handling and retry logic for HTTP timeouts.

The goal is to move from independently working services to a reliable distributed request path:

```text
Gateway → STT → LLM → TTS → Gateway
```

### Phase 3 — make the experiment measurable

- **STSK8-006** — add persistent logging and a `kubectl logs` parsing/debugging guide.
- **STSK8-007** — deploy Prometheus + GPU exporter for real-time VRAM and GPU metrics.
- **STSK8-008** — perform initial latency benchmarking and document the results in `docs/benchmarks.md`.

This phase is particularly important because the purpose of the lab is experimentation. We need measurements for VRAM usage, GPU utilization, model loading, network latency, STT latency, LLM TTFT, TTS TTFA, and end-to-end TTFA before making architectural decisions.

### Phase 4 — improve deployment ergonomics and security

- **STSK8-009** — package the Kubernetes manifests as Helm charts.
- **STSK8-010** — harden service-to-service communication with mTLS or API-key authentication.

These are deliberately after the basic pipeline works. The project is a sandbox, so deployment and security complexity should follow demonstrated requirements rather than precede them.

### Phase 5 — improve the developer experience

- **STSK8-011** — add a `--watch` / interactive live-tail script for easier debugging.

This should make iterative experiments on the home cluster considerably faster.

### Beyond the current backlog

After the current issues are complete, the next architectural experiments are likely to be:

1. Compare TTS placement:
   - node2: STT + TTS, node3: LLM
   - node2: STT, node3: LLM + TTS
2. Measure concurrency and determine practical GPU capacity.
3. Investigate true streaming across service boundaries.
4. Compare the current HTTP transport with streaming gRPC.
5. Add cancellation / barge-in propagation.
6. Experiment with more explicit GPU workload scheduling.
7. Evaluate integration with a general GPU execution layer.

The key principle remains:

> **Measure first, optimize second.**

The home lab is intentionally small and heterogeneous. That makes it a useful sandbox for discovering where distributed inference actually needs more sophisticated scheduling, streaming, observability, or resource management.

## Documentation

- [`docs/proposal.md`](docs/proposal.md) — original design proposal and motivation
- [`docs/architecture.md`](docs/architecture.md) — current as-built architecture
- [`docs/deployment.md`](docs/deployment.md) — deployment procedure
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — infrastructure and application troubleshooting
- [`docs/benchmarks.md`](docs/benchmarks.md) — benchmark results
- [`docs/observability.md`](docs/observability.md) — observability notes

## License

Apache-2.0
