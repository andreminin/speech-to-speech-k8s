# Distributed Speech-to-Speech - Kubernetes Proposal

## 1. Goals

Build a self-hosted Speech-to-Speech system running on the existing Kubernetes GPU cluster:

| Node          | GPU     | Primary responsibility                                 |
| ------------- | ------- | ------------------------------------------------------ |
| node0, master |         | Master node                                            |
| node1         | 4 GB    | Gateway/orchestrator, VAD, optional lightweight models |
| node2         | 16 GB   | STT + potentially TTS                                  |
| node3         | 16 GB   | LLM + potentially TTS                                  |
| network       | 10 Gbit | Inter-service streaming                                |

Primary goals:

- run the Hugging Face `speech-to-speech` pipeline in Kubernetes
- avoid requiring a single 24 GB GPU
- distribute GPU workloads across node2/node3
- preserve realtime streaming
- use the 10-Gbit network for inter-node communication
- isolate STT/LLM/TTS failures
- allow individual components to be upgraded independently
- eventually support multiple GPU replicas
- measure whether the two 16 GB GPUs are sufficient before buying additional hardware

The upstream server already exposes an OpenAI Realtime-compatible `/v1/realtime` endpoint and supports multiple pipeline units. 

------

# 2. Proposed architecture

```
                         ┌───────────────────────┐
                         │       Client          │
                         │ Browser / WebRTC      │
                         │ WebSocket             │
                         └───────────┬───────────┘
                                     │
                                     │ PCM16 audio
                                     ▼
                         ┌───────────────────────┐
                         │        node1          │
                         │       4 GB GPU        │
                         │                       │
                         │  S2S Gateway          │
                         │  Realtime API         │
                         │  Session management   │
                         │  VAD                  │
                         └───────────┬───────────┘
                                     │
                              10 Gbit network
                                     │
                         ┌───────────┴───────────┐
                         │                       │
                         ▼                       ▼
                ┌─────────────────┐     ┌─────────────────┐
                │      node2      │     │      node3      │
                │      16 GB      │     │      16 GB      │
                │                 │     │                 │
                │  STT Service    │     │  LLM Service    │
                │                 │     │                 │
                │  Parakeet       │     │  Qwen / other   │
                │                 │     │  quantized LLM  │
                │                 │     │                 │
                │  TTS Service*   │     │  TTS Service*   │
                └────────┬────────┘     └────────┬────────┘
                         │                       │
                         └───────────┬───────────┘
                                     │
                                     ▼
                                  node1
                                     │
                                     ▼
                                  Client

* TTS placement determined by VRAM benchmark.
```

The important architectural principle is:

> **The GPUs are distributed by pipeline stage, not combined into one logical GPU.**

------

# 3. Runtime flow

A conversation should work approximately like this:

```
Client
  │
  │ audio chunks
  ▼
S2S Gateway
  │
  ├── VAD
  │
  └── STT request
          │
          ▼
       node2
       STT
          │
          │ transcript
          ▼
       node3
       LLM
          │
          │ streamed tokens
          ▼
       TTS
          │
          │ streamed PCM
          ▼
       S2S Gateway
          │
          │ audio chunks
          ▼
       Client
```

This is still a **sequential inference pipeline**, but the components are physically distributed.

The current upstream implementation already internally chains handlers through queues:

```
VAD
 ↓
STT
 ↓
LM
 ↓
TTS
```

and maintains isolated state per pipeline unit. 

Our implementation essentially changes:

```
local handler
     ↓
remote inference service
```

for selected components.

------

# 4. Why sequential calls are acceptable

The network traffic between stages is relatively small.

### STT

```
audio
   ↓
STT
   ↓
text
```

### LLM

```
text
   ↓
LLM
   ↓
tokens
```

### TTS

```
text/tokens
   ↓
TTS
   ↓
audio
```

The 10-Gbit network is therefore more than adequate from a bandwidth perspective.

The important metric is **latency**, particularly:

```
audio → first transcript
transcript → first LLM token
first LLM token → first audio
```

rather than raw network throughput.

