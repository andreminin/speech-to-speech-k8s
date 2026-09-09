# MCP Experimentation Proposal for `speech-to-speech-k8s`

**Status:** Proposal  
**Version:** 0.2  
**Purpose:** Experimental MCP integration for a local voice assistant  
**Primary implementation:** Go  
**Target model:** Gemma served by `llama.cpp`  
**Target environment:** Home Kubernetes cluster

---

## 1. Executive Summary

This proposal defines a small, deliberately experimental **Model Context Protocol (MCP)** integration for `speech-to-speech-k8s`.

The goal is not to build a production-grade agent platform. The goal is to make MCP useful enough to experiment with:

- tool discovery,
- structured tool calling,
- internet search,
- Kubernetes/local-cluster search,
- multi-turn tool execution,
- latency measurement,
- and the interaction between a voice pipeline and an MCP-based tool layer.

The proposed implementation is a small **Go MCP server**, named `speech-mcp`, deployed as a CPU-only service on `node1`.

The important architectural distinction is:

> **The LLM decides that a tool is needed. The MCP client/orchestrator executes the tool call. The MCP server owns and implements the tool capability.**

The LLM is therefore not directly connected to MCP.

### Target architecture

```text
                         Kubernetes cluster
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│  node1                                                           │
│  ┌──────────────────────┐       ┌────────────────────────────┐   │
│  │ speech-gateway       │       │ speech-mcp                 │   │
│  │                      │──────▶│ Go MCP server              │   │
│  │ WebSocket / voice    │ MCP   │                            │   │
│  │ orchestration        │       │ - internet search          │   │
│  │ MCP client           │       │ - local cluster search     │   │
│  └──────────┬───────────┘       │ - optional cluster status  │   │
│             │                   └─────────────┬──────────────┘   │
│             │                                 │                  │
│             │ HTTP OpenAI-compatible          │ Kubernetes API   │
│             ▼                                 ▼                  │
│  node3 ┌──────────────────┐           Kubernetes API             │
│        │ speech-llm       │                                      │
│        │ Gemma / llama.cpp│                                      │
│        └──────────────────┘                                      │
│                                                                  │
│  node2 / node3                                                   │
│  ┌──────────────────┐    ┌──────────────────┐                    │
│  │ speech-stt       │    │ speech-tts       │                    │
│  └──────────────────┘    └──────────────────┘                    │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. Motivation

The existing voice pipeline already provides:

```text
User speech
    ↓
speech-gateway
    ↓
speech-stt
    ↓
speech-llm
    ↓
speech-tts
    ↓
User audio
```

The missing capability is controlled access to external or local information.

For example:

> "What pods are currently running?"

or:

> "Search the internet for the latest llama.cpp MCP documentation."

The LLM should not receive unrestricted Kubernetes access or arbitrary network access.

MCP provides a useful experimentation boundary:

```text
LLM
 ↓
structured tool call
 ↓
MCP client
 ↓
MCP server
 ↓
specific capability
```

This makes it possible to experiment with agent-like behavior without turning the LLM itself into an unrestricted infrastructure client.

---

## 3. Goals

### 3.1 Primary goals

1. Introduce MCP into the voice-assistant architecture.
2. Use Go rather than Java for the experimental MCP service.
3. Implement a small number of useful tools.
4. Keep the implementation easy to understand and modify.
5. Use Kubernetes-native deployment.
6. Measure tool-call latency separately from LLM latency.
7. Support iterative experimentation with different tool schemas and prompts.
8. Keep permissions read-only.
9. Avoid coupling the MCP implementation to the speech pipeline internals.
10. Establish a foundation for additional tools later.

### 3.2 Secondary goals

Experiment with:

- MCP tool discovery,
- tool schemas,
- tool descriptions,
- structured tool calls,
- search result formatting,
- tool-result size,
- error handling,
- cancellation,
- timeouts,
- multi-step tool calls,
- and voice-response latency.

---

## 4. Non-Goals

This proposal intentionally does **not** attempt to build:

- a production agent framework,
- a general-purpose Kubernetes management system,
- arbitrary Kubernetes command execution,
- arbitrary shell execution,
- unrestricted URL fetching,
- persistent conversational memory,
- a distributed MCP gateway,
- MCP authentication infrastructure for the home lab,
- HA deployment,
- automatic tool planning outside the LLM,
- or a universal search abstraction.

The first implementation should remain small.

---

## 5. Why Go

Go is the preferred implementation language for this experiment.

### 5.1 Fit with the workload

The service primarily needs:

- HTTP,
- JSON,
- MCP protocol handling,
- HTTP clients,
- Kubernetes API access,
- small amounts of state,
- concurrency,
- timeouts,
- cancellation,
- and metrics.

This is an excellent Go workload.

### 5.2 Kubernetes integration

The Kubernetes ecosystem already has a mature Go client:

```text
k8s.io/client-go
```

This makes local-cluster tools straightforward to implement without invoking `kubectl` as a subprocess.

### 5.3 Small operational footprint

The expected service can be packaged as a small container and run comfortably on `node1`, which is already the CPU-oriented gateway node.

### 5.4 MCP SDK

Use the official MCP Go SDK where practical:

```text
github.com/modelcontextprotocol/go-sdk/mcp
```

The SDK should be treated as the protocol implementation boundary rather than implementing MCP JSON-RPC manually.

---

## 6. MCP Transport

Use **Streamable HTTP** as the primary transport.

```text
speech-gateway
      |
      | HTTP
      | MCP / JSON-RPC
      v
