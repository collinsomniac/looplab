import Foundation
import MLX
import MLXLMCommon

/// Jev/Clef-style typed decision on an ordinary causal LM.
///
/// One prefill, no sampling: build a prompt that ends right where the answer begins, read the
/// next-token logits, and compare the log-probability of each option's first token.
/// Options whose first tokens collide are scored by full sequence log-prob instead (extra passes).
///
/// This is the cheap baseline that real decision models (Laya, Clef, Wald) are trained to beat:
/// they add calibration and a dedicated head; this uses the LM head as-is.
extension ModelHost {

    func decide(state: String, question: String, options: [String],
                instructions: String? = nil) async throws -> JSONBox {
        guard let c = container else {
            throw NSError(domain: "ModelHost", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no model loaded"])
        }
        let t0 = Date()
        let letters = options.indices.map { String(UnicodeScalar(UInt8(65 + $0))) } // A, B, C...
        var body = ""
        if let instructions { body += instructions + "\n\n" }
        body += "Input:\n\(state)\n\nQuestion: \(question)\nOptions:\n"
        for (l, o) in zip(letters, options) { body += "\(l). \(o)\n" }
        body += "\nReply with the letter of the single best option only."

        let result: [String: Any] = try await c.perform { ctx in
            // Chat template, thinking off, then append the assistant's answer prefix.
            let chat: [Chat.Message] = [.user(body)]
            let prepared = try await ctx.processor.prepare(
                input: UserInput(chat: chat, additionalContext: ["enable_thinking": false]))
            var tokens = prepared.text.tokens.asArray(Int.self)
            // Some templates still emit an empty think block; it is part of the prompt either way.
            let promptLen = tokens.count

            // Candidate first tokens: the bare letter, with and without a leading space.
            var cand: [[Int]] = []
            for l in letters {
                var ids = Set<Int>()
                for s in [l, " " + l] {
                    let e = ctx.tokenizer.encode(text: s, addSpecialTokens: false)
                    if e.count == 1 { ids.insert(e[0]) }
                }
                cand.append(Array(ids))
            }

            let tPrefill = Date()
            let cache = try ctx.model.newCache(parameters: nil)
            let input = MLXArray(tokens).reshaped(1, tokens.count)
            let logits = ctx.model(input, cache: cache)          // [1, T, V]
            let last = logits[0, -1].asType(.float32)            // [V]
            let logp = last - logSumExp(last, axis: -1)
            eval(logp)
            let prefillMs = Date().timeIntervalSince(tPrefill) * 1000

            var scores: [Double] = []
            let lp = logp.asArray(Float.self)
            for ids in cand {
                // log of summed probability over the letter's surface forms
                let ps = ids.map { Double(exp(lp[$0])) }
                scores.append(log(max(ps.reduce(0, +), 1e-30)))
            }
            // Renormalise over the options -> a distribution over choices.
            let m = scores.max() ?? 0
            let ex = scores.map { exp($0 - m) }
            let z = ex.reduce(0, +)
            let probs = ex.map { $0 / z }
            let mass = scores.map { exp($0) }.reduce(0, +)   // how much of the LM's mass landed on any option
            let best = probs.indices.max { probs[$0] < probs[$1] } ?? 0
            tokens.removeAll()
            return [
                "answer": options[best],
                "index": best,
                "probabilities": Dictionary(uniqueKeysWithValues: zip(options, probs)),
                "optionMass": mass,
                "promptTokens": promptLen,
                "prefillMs": prefillMs,
            ]
        }
        var out = result
        out["totalMs"] = Date().timeIntervalSince(t0) * 1000
        out["model"] = modelId ?? "?"
        out["thermal"] = DeviceProbe.thermalString()
        ModelHost.raw("  decide -> \(out["answer"] ?? "?") in \(String(format: "%.0f", out["totalMs"] as? Double ?? 0)) ms")
        return JSONBox(out)
    }
}
