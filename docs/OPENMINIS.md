# OpenMinis as the chat front-end — assessment

OpenMinis (github.com/OpenMinis/OpenMinis, GPL-3.0, ~5k stars) is the open-source version of the
agent app this conversation runs in. Swift (iOS) + Kotlin (Android).

## What it has that LoopLab does not
- A mature agent chat: tool calls, sessions, compaction, attachments, fallback models, mentions,
  background tasks, memory, skills, MCP, a Linux sandbox (iSH), a file provider, share extension,
  widgets, Shortcuts intents (Ask, Send Prompt, Quick Task, List/Open sessions…).
- Provider abstraction (`src/ios/Providers`, `AIChatViewModel+ProviderFactory`) — cloud models only.
  No local inference anywhere in the tree.

## What a fork would add
A **local MLX provider** inside OpenMinis, using the LoopLab engine (our mlx-swift-lm fork, model
library, effort mapping, decide/score, speculation per task, loops). The agent could then route
cheap steps (classification, extraction, summarisation of tool output, short code) to the phone's
GPU and keep the cloud model for planning — the "routing by task" win from STATUS §7.

## Constraints
- **GPU is per-app and foreground-only**: two apps cannot share a loaded model, and a background
  app cannot use Metal. So the model must live *inside* OpenMinis; LoopLab cannot serve it.
- **Memory**: OpenMinis already runs a Linux sandbox; with a 1–4 GB model resident we must budget
  against the 6 GB entitlement (which our iloader fix provides).
- **Free signing**: each extension (File Provider, Share, Widget) needs its own App ID; a free
  account gets ~10 per week. First fork build should strip extensions or keep only the main app.
- **License**: GPL-3.0. Any distributed build (including our published IPAs) must ship its source
  under GPL-3.0; code merged in becomes GPL. Our repos are public, so this is compatible; LoopLab's
  own code (currently unlicensed) would need a GPL-compatible licence before merging.
- **Build**: first build compiles iSH and ffmpeg from source (30–60 min on CI).

## Plan
1. Keep LoopLab as the lab: experiments, benchmarks, queue, Shortcuts actions.
2. Extract the engine into a Swift package (`LoopLabCore`: ModelHost, ModelStore, decide, effort,
   speculation, loops) so it can be linked by both apps.
3. Fork OpenMinis; add `LocalMLXProvider` behind the existing provider protocol; a model picker fed
   by the shared library; router rules (task type → local/cloud).
4. Strip extensions for sideloading; CI like LoopLab's (xcode-27 runner, ad-hoc sign with entitlements).