speech-mcp
      |
      +-- /mcp
```

The experimental service should expose:

```text
POST /mcp
GET  /mcp              # only if required by the MCP transport/session model
```

The older HTTP+SSE transport should not be the primary design.

If the selected MCP client implementation requires a compatibility transport during experimentation, HTTP+SSE can be added temporarily without changing the logical tool architecture.

### Why Streamable HTTP

It is the current MCP direction and is a better fit for:

- a Kubernetes ClusterIP service,
- a separately deployed MCP server,
- client/server separation,
- and future authentication.

---

## 7. Component Responsibilities

### 7.1 `speech-llm`

The LLM is responsible for:

- understanding the user's request,
- deciding whether a tool is needed,
- producing a structured tool call,
- interpreting the tool result,
- and generating the final natural-language answer.

It should **not** directly perform HTTP requests to search engines or Kubernetes.

### 7.2 MCP client/orchestrator

The MCP client is responsible for:

- connecting to `speech-mcp`,
- discovering tools,
- exposing tool schemas to the LLM,
- detecting structured tool calls,
- invoking MCP tools,
- returning results to the LLM,
- handling timeouts,
- and continuing the conversation after tool execution.

For the first experiment this can live inside `speech-gateway`.

```text
speech-gateway
 ├── voice/WebSocket handling
 ├── LLM request handling
 └── MCP client/orchestration
```

This avoids introducing another deployment until there is a reason to do so.

### 7.3 `speech-mcp`

The MCP server owns the actual capabilities:

```text
speech-mcp
 ├── global_internet_search
 ├── local_cluster_search
 └── optional cluster status tools
```

It should not contain speech/STT/TTS logic.

---

## 8. Initial Tool Set

Start with two tools.

### 8.1 `global_internet_search`

Purpose:

> Search the public internet for information relevant to the user's request.

Suggested schema:

```json
{
  "name": "global_internet_search",
  "description": "Search the public internet and return concise results relevant to the query.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "The search query"
      },
      "max_results": {
        "type": "integer",
        "minimum": 1,
        "maximum": 10,
        "default": 5
      }
    },
    "required": ["query"]
  }
}
```

Return structured results rather than a large block of scraped text:

```json
{
  "results": [
    {
      "title": "Example result",
      "url": "https://example.com/article",
      "snippet": "Short relevant description...",
      "source": "example.com"
    }
  ]
}
```

The first version should preferably use an existing search API/provider rather than implementing a crawler.

---

### 8.2 `local_cluster_search`

Purpose:

> Search read-only information available from the local Kubernetes cluster.

Example queries:

```text
What pods are running?
Which services expose port 8080?
What is running on node3?
Show me GPU workloads.
```

The tool should translate a constrained natural-language query into supported Kubernetes API operations.

For the first implementation, avoid giving the LLM raw Kubernetes API access.

Example result:

```json
{
  "query": "pods running on node3",
  "resources": [
    {
      "kind": "Pod",
      "namespace": "speech",
      "name": "speech-llm-7f8c9d",
      "node": "node3",
      "phase": "Running"
    }
  ]
}
```

---

## 9. Optional Experimental Tools

Once the two initial tools work, add narrowly scoped read-only tools.

### `get_cluster_status`

Return:

- node readiness,
- Kubernetes version,
- selected workload status.

### `get_gpu_status`

Return only information that is safe and useful to the voice assistant:

```text
node2:
  GPU: NVIDIA 5060
  workload: speech-stt