------

# 5. Streaming rather than batch RPC

This is important.

Do **not** initially design the distributed system as:

```
send complete audio
        ↓
wait for STT
        ↓
send complete text
        ↓
wait for LLM
        ↓
send complete text
        ↓
wait for TTS
```

That would produce noticeable latency.

Instead:

```
audio chunks
   │
   ├──────► STT
   │          │
   │          ├── partial transcript
   │          │
   │          └── final transcript
   │
   └─────────────────────►
                          LLM
                           │
                           ├── token
                           ├── token
                           ├── token
                           ▼
                          TTS
                           │
                           ├── audio chunk
                           ├── audio chunk
                           └── audio chunk
```

This should eventually be implemented using **bidirectional gRPC streaming**.

------

# 6. Service boundaries

I recommend four logical services.

## `speech-gateway`

Runs primarily on node1.

Responsibilities:

- WebSocket/WebRTC
- OpenAI Realtime protocol
- session state
- authentication
- VAD
- turn detection
- orchestration
- streaming responses back to client
- cancellation
- metrics/tracing

The upstream S2S demo already uses WebSocket/WebRTC and the `/v1/realtime` API, so we should preserve that external contract. 

------

## `speech-stt`

Runs on node2.

```
Input:
  PCM16 audio

Output:
  partial/final transcript
```

Initial model:

```
Parakeet TDT
```

Alternative later:

```
Qwen3-ASR
```

The upstream project already supports an OpenAI-compatible STT endpoint and documents running Qwen3-ASR behind vLLM. 

------

## `speech-llm`

Runs on node3.

```
Input:
  conversation/messages

Output:
  streamed tokens
```

The exact model should be determined by the 16 GB VRAM budget.

Start with a quantized model rather than assuming that the 4B model will comfortably coexist with other GPU workloads.

------

## `speech-tts`

Initially test on node2.

```
Input:
  text/token stream

Output:
  PCM16 audio
```

If node2 cannot comfortably hold both STT and TTS:

```
node2 → STT
node3 → LLM + TTS
```

or:

```
node2 → STT
node3 → LLM
node1 → lightweight TTS
```

depending on the benchmark.

The current upstream project supports an OpenAI-compatible remote TTS endpoint, including Qwen3-TTS via vLLM-Omni. 

------

# 7. Kubernetes topology

Label the nodes:

```
kubectl label node node1 gpu-class=small
kubectl label node node2 gpu-class=16gb
kubectl label node node3 gpu-class=16gb
```

Then:

```
node1
gpu-class=small

node2
gpu-class=16gb

node3
gpu-class=16gb
```

This allows explicit placement.

Example STT:

```
spec:
  nodeSelector:
    gpu-class: "16gb"

  containers:
    - name: stt
      resources:
        limits:
          nvidia.com/gpu: 1
```

LLM:

```
spec:
  nodeSelector:
    kubernetes.io/hostname: node3

  containers:
    - name: llm
      resources:
        limits:
          nvidia.com/gpu: 1
```

------

# 8. Namespace

```
apiVersion: v1
kind: Namespace
metadata:
  name: speech
```

Everything initially lives here:

```
speech
├── speech-gateway
├── speech-stt
├── speech-llm
├── speech-tts
├── ConfigMaps
├── Secrets
├── Services
└── model caches
```

------

# 9. GPU isolation

Every inference container gets:

```
resources:
  requests:
    nvidia.com/gpu: 1
  limits:
    nvidia.com/gpu: 1
```

This is important.

Do **not** give a pod:

```
nvidia.com/gpu: 2
```

and expect Kubernetes to combine:

```
node2 GPU
+
node3 GPU
```

That is not how Kubernetes GPU resources work.

------

# 10. Model storage

Use local SSD-backed caches.

For node2:

```
/mnt/models
├── parakeet
└── qwen3-tts
```

For node3:

```
/mnt/models
└── llm
```

I would avoid network storage for the hot model files initially.

The 10-Gbit network is excellent for **inference traffic**, but there's no reason to repeatedly pull multi-GB model weights across the network.

