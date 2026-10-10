# LoopLab — status, findings and direction (2026-10-09, after build 23)

LoopLab is a sideloaded iOS app that runs open-weight language models on an iPhone 17 Pro Max
(A19 Pro, 12 GB, iOS 27) with MLX, and measures everything it does. A desktop on the tailnet acts as
a job queue and as the permanent record of every run. This document is the source of truth for what
has been built, what has been measured, and what we think follows from it.

---

## 1. The device, as measured

| quantity | value | how we know |
|---|---|---|
| memory the app may use | **5.96 GB** (3.25 GB without the entitlement) | `os_proc_available_memory`, builds 14→16 |
| GPU memory bandwidth, our own kernel | **66–70 GB/s** = 86–91% of the 76.8 GB/s spec | verified Metal streaming bench |
| effective bandwidth during decode | ~55–59 GB/s | tok/s × bytes per token, several models |
| flash storage, cold read | **1.4–3.6 GB/s**, random 4 MB ≈ sequential, p50 1–3.6 ms | `read_bench`, F_NOCACHE |
| thermal swing between identical runs | up to ~20% | repeated configs within a session |

**Planning rule: decode tokens/s ≈ 56 GB/s ÷ bytes read per token.** Weights dominate the bytes,
so a 4-bit model's speed is roughly 56 / (size in GB). It held for every dense model we ran:
Qwen3-0.6B 164, Llama-3.2-1B 86–89, Qwen3-1.7B 60–62, Qwen2.5-Coder-1.5B 70, Qwen3-4B 25–27 tok/s.

## 2. Build history

| build | what changed | what it taught us |
|---|---|---|
| 3–8 | First app: MLX model host, device probe, Metal bench, token-protected loopback API; CI on GitHub's Xcode 27 runners; ad-hoc signing **with** entitlements; desktop job queue over the tailnet (HTTPS) | SideStore drops the memory entitlement unless the IPA requests it; the tool chain (iloader) had it hard-coded off → we patched and rebuilt iloader |
| 12–14 | Five-tab state-driven UI, decode bench with min/median/max, memory-policy knobs, MLX internal timings | — |
| 14→16 | **Memory entitlement granted (3.25 → 5.96 GB)** | **~3× decode speed** (Qwen3-0.6B 43–54 → 144–168 tok/s), TTFT 1.8 s → 21–46 ms, Metal 36–39 unstable → 66–68 GB/s stable. The jetsam ceiling had been starving MLX's buffer pool. |
| 16 | Our MLX fork gains **Ouro** (looped model): sandwich norms, per-loop final norm, exit gate, `setLoopCount`, `forwardLoops` | Loop cost is linear in time; quality plateaus at 2 loops (§3.3) |
| 19 | Speculative decoding step, KV-cache quantization, raw command log | first runs measured thinking text (artifact) |
| 20 | Thinking off by default (`enable_thinking`), single-pass `decide` op, first Shortcuts actions (Generate Text, Decide), Qwen3.5 presets | first fair model comparison (§3.1); Shortcuts actions work with the app closed |
| 22 | On-device model library in Files, model picker for Shortcuts, Effort with defaults read from the model, timeouts and foreground option, Score/Load/Unload/List actions, Models tab with read bench, terminal Queue with runs stored on the desktop | **decode fell to ~40%** (§4) |
| 23 | Line-based lazy terminal, `echo` switch, tab/battery per step, OLMoE tokenizer alias | A/B showed the terminal is **not** the cause (§4) |
| 24 (pending) | Static probe values cached (no Metal device creation or profile parsing every 1.5 s), library cached instead of rescanned on every render, models excluded from iCloud backup | — |

## 3. Findings

### 3.1 Which model, for which job (thinking off, build 20, code scored by running it)
| model | gen /30 | code /8 | tok/s | s per answer | decide /16 |
|---|---|---|---|---|---|
| Qwen3-0.6B | 18 | 6 | 164 | 0.37 | 8 (and ~90% confident: miscalibrated) |
| Qwen3.5-0.8B | 22 | 4 | 135 | 0.29 | 12 |
| **Qwen3-1.7B** | **28** | **8** | 62 | 0.71 | 14 |
| Qwen3.5-2B | 20 | 6 | 57 | 0.92 | **16** |
| **Qwen2.5-Coder-1.5B** | **28** | **8** | **70** | **0.58** | 14 |
| Qwen3-4B-Instruct-2507 | 26 | 6 | 25 | 1.76 | 14 |
| Qwen3.5-4B | 20 | 6 | 25 | 1.68 | **16** |

- **Best task-to-cost today: Qwen2.5-Coder-1.5B** (ties the best score, fastest per answer, terse).
- **Larger is not better at a fixed token budget**: the 4Bs lose to verbosity (docstrings cut off), not ability.
- **Qwen3.5 explains arithmetic instead of answering** (format), but follows the decision format
  almost perfectly (~100% of probability on the option letters) → best decision models we have.
- A first-token read of a chat model is a cheap classifier (74–300 ms) but uncalibrated at 0.6B.

### 3.2 Mixture-of-experts on the phone (builds 22/23, absolute speeds affected by §4)
| model | total / active | disk | decode | quality |
|---|---|---|---|---|
| OLMoE-1B-7B | 7B / 1.3B | 3.9 GB | **42 tok/s** | correct code + word problem |
| LFM2-8B-A1B | 8.3B / 1.5B | 5.2 GB | 27–29 | 12/12, 6/6 |
| Granite-4.0-h-tiny | 7B / 1B (hybrid Mamba) | 3.9 GB | 25–26 | 12/12, 6/6 |
| Qwen3-1.7B (dense, same session) | 1.7B | 1.0 GB | 26.6 | 12/12 |