node3:
  GPU: NVIDIA 5060
  workload: speech-llm
```

This could eventually be backed by Kubernetes resources, NVIDIA device-plugin information, or metrics.

### `get_service_status`

Return health information for:

- `speech-gateway`,
- `speech-stt`,
- `speech-llm`,
- `speech-tts`,
- `speech-mcp`.

These should be added only after the basic search experiment works.

---

## 10. Tool Selection Policy

Do not attempt to build sophisticated planning logic in the first experiment.

Use a simple policy in the system/developer prompt:

```text
Use a tool when the answer requires information that is not reliably
available from your existing knowledge.

Use local_cluster_search for questions about this Kubernetes cluster.

Use global_internet_search for current public information.

Do not invent tool results.

After receiving a tool result, answer the user's question directly.
```

The exact prompt should be treated as a benchmark variable.

The experiment should compare:

1. no tools,
2. tools with short descriptions,
3. tools with detailed descriptions,
4. tools with explicit selection rules.

Do not depend on undocumented model-specific "thinking mode" tags.

---

## 11. LLM Tool-Calling Flow

The intended interaction is:

```text
1. User speaks
       ↓
2. STT
       ↓
3. speech-gateway
       ↓
4. LLM request with tool schemas
       ↓
5. LLM returns:
       tool_call(global_internet_search, {...})
       ↓
6. MCP client
       ↓
7. speech-mcp
       ↓
8. Tool result
       ↓
9. MCP client
       ↓
10. Second LLM request containing tool result
       ↓
11. Final natural-language response
       ↓
12. TTS
       ↓
13. User hears response
```

This means a tool-enabled request normally introduces another LLM generation step.

That latency must be measured explicitly.

---

## 12. `llama.cpp` Considerations

The current `llama.cpp` server supports OpenAI-compatible APIs and tool/function calling when the selected model/chat template supports it.

For this experiment, prefer controlling MCP from `speech-gateway` rather than depending on `llama.cpp`'s experimental server-side MCP integration.

Reason:

```text
speech-gateway
    owns orchestration
        ↓
llama.cpp
    remains the LLM inference service
```

This keeps the voice application in control of:

- tool policy,
- MCP sessions,
- timeouts,
- result truncation,
- logging,
- metrics,
- and future security controls.

The `llama.cpp` MCP integration can still be tested separately as an experiment, but it should not be a dependency of the main architecture.

---

## 13. Web Search Safety

Internet search results must be treated as **untrusted input**.

The MCP server should:

- return search metadata and short snippets,
- limit result size,
- remove HTML where applicable,
- avoid executing returned content,
- avoid arbitrary URL fetching in v1,
- enforce provider/network timeouts,
- and never interpret search-result text as instructions to the MCP server.

A malicious search result should not be able to cause:

```text
shell execution
Kubernetes mutation
credential access
arbitrary network requests
```

Search results are data, not instructions.

---

## 14. Kubernetes Security

The MCP server should use a dedicated ServiceAccount.

Initial permissions should be read-only.

Example conceptual RBAC:

```yaml
rules:
  - apiGroups: [""]
    resources:
      - pods
      - services
      - nodes
      - namespaces
    verbs:
      - get
      - list

  - apiGroups: ["apps"]
    resources:
      - deployments
      - replicasets
      - statefulsets
      - daemonsets
    verbs:
      - get
      - list
```

Do not grant:

```text
create
update
patch
delete
exec
proxy
portforward
```

The MCP server must never expose arbitrary `kubectl` execution.

---

## 15. Network Policy

The intended network relationship is:

```text
speech-gateway ─────▶ speech-mcp
speech-mcp ──────────▶ Kubernetes API
speech-mcp ──────────▶ configured search provider
```

The MCP server should not accept arbitrary inbound traffic.

Conceptually:

```text
Ingress:
  speech-gateway only