------

# 11. Communication protocol

I recommend:

### External

```
Client
  │
  ▼
WebSocket / WebRTC
```

Maintain compatibility with:

```
/v1/realtime
```

because that is already the upstream interface. 

### Internal

```
Gateway
   │
   ▼
gRPC streaming
   │
   ├── STT
   ├── LLM
   └── TTS
```

Why gRPC?

- bidirectional streaming
- binary audio
- low overhead
- explicit protobuf contracts
- cancellation
- deadlines
- metadata
- OpenTelemetry integration
- easy Java/Go/Python interoperability

This also fits naturally with the existing architecture you're using elsewhere.

------

# 12. Proposed protobuf API

For example:

```
service SpeechToText {
  rpc Transcribe(stream AudioChunk)
      returns (stream TranscriptEvent);
}

service LanguageModel {
  rpc Generate(LLMRequest)
      returns (stream TokenEvent);
}

service TextToSpeech {
  rpc Synthesize(stream TextChunk)
      returns (stream AudioChunk);
}
```

Audio:

```
message AudioChunk {
  string session_id = 1;
  bytes pcm16 = 2;
  int64 sequence = 3;
  bool end_of_turn = 4;
}
```

Transcript:

```
message TranscriptEvent {
  string session_id = 1;
  string text = 2;
  bool final = 3;
}
```

Token:

```
message TokenEvent {
  string session_id = 1;
  string text = 2;
  bool final = 3;
}
```

Audio:

```
message AudioChunk {
  string session_id = 1;
  bytes pcm16 = 2;
  int64 sequence = 3;
  bool final = 4;
}
```

------

# 13. Session identity

Every request should carry:

```
session_id
conversation_id
request_id
trace_id
sequence
```

Example:

```
session = abc123
turn = 42
request = 42-stt
trace = 7f93...
```

This becomes important when cancellation occurs.

Example:

```
User starts speaking
       ↓
STT
       ↓
LLM starts
       ↓
User interrupts
       ↓
cancel LLM
       ↓
cancel TTS
       ↓
new STT turn
```

The gateway must propagate cancellation downstream.

------

# 14. Distributed tracing

Use OpenTelemetry.

One request:

```
trace
 │
 ├── gateway
 │
 ├── VAD
 │
 ├── STT
 │
 ├── LLM
 │
 └── TTS
```

Record:

```
stt_queue_ms
stt_inference_ms

llm_queue_ms
llm_ttft_ms
llm_generation_ms

tts_queue_ms
tts_ttfa_ms
tts_generation_ms

network_ms

e2e_ttfa_ms
```

The most important KPI should be:

```
TTFA = Time To First Audio
```

------

# 15. Failure model

Each service must fail independently.

### STT unavailable

```
gateway
   ↓
STT unavailable
   ↓
return controlled error
```

### LLM unavailable

Potentially:

```
cached/fallback response
```

### TTS unavailable

Return text but no synthesized audio.

### node2 failure

STT/TTS disappear.

Kubernetes should restart them when possible, but with only one 16-GB node for each workload there is no immediate GPU failover.

### node3 failure

LLM disappears.

The system should expose:

```
DEGRADED
```

rather than crashing the gateway.

------

# 16. Important: don't start with HA

With only:

```
node2 = 16 GB
node3 = 16 GB
```

you don't actually have GPU high availability.

For example:

```
node2 STT
node3 LLM
```

If node3 dies, there isn't another 16-GB GPU to run the LLM.

So Phase 1 should optimize for:

> **distributed resource utilization and experimentation**

rather than:

> **production HA**

------

# 17. Implementation plan

## Phase 0 - hardware baseline

### Tasks

Validate:

```
nvidia-smi
```

on:

```
node1
node2
node3
```

Verify:

```
node1 → 4 GB
node2 → 16 GB
node3 → 16 GB
```

Test:

```
node2 ↔ node3
```

using 10-Gbit iperf3.

Acceptance:

```
~10 Gbit/s network
GPU visible on all nodes
```

------

