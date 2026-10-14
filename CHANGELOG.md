# Changelog — LoopLab

LoopLab is the on-device **looped-transformer** experiment app: it runs a looped/universal-transformer
model on the iPhone and measures how inference behaves when the same weights are applied repeatedly.

> **Honesty note.** Build history before `0.1.25` was not recorded systematically — the app repo had no
> changelog, and the build-by-build notes lived in session logs. What follows is reconstructed from what
> survives: the released IPAs, the device-side install listing, `docs/RECON-2026-10-10.md`, and the
> `loopscope` benchmark findings. Where a detail could not be verified it is left out rather than guessed.

| build | date | what changed |
|---|---|---|
| 0.1.20 | 2026-10-09 | `LoopLab-build20.ipa` produced — the first IPA kept on disk |
| 0.1.25 | 2026-10-10 | **Installed on device** (`io.github.collinsomniac.looplab.FRJQU6T5U5`, v0.1.25 (25)). Entitled with `increased-memory-limit`, so the app gets ≈6 GB rather than ≈3.25 GB |
| — | 2026-10-10…13 | Benchmark campaign: job specs (`p0/p1/p2`), device traces, and the `loopscope` findings R2–R6 (halting behaviour, a Qwen3 thinking-budget artefact, fair model comparison, speculation) |

## What moved out of this repo

This repo used to also carry the **generic iOS build/sign/install tooling** and the **Nabla app
documentation**. Both now live where they belong:

* `tools/`, `docs/IOS-PIPELINE.md`, `docs/ANISETTE-REPORT.md`, `docs/WIRELESS-INSTALL.md` →
  [`agent-ios-ipas`](https://github.com/collinsomniac/agent-ios-ipas)
* `docs/NABLA-*.md`, `docs/OPENMINIS-*.md`, engine notes → [`nabla-ios`](https://github.com/collinsomniac/nabla-ios)

## Current pipeline

Build on GitHub Actions (`looplab-ios` workflow) → sign headlessly with
[`loopdeploy`](https://github.com/collinsomniac/loopdeploy) → install over Wi-Fi with `pymobiledevice3`.
See `agent-ios-ipas` for the full recipe.