Egress:
  Kubernetes API
  configured search provider
  DNS
```

This becomes particularly important if internet search is enabled.

---

## 16. Deployment

Deploy `speech-mcp` to `node1`.

### Why node1

`node1` is already the CPU-oriented infrastructure node and hosts the gateway.

The MCP server does not need a GPU.

Suggested initial resources:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

These values are experimental and should be adjusted from measurements.

### Deployment characteristics

```yaml
replicas: 1
```

HA is unnecessary for the home-lab experiment.

Use an immutable image tag:

```text
speech-mcp:0.1.0
```

rather than:

```text
speech-mcp:latest
```

---

## 17. Kubernetes Service

Expose the service internally:

```text
Service type: ClusterIP
Port: 8080
```

Example:

```text
http://speech-mcp:8080/mcp
```

The service should not be exposed through an external LoadBalancer or NodePort.

---

## 18. Health Endpoints

Use ordinary HTTP health endpoints:

```text
GET /health/live
GET /health/ready
```

Do not use the MCP streaming endpoint for Kubernetes health probes.

### Liveness

Checks that the process is alive.

### Readiness

Checks that required dependencies are available enough for serving requests.

Readiness should not necessarily fail just because an external search provider is temporarily unavailable if local-cluster tools can still operate.

---

## 19. Go Project Structure

Suggested initial repository structure:

```text
speech-mcp/
├── cmd/
│   └── speech-mcp/
│       └── main.go
├── internal/
│   ├── mcpserver/
│   ├── search/
│   ├── kubernetes/
│   ├── config/
│   └── health/
├── k8s/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── serviceaccount.yaml
│   ├── role.yaml
│   ├── rolebinding.yaml
│   └── networkpolicy.yaml
├── Dockerfile
├── go.mod
├── go.sum
└── README.md
```

Keep the internal interfaces small.

---

## 20. Tool Implementation Interface

The exact MCP SDK API should be used according to the version selected during implementation.

Conceptually, tools should map to application interfaces such as:

```go
type InternetSearcher interface {
    Search(ctx context.Context, query string, maxResults int) ([]SearchResult, error)
}

type ClusterSearcher interface {
    Search(ctx context.Context, query string) ([]ClusterResult, error)
}
```

This keeps the MCP layer independent from the underlying search implementation.

It also makes testing easy.

---

## 21. Configuration

Use environment variables for experimental configuration.

Example:

```text
MCP_HTTP_ADDR=:8080

SEARCH_PROVIDER=...
SEARCH_API_URL=...
SEARCH_API_KEY=...

KUBERNETES_NAMESPACE=...

TOOL_MAX_RESULTS=5
TOOL_TIMEOUT=5s
```

Do not put secrets directly into Git.

Kubernetes Secrets should be used for search-provider credentials.

---

## 22. Timeouts

Every external operation must have a context timeout.

Suggested initial values:

```text
MCP request:       10s
Internet search:    5s
Kubernetes query:   2s
```

These are benchmark starting points, not fixed requirements.

A voice interaction should fail quickly enough that the assistant can produce a useful response instead of appearing frozen.

---

## 23. Result Size Control

Large tool results are harmful to both latency and LLM context.

The MCP server should impose limits.

Example:

```text
maximum search results: 5
maximum snippet length: 500 characters
maximum cluster resources: 50
maximum total tool response: configurable
```

The MCP client should also enforce a final maximum result size before passing data to the LLM.

---

## 24. Observability

Add structured logs and Prometheus-compatible metrics.

Important metrics:

```text
mcp_requests_total
mcp_request_duration_seconds

mcp_tool_calls_total
mcp_tool_duration_seconds
mcp_tool_errors_total

internet_search_duration_seconds
cluster_search_duration_seconds
```

At the gateway level:

```text
llm_first_pass_duration
mcp_roundtrip_duration
llm_second_pass_duration
tts_duration
end_to_end_duration
```

The most important metric for the voice experiment is:

```text
time_to_final_audio
```

---

## 25. Correlation IDs

Every voice request should receive a correlation/request ID.

Propagate it through:

```text
speech-gateway
    ↓
LLM
    ↓
MCP client
    ↓
speech-mcp
    ↓
