# Nabla / LoopLab documentation index

Read in this order for a cold start.

| document | what it is |
|---|---|
| **NABLA-CHANGELOG.md** | patch notes, build by build — what changed and why |
| **NABLA-STACK.md** | what the fork is made of *right now*: ids, entitlements, dependencies, build/sign/install, the device, where our code lives, reference measurements |
| **LOCAL-INFERENCE.md** | the on-device subsystem in depth, with citations into the MLX source and the checkpoints' own configs |
| **INFERENCE-OPTIMISATION.md** | the bandwidth arithmetic behind observed speeds, the KV levers MLX already provides, what other engines do, claims to test |
| **ENGINE-FORK.md** | what compiling our own MLX buys: MTP resolvability, a fused quantized-KV attention kernel, the decode bandwidth model (`tools/decode_model.py`) and the bar for keeping a fork |
| **DEV-SETUP-REVIEW.md** | the assets of our setup, how well we use them, the additions that would compress the loop, and the three-pass plan |
| **MUX-DESIGN.md** | the agent multiplexer: what to copy from Herdr/OpenRig/Remux/tmux, where it plugs into the app, data model, networking, cooperation, build plan |
| **NABLA-DEBUGGING-LOG.md** | each failure as symptom → **evidence that identified it** → cause → fix → lesson, plus the verification toolkit |
| **AGENT-INSIDE-THE-APP.md** | first-hand account of building this from inside the app: the tools available, the frictions, the introspection server the app already contains, and what an agent-native app should expose |
| **OPENMINIS-ANALYSIS.md** | the upstream codebase examined before changing it: scale, layers, patterns, gaps, integration points, traps |
| **WIRELESS-INSTALL.md** | the cable-free deploy pipeline (pair once over USB → CI → sign → pack → install over Tailscale → verify) |
| **RECON-2026-10-10.md** | review of the six reference projects (ninfer, llama.cpp, Strata, UL, SwiftUI/iOS 27, uiverse galaxy) |
| **SHORTCUTS-RESEARCH.md** | what iOS Shortcuts can and cannot do for on-device models |
| **STATUS.md**, **LEARNING.md**, **METHOD.md**, **HANDOVER.md** | LoopLab: build history and measurements, inference-time learning plan, working method, handover |

Related repositories:

- `collinsomniac/looplab` — the measurement harness (batteries, Metal bench, model library) whose numbers
  every "it feels slow" claim is compared against.
- `collinsomniac/OpenMinis` — this fork.
- `collinsomniac/mlx-swift-lm` (branch `ouro-3.32.3`) — MLX with looped-model support, used by LoopLab.
  Nabla uses **upstream** 3.32.3; no fork is needed for the models in its library.
