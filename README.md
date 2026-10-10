# LoopLab

On-device lab for running and instrumenting MLX language models (including looped models such as Nanbeige4.2) on iPhone, driven by scripts or an AI agent.

- **Build:** every push to `main` builds an unsigned IPA on a GitHub `xcode-27` runner and publishes it as a release.
- **Install/update on iPhone (no Mac, free Apple ID):** add this SideStore source once:
  `https://github.com/collinsomniac/looplab/releases/latest/download/sidestore-source.json`
  then tap Update in SideStore when a new build lands.
- **Control:** the app runs a JSON server on `127.0.0.1:8765` (loopback only, token-protected). `tools/ll` drives it from a terminal on the same phone (e.g. iSH): `ll status`, `ll load nanbeige-3b`, `ll gen "hello"`, `ll bench`.
- **Models:** any MLX checkpoint on the Hugging Face Hub (`mlx-community/...`), downloaded at runtime.

## What it measures
- Device probe: model identifier, cores and caches, RAM, memory available to the process (`os_proc_available_memory`), granted entitlements (does `increased-memory-limit` actually apply?), Metal GPU limits, thermal state.
- Metal bench: 64 MiB f16 matvec at batch 1/2/4/8 (one weight read serving several tokens), thread-per-row vs simdgroup reduction, GPU-timed, outputs verified; raw blit bandwidth.
- Generation: TTFT, tokens/s (MLX's own counters), memory before/after, MLX active/cache/peak, thermal before/after.

## Layout
`project.yml` (XcodeGen) · `App/` Swift sources · `.github/workflows/build.yml` · `tools/ll`.

## Documentation
- [docs/STATUS.md](docs/STATUS.md) — build history, measured findings, open issues, priorities
- [docs/LEARNING.md](docs/LEARNING.md) — plan for weight updates at inference time (session adapters)
- [docs/OPENMINIS.md](docs/OPENMINIS.md) — forking OpenMinis as the chat front-end
- [docs/SHORTCUTS-RESEARCH.md](docs/SHORTCUTS-RESEARCH.md) — Apple Intelligence / Shortcuts research