In the same session **a 3.9 GB 7B MoE ran 1.6× faster than a 1 GB dense model**. Speed tracks
active bytes, not total size. Storage reads are 20–40× slower than RAM, so streaming experts from
flash only works with a high expert-cache hit rate.

### 3.3 Loops (Ouro-1.4B, recurrent depth)
| loops | correct (24) | tok/s |
|---|---|---|
| 1 | 4 (17%) | 73 |
| 2 | 20 (83%) | 38 |
| 4 | 20 (83%) | 18.5 |
Linear cost, plateau at 2; 4 loops broke one arithmetic answer ("overthinking") and fixed the
bat-and-ball. Depth helps per item, not on average → the win is **adaptive** depth per token.

### 3.4 Speed techniques
| technique | result | verdict |
|---|---|---|
| memory entitlement | ~3× | essential |
| thinking off for short tasks | 0% → 93% of answers finishing within budget | essential default; Effort turns it on |
| speculative decoding 0.6B → 4B | code ×1.19–1.42, prose ×0.60–0.88 | **per task**: on for code/structured output, off for chat; n = 2–3 |
| speculative 0.6B → 1.7B | ×1.02–1.08 | not worth it (draft too large relative to target) |
| KV-cache 8/4-bit at ≤ 200 tokens | −6% | long-context memory tool only; 4-bit broke Qwen3 with thinking on |
| loading from library | 1 GB in 0.6 s warm; 5 GB in 3–4 s cold | fine |
| speculative output "not identical" | divergence at a near-tie (docstring-first vs signature-first) | both valid; exact losslessness needs deterministic kernels |

## 4. Open issue: builds 22–23 decode at ~40% of build 20

| model | build 20 | build 23, echo off | build 23, echo on |
|---|---|---|---|
| Qwen3-0.6B | 164 | 54–55 | 46–54 |
| Qwen3-1.7B | 60–62 | 26.6–27.2 | 26.2–26.9 |
| Qwen3-4B | 25–27 | 11.3–11.9 | 11.3–11.4 |
| Metal bench, simdgroup | **68–70 GB/s** | **36–38 GB/s** | |

**Ruled out**: terminal rendering (echo on/off ±2%), visible tab, thermal (nominal), Low Power Mode,
the memory entitlement (granted, same 5.96 GB), MLX/mlx-swift-lm versions (unchanged since build 16),
weights source (identical files).
**Key clue**: our own Metal kernel, which shares no code with MLX or the model path, dropped from
68–70 to 36–38 GB/s at the same time, and was already low (39 GB/s) in the first run on build 22.
So the GPU itself is running at half bandwidth, for everything.
**Candidates**: (a) the device entered a reduced-performance state (charge/battery state, a long
uptime — it was at ~18 h; the first sessions of the day ran at full speed); (b) something new in
builds 22–23 keeping the GPU or memory busy (none found: no new Metal work, timers only touch
memory and thermal); (c) the per-1.5 s device probe creating a Metal device and parsing the
provisioning profile (present since early builds; cached in build 24 regardless).
**Decisive test**: reboot the phone → run Tests › Metal bench on build 23. 68+ GB/s means the device
state was the cause. Still ~37 means it is the app → install the staged **build 20**
(`D:\loopscope\LoopLab-build20.ipa`) and run the same bench.

## 5. Shortcuts

Working today (from Shortcuts, with the app closed): Generate Text, Decide, Score Options, Load /
Unload / Get Models, model picker from the library, Effort with defaults read from the model.
Research (SHORTCUTS-RESEARCH.md): no third-party model can back Apple's "Use Model" (On-Device,
Cloud, Cloud Pro, ChatGPT only); iOS 27 `LongRunningIntent` gives GPU access in the background with a
Live Activity; default background budget ≈ 30 s; model work must run in the main app process.

Next actions, by value:
1. Long-running mode with progress for every model action (fixes the "hung" load).
2. **Extract**: field list → dictionary (JSON constrained decoding).
3. **Typed answers**: Yes/No → Boolean, Number, Date, List — they feed If directly.
4. Writing Tools parity (summarize, rewrite, proofread, tone) with length/format controls.
5. Conversation entity: chats that persist across runs (transcript + cached prompt state).
6. Embeddings: similarity, rank, dedupe.

## 6. Learning at inference time

See `docs/LEARNING.md` for the full plan. In short: the engine already contains LoRA/DoRA layers and
a LoRA trainer (`MLXLLM/LoraTrain.swift`), so **weight updates on the phone are possible today**
within the same 6 GB. The literature of the last weeks shows the main hazard: a model that trains on
its own output degrades (self-generated feedback destabilizes test-time training, 2610.05076); the
updates that work train on verified outcomes (ASCENT 2610.05303), protect old behaviour by
distillation from the frozen model (2610.06940), or touch only a sparse memory (SMF, 2510.15103 /
2605.03229).

## 7. Where we think the biggest wins are (cost per completed task)

1. **Fix the 2× regression** — larger than every other optimisation combined.
2. **Route by task**: Coder-1.5B for code and extraction, Qwen3.5-2B/4B for decisions, OLMoE when a
   larger-knowledge model is needed at small-model speed, Qwen3-4B only for hard long-form.
3. **Shorter answers**: answer-first prompts, stop sequences, constrained output. On this hardware
   tokens are the cost; most 4B losses were tokens spent on preamble.
4. **Prompt-cache reuse** for chat and repeated Shortcuts (system prompt + history prefilled once).
5. **Speculation where it pays** (code, structured output) with n = 2–3.
6. **Adaptive depth** for looped models; MoE expert caching for models larger than RAM.
7. **Learning at inference** as a per-project adapter (§6).