search / Kubernetes
```

Example:

```text
request_id=01J...
tool_call_id=...
tool=global_internet_search
```

This will make latency debugging much easier.

---

## 26. Error Handling

Tool failures should become structured tool results or controlled MCP errors.

Examples:

### Search provider timeout

```json
{
  "error": "search_timeout",
  "message": "Internet search timed out."
}
```

### Kubernetes API failure

```json
{
  "error": "cluster_query_failed",
  "message": "The Kubernetes API could not be queried."
}
```

The LLM should then be able to say:

> "I couldn't check the cluster right now."

rather than hallucinating an answer.

---

## 27. MCP Session Strategy

For the first implementation, keep MCP session state minimal.

The service should be capable of operating without application-level conversational state.

Conversation state remains primarily in `speech-gateway`.

This separation is desirable:

```text
speech-gateway
    conversation state

speech-mcp
    capability state
```

If MCP sessions are required by the selected transport/SDK configuration, keep their state lightweight and avoid storing user conversation history in the MCP server.

---

## 28. Testing Strategy

### Unit tests

Test:

- tool input validation,
- result truncation,
- Kubernetes query translation,
- search-provider adapter,
- timeout behavior,
- malformed provider responses.

### MCP protocol tests

Verify:

- initialization,
- tool discovery,
- tool schema,
- tool invocation,
- error response,
- cancellation where supported.

### Integration tests

Run:

```text
speech-gateway
speech-mcp
mock search provider
mock or test Kubernetes API
```

without requiring the full GPU pipeline.

---

## 29. First Experimental Scenarios

### Scenario 1 — local cluster

User:

> "What is running on node3?"

Expected:

```text
LLM
 → local_cluster_search
 → speech-mcp
 → Kubernetes API
 → result
 → LLM
 → answer
```

### Scenario 2 — internet search

User:

> "What is the latest MCP transport?"

Expected:

```text
LLM
 → global_internet_search
 → speech-mcp
 → search provider
 → results
 → LLM
 → answer
```

### Scenario 3 — no tool

User:

> "What is Kubernetes?"

Expected:

```text
LLM
 → direct answer
```

No MCP call should occur.

### Scenario 4 — mixed query

User:

> "Is my cluster using the latest llama.cpp MCP transport?"

Potential flow:

```text
local_cluster_search
        +
global_internet_search
        ↓
LLM synthesis
```

This is especially useful for testing multi-tool behavior.

---

## 30. Benchmark Plan

The experiment should measure more than whether tool calling works.

### Baseline

```text
voice → STT → LLM → TTS
```

### MCP

```text
voice
 → STT
 → LLM
 → MCP
 → LLM
 → TTS
```

Measure:

| Metric | Baseline | MCP |
|---|---:|---:|
| STT latency | | |
| first LLM latency | | |
| MCP latency | N/A | |
| second LLM latency | N/A | |
| TTS latency | | |
| end-to-end latency | | |
| time to first audio | | |
| tool success rate | N/A | |
| answer correctness | | |

The most important question is:

> **Does MCP make the assistant useful enough to justify the additional round-trip and second LLM generation?**

---

## 31. Tool-Calling Accuracy Experiment

Create a small fixed evaluation set.

Example:

| User request | Expected tool |
|---|---|
| "What pods are running?" | local_cluster_search |
| "What is on node3?" | local_cluster_search |
| "Search the web for MCP transport changes." | global_internet_search |
| "What is Kubernetes?" | none |
| "What is the latest llama.cpp release?" | global_internet_search |
| "Is speech-llm running?" | local_cluster_search |

Measure:

```text
correct tool selection
incorrect tool selection
unnecessary tool call
missed tool call
failed tool call
```

This will be more useful than subjective testing alone.

---

## 32. Search Result Quality Experiment

For internet search, compare:

### A. Search snippets only

```text
title
url
snippet
```

### B. Search snippets + publication date

```text
title
url
snippet
published
```

### C. Search snippets + limited page extraction

Only add page extraction if snippets are insufficient.

The default should remain small because this is a voice application.

---

## 33. Voice UX Considerations

Tool execution can introduce a noticeable pause.

For example:

```text
User stops speaking
       ↓
STT
       ↓
LLM decides tool
       ↓
MCP search
       ↓
LLM synthesizes
       ↓
