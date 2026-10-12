"""Bandwidth model for on-device decode, used to check claims BEFORE building.

Decode is memory-bound: per generated token the GPU reads the weights plus the KV cache, plus whatever
intermediate tensors an attention path materialises. This models three attention paths:

  fused_fp16    MLX fast SDPA (sdpa_vector): reads fp16 K and V once, keeps scores in registers.
  unfused_q     MLX quantizedScaledDotProductAttention as written in mlx-swift-lm 3.32.3:
                quantizedMM(q, K_q) -> materialise scores [H, L] in fp32 -> softmax -> quantizedMM(p, V_q).
                Reads quantized K and V once, but also WRITES and READS the score matrix (several times:
                mask/where, softmax max+sum+exp, then the second matmul reads it).
  fused_q       a fused quantized-KV vector kernel (what an own-fork kernel would add): reads quantized
                K/V once, scores never leave registers.

Numbers: bandwidth 56 GB/s (measured, LoopLab Metal bench / decode fits). Kernel-launch overhead per
layer is approximated from LoopLab's 0.6B short-prompt result (164 tok/s for 0.36 GB/token => the
bandwidth-only ceiling would be ~155 tok/s; the residual is small, so launches are treated as ~0).
"""

BW = 56e9


def per_token_bytes(weights, layers, kv_heads, q_heads, head_dim, ctx, path, kv_bits=16, group=64):
    elems = layers * kv_heads * head_dim * ctx            # per K (same for V)
    if path == "fused_fp16":
        kv = 2 * elems * 2
        extra = 0
    else:
        # affine: bits/8 bytes per element + fp16 scale & bias per group
        per_elem = kv_bits / 8 + 2 * 2 / group
        kv = 2 * elems * per_elem
        if path == "unfused_q":
            # scores [q_heads, ctx] fp32 per layer: written by matmul, read+written by where/mask,
            # read twice and written once by softmax, read by the second matmul  => ~6 passes
            scores = layers * q_heads * ctx * 4
            extra = 6 * scores
        else:
            extra = 0
    return weights + kv + extra


def tps(b):
    return BW / b


models = {
    # name: (weight bytes, attention layers, kv heads, q heads, head dim)
    "Qwen3-0.6B-4bit": (335e6, 28, 8, 16, 128),
    "Qwen3.5-4B-4bit (8 attn layers)": (2.9e9, 8, 4, 16, 256),
    "Qwen3.5-4B-8bit (8 attn layers)": (5.14e9, 8, 4, 16, 256),
}

for name, (w, L, kvh, qh, hd) in models.items():
    print(f"\n{name}")
    print(f"  {'context':>8} | {'fp16 fused':>11} | {'8b unfused':>11} | {'4b unfused':>11} | {'8b fused':>9} | {'4b fused':>9}")
    for ctx in (256, 2048, 6600, 16000, 32000):
        r = [tps(per_token_bytes(w, L, kvh, qh, hd, ctx, "fused_fp16")),
             tps(per_token_bytes(w, L, kvh, qh, hd, ctx, "unfused_q", 8)),
             tps(per_token_bytes(w, L, kvh, qh, hd, ctx, "unfused_q", 4)),
             tps(per_token_bytes(w, L, kvh, qh, hd, ctx, "fused_q", 8)),
             tps(per_token_bytes(w, L, kvh, qh, hd, ctx, "fused_q", 4))]
        print(f"  {ctx:>8} | " + " | ".join(f"{x:>9.0f}  " if i < 3 else f"{x:>7.0f}  " for i, x in enumerate(r)))