# Phase 1 - Kubernetes GPU foundation

Install/verify:

```
NVIDIA driver
NVIDIA Container Toolkit
Kubernetes NVIDIA device plugin
```

Then:

```
kubectl describe node node2
kubectl describe node node3
```

Verify:

```
nvidia.com/gpu: 1
```

Deploy CUDA test pods.

Acceptance:

```
CUDA pod on node2 → GPU works
CUDA pod on node3 → GPU works
CUDA pod on node1 → GPU works
```

------

# Phase 2 - build S2S base image

Create:

```
speech-to-speech/
├── Dockerfile
├── pyproject.toml
├── configs/
└── k8s/
```

Base:

```
CUDA 13.x
Ubuntu 24.04
Python
PyTorch
speech-to-speech
```

Do not blindly use the upstream image because your CUDA 13.2 environment requires us to validate the CUDA/PyTorch/model combination.

------

# Phase 3 - standalone STT service

Deploy:

```
speech-stt
```

on node2.

Initially expose:

```
/v1/audio/transcriptions
```

or the internal gRPC interface.

Benchmark:

```
VRAM
RTF
latency
CPU
GPU utilization
```

Acceptance:

```
16 GB GPU
STT works
no OOM
stable under 10+ minutes of continuous testing
```

------

# Phase 4 - standalone TTS service

Deploy Qwen3-TTS.

The upstream project already documents the remote OpenAI-compatible TTS pattern, including vLLM-Omni/Qwen3-TTS. 

Test:

```
text
 ↓
TTS
 ↓
PCM16
```

Measure:

```
TTFA
audio generation rate
VRAM
```

Acceptance:

```
TTS fits into available GPU memory
streaming works
```

------

# Phase 5 - standalone LLM

Deploy the chosen quantized LLM on node3.

Use an OpenAI-compatible endpoint where possible.

The upstream ecosystem already supports OpenAI-compatible model servers, and Hugging Face's current Transformers serving interface provides `/v1/responses` and other OpenAI-compatible endpoints. 

Test:

```
prompt
 ↓
LLM
 ↓
streamed tokens
```

Measure:

```
VRAM
TTFT
tokens/sec
```

Acceptance:

```
< 16 GB VRAM
streaming tokens
stable
```

------

# Phase 6 - distributed gateway

Implement:

```
speech-gateway
```

with:

```
/v1/realtime
```

and internal:

```
gRPC
```

flow:

```
Client
 ↓
Gateway
 ↓
STT
 ↓
LLM
 ↓
TTS
 ↓
Gateway
 ↓
Client
```

Acceptance:

**User can speak and receive synthesized speech without manually interacting with individual services.**

------

# Phase 7 - streaming optimization

First implementation:

```
turn-based
```

Then optimize to:

```
audio streaming
      ↓
progressive STT
      ↓
LLM streaming
      ↓
TTS streaming
```

The upstream STT implementation already distinguishes progressive transcription from the final transcription request, so this maps reasonably well to the distributed design. 

------

# Phase 8 - Kubernetes productionization

Add:

```
PodDisruptionBudget
readinessProbe
livenessProbe
startupProbe
resource limits
NetworkPolicy
Secrets
ConfigMaps
```

Add topology constraints:

```
gateway → node1
STT     → node2
LLM     → node3
```

TTS gets assigned based on benchmark results.

------

# Phase 9 - observability

Deploy:

```
OpenTelemetry
Prometheus
Grafana
```

Dashboards:

### GPU

```
GPU utilization
VRAM
temperature
power
```

### S2S

```
sessions
active sessions
STT latency
LLM TTFT
TTS TTFA
E2E TTFA
```

### Network

```
STT network latency
LLM network latency
TTS network latency
bytes/sec
```

------

# 18. Benchmark matrix

Before committing to the final placement, run this matrix:

| Test          | node2 | node3 | Measure        |
| ------------- | ----- | ----- | -------------- |
| STT           | ✓     |       | VRAM / latency |
| TTS           | ✓     |       | VRAM / latency |
| LLM           |       | ✓     | VRAM / TTFT    |
| STT + TTS     | ✓     |       | combined VRAM  |
| LLM + TTS     |       | ✓     | combined VRAM  |
| full pipeline | ✓     | ✓     | E2E TTFA       |

