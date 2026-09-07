# Benchmarks

Carried forward from `doc/Speech-to-Speech K8S Proposal.md` - this is the
mechanism that decides final `speech-tts` placement (Option A vs Option B)
and validates the HTTP-first architecture's TTFA under real network
conditions. **Not yet run** - the cluster's worker nodes need to be healthy
first (see `docs/troubleshooting.md`).

## Matrix

Run each row with the same test utterance(s)/prompt(s). Record **VRAM**
(peak, via `./scripts/record-vram.sh <pod>`) and **latency**, especially
**TTFA** (time from user-audio-end to first synthesized-audio byte reaching
the gateway).

| Row | Config | Node(s) | VRAM (MB) | Latency / TTFA (ms) | Notes |
|---|---|---|---|---|---|
| STT alone | speech-stt only | node2 | _tbd_ | _tbd_ | |
| TTS alone | speech-tts only | node2 (trial) | _tbd_ | _tbd_ | |
| LLM alone | speech-llm only | node3 | _tbd_ | _tbd_ | TTFT specifically |
| STT+TTS co-located | speech-stt + speech-tts | node2 | _tbd_ | _tbd_ | Option A trial - use `k8s/stt/deployment-colocated-with-tts.yaml` if separate Deployments won't co-schedule |
| LLM+TTS co-located | speech-llm + speech-tts | node3 | _tbd_ | _tbd_ | Option B trial |
| Full pipeline | gateway + stt + llm + tts | node1/2/3 | n/a | _tbd_ | real e2e TTFA, the headline number |

## Decision rule

Pick whichever of {STT+TTS combined, LLM+TTS combined} fits in 16GB with
comfortable headroom (leave margin for KV-cache growth on the LLM side under
real, batch-of-1 usage) **and** yields the lower full-pipeline TTFA.

## Decision record

_Not yet decided - fill in once Phase D actually runs._

- **Chosen option**: -
- **Reasoning**: -
- **Date**: -
