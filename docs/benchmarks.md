# Benchmarks

Carried forward from `doc/Speech-to-Speech K8S Proposal.md` - this is the
mechanism that decides final `speech-tts` placement (Option A vs Option B)
and validates the HTTP-first architecture's TTFA under real network
conditions.

**Note on node assignment**: the original Option A/B framing below assumed
`node2`/`node3` could be freely chosen. In practice `node2` had a physical
outage (see `docs/deployment.md` "Status"), so the actual current layout is
`node2 = speech-llm` alone, `node3 = speech-stt + speech-tts` colocated -
the mirror image of "Option A" with the node labels swapped, not literally
either named option. Rows below record what was actually measured, on the
node it actually ran on.

## Matrix

Run each row with the same test utterance(s)/prompt(s). Record **VRAM**
(peak, via `./scripts/record-vram.sh <pod>`) and **latency**, especially
**TTFA** (time from user-audio-end to first synthesized-audio byte reaching
the gateway).

| Row | Config | Node(s)       | VRAM (MB) | Latency / TTFA (ms) | Notes |
|---|---|---------------|---|---|---|
| STT alone | speech-stt only | node3         | _tbd_ | _tbd_ | Smoke-tested (transcript correct); VRAM not isolated separately from the combined figure below |
| TTS alone | speech-tts only | node3 | _tbd_ | _tbd_ | Smoke-tested (valid WAV returned); VRAM not isolated separately from the combined figure below |
| LLM alone | speech-llm only | node2 (gemma-4-E4B-it-Q8_0)      | 8731 | _tbd_ | TTFT specifically; smoke-tested (`/health` + chat completion both OK) |
| STT+TTS co-located | speech-stt + speech-tts | node3 | 6772 / 16311 | _tbd_ | Retargeted `k8s/stt/deployment-colocated-with-tts.yaml` from node2 to node3 (see file header). Pod reached `2/2 Running` in ~20s (model caches already warm); STT and TTS smoke-tested **concurrently** (both requests succeeded) - confirms real coexistence on one GPU, not just idle presence. Comfortable headroom: 6.8GB used of 16.3GB. |
| LLM+TTS co-located | speech-llm + speech-tts | node3         | _tbd_ | _tbd_ | Option B trial - not yet run |
| Full pipeline | gateway + stt + llm + tts | node1/2/3     | n/a | _tbd_ | real e2e TTFA, the headline number - gateway not yet deployed |

## Decision rule

Pick whichever of {STT+TTS combined, LLM+TTS combined} fits in 16GB with
comfortable headroom (leave margin for KV-cache growth on the LLM side under
real, batch-of-1 usage) **and** yields the lower full-pipeline TTFA.

## Decision record

_Latency/TTFA and the LLM+TTS alternative still need measuring before this
is final - not a complete Phase D run yet._

- **Chosen option**: Leaning towards the current layout - `node2 = speech-llm`
  alone, `node3 = speech-stt + speech-tts` colocated via
  `k8s/stt/deployment-colocated-with-tts.yaml` - since it's already
  confirmed working and STT+TTS together use well under half of node3's
  16GB (6.8GB), leaving headroom that Option B (LLM+TTS on node3, competing
  with the LLM's own 8.7GB and KV-cache growth) would not have as
  comfortably.
- **Reasoning**: VRAM headroom favors keeping the LLM (the one component
  with growing KV-cache memory under real usage) on its own GPU, away from
  the two comparatively small, fixed-footprint STT/TTS models.
- **Date**: 2026-09-09 (VRAM measured; latency/TTFA still open)