TTS
```

The user may perceive this as silence.

For the experiment, measure whether a short acknowledgement improves UX.

For example:

> "Let me check that."

However, do not implement complex streaming-agent behavior initially.

First measure the baseline.

---

## 34. Security Model

The initial security model is appropriate for a trusted home network, but the MCP server should still follow least privilege.

### Required

- dedicated ServiceAccount,
- read-only Kubernetes RBAC,
- NetworkPolicy,
- no shell execution,
- no arbitrary Kubernetes operations,
- no arbitrary URL fetching,
- bounded tool output,
- bounded timeouts,
- secrets via Kubernetes Secret,
- structured audit logging.

### Future

If the service is ever exposed outside the home network:

- authentication,
- authorization,
- TLS,
- tenant/user identity,
- rate limiting,
- tool-level permissions,
- stronger audit logging

become mandatory.

---

## 35. Failure Modes

### MCP server unavailable

The gateway should return a controlled tool failure.

### Search provider unavailable

The assistant should say that internet search is unavailable rather than fabricate current information.

### Kubernetes API unavailable

The assistant should state that cluster status could not be checked.

### LLM produces invalid tool arguments

The MCP client should validate against the discovered schema before invocation where practical.

### Tool returns excessive output

The client/server must truncate it.

### Search result contains malicious instructions

Treat it as untrusted content.

---

## 36. Implementation Phases

### Phase 1 — Minimal MCP server

Implement:

```text
speech-mcp
 └── test_echo
```

Verify:

- MCP initialization,
- tool discovery,
- invocation,
- result handling.

### Phase 2 — Internet search

Implement:

```text
global_internet_search
```

Add:

- provider adapter,
- timeout,
- result limits,
- structured output.

### Phase 3 — Kubernetes search

Implement:

```text
local_cluster_search
```

Add:

- ServiceAccount,
- read-only RBAC,
- Kubernetes client,
- resource filtering.

### Phase 4 — Gateway MCP client

Implement MCP client/orchestration in `speech-gateway`.

Add:

- tool discovery,
- LLM tool definitions,
- structured tool-call detection,
- MCP invocation,
- result injection,
- second LLM request.

### Phase 5 — Voice integration

Run:

```text
STT → LLM → MCP → LLM → TTS
```

with real speech.

### Phase 6 — Benchmark

Measure:

- latency,
- tool-selection accuracy,
- failure rate,
- response quality,
- perceived voice UX.

### Phase 7 — Expand only if useful

Potential additions:

```text
get_cluster_status
get_gpu_status
get_service_status
```

---

## 37. Suggested Repository Layout

The existing `speech-to-speech-k8s` repository can remain focused on the voice application.

A separate repository is recommended for the MCP service:

```text
andreminin/
├── speech-to-speech-k8s
└── speech-mcp
```

This gives the MCP service its own:

- Go module,
- container,
- deployment,
- tests,
- release lifecycle.

It also prevents experimental MCP code from becoming tightly coupled to the voice gateway.

---

## 38. Proposed Initial Kubernetes Resources

```text
Namespace
    speech

ServiceAccount
    speech-mcp

Role
    read-only Kubernetes resources

RoleBinding
    speech-mcp → Role

Deployment
    speech-mcp

Service
    speech-mcp:8080

NetworkPolicy
    gateway → MCP
    MCP → Kubernetes API
    MCP → configured search provider
```

No GPU resources are required.

---

## 39. Configuration Example

Conceptual deployment environment:

```yaml
env:
  - name: MCP_HTTP_ADDR
    value: ":8080"

  - name: SEARCH_PROVIDER
    value: "..."

  - name: SEARCH_API_URL
    value: "..."

  - name: TOOL_MAX_RESULTS
    value: "5"

  - name: TOOL_TIMEOUT
    value: "5s"
```

Credentials:

```yaml
envFrom:
  - secretRef:
      name: speech-mcp-search
