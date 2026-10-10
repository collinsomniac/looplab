# Learning at inference time — plan for LoopLab

## The goal
A model that changes **its own weights** from what it does after deployment, so that a model which
has worked in one repository for a week is measurably better at that repository — and the learned
state is a file you can copy, back up, restore, and continue from. Not retrieval and not a longer
prompt: parameters.

## What is true today
- Context-based memory (notes, retrieval, long prompts) does not change the model. It costs tokens
  every turn and is lost when it falls out of the window.
- The engine we already ship has the parts for weight updates: LoRA and DoRA layers, adapter
  loading, and a trainer (`MLXLLM/LoraTrain.swift`: value-and-grad, optimizer step, per-iteration
  loss). A rank-8 LoRA on a 1.5B model is ~10–20 MB: easy to save, copy, version.
- Memory budget: 4-bit Qwen2.5-Coder-1.5B ≈ 0.9 GB weights; LoRA gradients and optimizer state for a
  few million parameters plus activations for short sequences fit well inside 6 GB.

## What the recent literature says (2025–2026)
| result | what it means for us |
|---|---|
| Self-generated feedback destabilizes TTT (2610.05076): training on its own generated text worsens the model, on Qwen3-4B too; using a frozen generator removes >98% of the damage | never train blindly on raw outputs |
| ASCENT (2610.05303): online training of an agent on its own trajectories works when the signal is **verified** experience and done by self-distillation, not by imitating the tokens | the signal must be checked: tests pass, user accepted, tool call succeeded |
| Condition-anchored distillation (2610.06940): keep a small set of old prompts, match the frozen model's distributions on them while learning | the anti-forgetting term |
| Sparse Memory Finetuning (2510.15103, 2605.03229): update only the few rows of a memory layer the batch reads most; +2.5 pts with ~1 pt forgetting vs clear drift for LoRA/full | a lower-forgetting alternative to LoRA, needs a memory layer added |
| Titans (2501.00663), Nested Learning (2512.24695), uTTT (2610.05484): architectures whose "fast weights" are updated during inference by design | the long-run direction; needs models trained that way |
| Agentic-TTT (2610.12002): learning when to train is itself a policy; TTT is not always beneficial | gate updates; measure before keeping |

## The design we would test
1. **Unit of learning = a session adapter.** A LoRA (or DoRA) on attention and MLP projections of a
   base model, one per project/repository. Base weights never change. The adapter is a file in the
   library next to the model: copy, share, roll back, continue training.
2. **Signal = verified outcomes only.** Code that ran and passed its tests; an answer the user
   accepted; a tool call that succeeded; a decision later confirmed. Store (prompt, accepted
   output, verdict) tuples.
3. **Update = small, gated, reversible.** A few optimizer steps after each verified task (or in a
   batch overnight while charging), with an anchor term: KL to the frozen base on a fixed set of
   held-out prompts. Keep the update only if the held-out battery does not regress (we already have
   the batteries and the scorer).
4. **Evaluation = before/after on the same tasks, plus forgetting probes.** Repository-specific
   tasks (held out from training), general batteries (09), perplexity on unrelated text.

## Experiments, in order
| # | experiment | question |
|---|---|---|
| L1 | Train a LoRA on the phone from a fixed set of 50 verified (prompt, solution) pairs for one codebase; measure step time, memory, and before/after on 20 held-out tasks + battery 09 | can the phone train at all, at what cost, and does it help |
| L2 | Same, but the data are the model's own outputs, kept only if their tests pass | verified self-training vs the "self-generated feedback" failure |
| L3 | Add the anchor term; vary rank, steps, learning rate | forgetting vs gain trade-off |
| L4 | Online: update after every verified task during a working session | does it keep improving or drift |
| L5 | Copy the adapter to a fresh install / to the desktop, continue training there, bring it back | "copy the weights and continue" |
| L6 | Sparse memory layer instead of LoRA | lower forgetting? |
| L7 | Looped model: train the exit gate/loop LoRA on the device's own tasks | adaptive depth learned from use |

## What it would take in the app
- `train` job op wrapping `LoRATrain.train` with progress in the terminal, loss per step, and the
  adapter saved to `Models/<model>/adapters/<name>/`.
- Adapter picker on Generate Text and in Chat; "Load adapter" / "Save adapter" Shortcuts actions.
- A verified-experience log: Chat thumbs-up and Shortcuts "Record Outcome" action.
- Battery runs before and after any adapter is promoted.