The **STT+TTS** and **LLM+TTS** tests are particularly important.

They determine whether we end up with:

```
Option A

node2: STT + TTS
node3: LLM
```

or:

```
Option B

node2: STT
node3: LLM + TTS
```

------

# 19. Target architecture after benchmarking

My initial hypothesis is:

```
                 ┌─────────────────────┐
                 │       node1         │
                 │       4 GB          │
                 │                     │
Client ─────────►│ S2S Gateway         │
                 │ VAD                 │
                 │ session management  │
                 └──────────┬──────────┘
                            │
                       10 Gbit gRPC
                            │
                 ┌──────────┴──────────┐
                 │                     │
                 ▼                     ▼
          ┌──────────────┐      ┌──────────────┐
          │    node2     │      │    node3     │
          │    16 GB     │      │    16 GB     │
          │              │      │              │
          │ STT          │      │ LLM          │
          │ Parakeet     │      │ quantized    │
          │              │      │              │
          │ TTS*         │      │ TTS*         │
          └──────────────┘      └──────────────┘
```

`*` TTS placement is decided after the VRAM benchmark.

------

# 20. Deliverables

I would turn this into the following implementation artifacts:

```
speech-to-speech-k8s/
│
├── README.md
│
├── docs/
│   ├── architecture.md
│   ├── deployment.md
│   ├── performance.md
│   └── troubleshooting.md
│
├── proto/
│   └── speech.proto
│
├── gateway/
│   ├── Dockerfile
│   └── ...
│
├── stt/
│   ├── Dockerfile
│   └── ...
│
├── llm/
│   ├── Dockerfile
│   └── ...
│
├── tts/
│   ├── Dockerfile
│   └── ...
│
└── k8s/
    ├── namespace.yaml
    ├── gateway.yaml
    ├── stt.yaml
    ├── llm.yaml
    ├── tts.yaml
    ├── services.yaml
    ├── configmaps.yaml
    └── network-policy.yaml
```

------

# 21. Recommended implementation order

I would **not start by modifying the entire Hugging Face S2S codebase**.

Do it incrementally:

```
1. Kubernetes GPU validation
        ↓
2. STT container
        ↓
3. TTS container
        ↓
4. LLM container
        ↓
5. Benchmark individual VRAM
        ↓
6. Define final node placement
        ↓
7. Gateway
        ↓
8. gRPC STT
        ↓
9. gRPC LLM
        ↓
10. gRPC TTS
        ↓
11. End-to-end sequential pipeline
        ↓
12. Streaming
        ↓
13. OpenTelemetry
        ↓
14. Load/concurrency testing
```

This is important because **the first unknown is not Kubernetes-it is the actual VRAM footprint of the chosen STT/LLM/TTS combination**.

The upstream project is already evolving toward explicit local/remote backend boundaries and endpoint-shared inference coordination, so keeping our implementation behind clean STT/LLM/TTS service interfaces should minimize divergence from upstream. 

## Recommended first milestone

I would define **S2S-001: Distributed GPU Inference POC** as:

> Run Parakeet STT on node2 and a quantized LLM on node3, connected by a streaming gRPC gateway, with node1 hosting the S2S Realtime gateway. Add Qwen3-TTS after determining whether it fits alongside STT on node2 or LLM on node3.

Acceptance criteria:

```
✓ 3-node Kubernetes deployment
✓ node1/node2/node3 GPU discovery
✓ 10-Gbit connectivity verified
✓ STT running on node2
✓ LLM running on node3
✓ gRPC streaming between nodes
✓ client → audio → STT → LLM → text working
✓ GPU VRAM telemetry
✓ OpenTelemetry trace across node1 → node2 → node3
✓ no GPU exceeds 16 GB
```

Then TTS becomes the next milestone rather than risking the whole installation around the assumption that a particular combination will fit in 16 GB.