```

---

## 40. Open Questions

These should be answered through experimentation rather than over-designed now.

### 40.1 Where should the MCP client live?

Initial answer:

```text
speech-gateway
```

If orchestration becomes complex, extract it into a separate service later.

### 40.2 Which search provider?

Start with one provider and hide it behind:

```go
InternetSearcher
```

The provider should be replaceable.

### 40.3 Should local search be one tool or several?

Start with:

```text
local_cluster_search
```

Split it into specialized tools only if tool-selection accuracy or schema clarity improves.

### 40.4 Should the LLM call MCP directly through `llama.cpp`?

Not initially.

Keep orchestration in the gateway so the experiment remains observable and controllable.

### 40.5 Should tool results contain raw Kubernetes objects?

No.

Return compact, purpose-built results.

---

## 41. Design Principles

### Principle 1 — Keep MCP boring

The MCP server should mostly be an adapter:

```text
MCP → capability
```

It should not become an agent itself.

### Principle 2 — Keep tools narrow

A tool should perform one useful capability.

### Principle 3 — Keep results small

Voice assistants do not benefit from huge tool responses.

### Principle 4 — Keep permissions read-only

The first experiment should observe the cluster, not modify it.

### Principle 5 — Keep orchestration outside the LLM

The LLM proposes a tool call. The application controls execution.

### Principle 6 — Measure before optimizing

Do not assume streaming, acknowledgements, parallel tool calls, or speculative execution improve UX. Benchmark them.

### Principle 7 — Make providers replaceable

Search providers and other external dependencies should be behind small interfaces.

---

## 42. Expected Outcome

At the end of the experiment, the system should support conversations such as:

> User: "What is running on node3?"

```text
LLM
 → local_cluster_search
 → Kubernetes
 → LLM
 → TTS
```

and:

> User: "Search the web for the latest MCP transport documentation."

```text
LLM
 → global_internet_search
 → Internet
 → LLM
 → TTS
```

while ordinary questions continue to use:

```text
LLM
 → TTS
```

without unnecessary MCP calls.

---

## 43. Recommendation

Proceed with a **small Go `speech-mcp` server** and an MCP client inside `speech-gateway`.

Do not start with a Java implementation or a generalized MCP platform.

The recommended experimental architecture is:

```text
                         ┌──────────────────────────┐
                         │        User voice        │
                         └────────────┬─────────────┘
                                      │
                                      ▼
                         ┌──────────────────────────┐
                         │ speech-gateway           │
                         │ node1                    │
                         │                          │
                         │ - WebSocket              │
                         │ - orchestration          │
                         │ - MCP client             │
                         └───────┬───────────┬──────┘
                                 │           │
                          HTTP/OpenAI        │ MCP
                                 │           │
                                 ▼           ▼
                         ┌─────────────┐ ┌───────────────┐
                         │ speech-llm  │ │ speech-mcp    │
                         │ node3       │ │ node1         │
                         │ Gemma       │ │ Go            │
                         │ llama.cpp   │ │               │
                         └─────────────┘ │ - web search  │
                                        │ - K8s search  │
                                        └───────┬───────┘
                                                │
                                      ┌─────────┴─────────┐
                                      ▼                   ▼
                                Internet            Kubernetes API
```

This is small enough to implement quickly, but it creates a realistic environment for learning how MCP behaves in an actual voice-agent pipeline.

---

## 44. Definition of Done

The experiment is successful when all of the following work:

- [ ] `speech-mcp` starts in Kubernetes.
- [ ] MCP initialization succeeds.
- [ ] Tool discovery works.
- [ ] `global_internet_search` works.
- [ ] `local_cluster_search` works.
- [ ] Gateway can invoke MCP tools.
- [ ] LLM can select a tool using structured tool calling.
- [ ] Tool results are returned to the LLM.
- [ ] Final answer is synthesized correctly.
- [ ] Voice response is produced.
- [ ] Kubernetes permissions are read-only.
- [ ] Tool calls have timeouts.
- [ ] Tool output is bounded.
- [ ] MCP latency is measured.
- [ ] End-to-end voice latency is measured.
- [ ] A small tool-selection evaluation set has been tested.

---

## 45. References

The implementation should follow the current MCP specification and SDK documentation selected at implementation time.

Primary references:

- Model Context Protocol specification and transport documentation.
- Official MCP Go SDK.
- `llama.cpp` server documentation for OpenAI-compatible APIs and tool calling.
- Kubernetes `client-go` documentation.

Because MCP and `llama.cpp` tool/MCP support are evolving, implementation details should be pinned to the versions actually used in the experiment rather than relying on undocumented behavior.
