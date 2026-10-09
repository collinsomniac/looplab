import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Additions to the model host: a raw command log for the terminal view, speculative decoding
/// (lossless: the verifier's output is unchanged), and KV-cache quantization knobs.
extension ModelHost {

    // MARK: - raw log

    /// Records what was actually asked for and what came back, for the terminal-style view.
    static func raw(_ text: String) {
        RawLog.shared.append(text)
    }

    // MARK: - speculative decoding

    /// Load a second (smaller) model to propose tokens for the loaded one, and measure the result.
    /// Speculation is lossless by construction: every proposed token is verified by the main model,
    /// so the emitted text matches non-speculative greedy decoding.
    func loadDraft(_ idOrPreset: String) async throws -> JSONBox {
        let id = ModelHost.presets[idOrPreset] ?? idOrPreset
        ModelHost.raw("$ load --draft \(id)")
        let config = ModelConfiguration(id: id)
        let downloader = #hubDownloader()
        let resolved = try await resolve(configuration: config, from: downloader, useLatest: false) { _ in }
        let c = try await LLMModelFactory.shared.loadContainer(
            from: resolved.modelDirectory, using: #huggingFaceTokenizerLoader())
        draftContainer = c
        draftId = id
        let n = await c.perform { $0.model.numParameters() }
        ModelHost.raw("  draft ready: \(id) (\(n) params)")
        return JSONBox(["draft": id, "params": n])
    }

    /// Compare plain vs speculative decoding on the same prompt, with the same budget.
    func benchSpec(prompt: String, maxTokens: Int = 128, runs: Int = 2,
                   numDraftTokens: Int = 5) async throws -> JSONBox {
        guard let main = container else { throw NSError(domain: "ModelHost", code: 2, userInfo: [NSLocalizedDescriptionKey: "no model loaded"]) }
        guard let draft = draftContainer else { throw NSError(domain: "ModelHost", code: 3, userInfo: [NSLocalizedDescriptionKey: "no draft model loaded"]) }

        func once(speculative: Bool) async throws -> [String: Any] {
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
            let session: ChatSession
            if speculative {
                session = ChatSession(
                    main,
                    speculativeDecoding: SpeculativeDecodingConfig(
                        draftModel: draft, numDraftTokens: numDraftTokens),
                    generateParameters: params)
            } else {
                session = ChatSession(main, generateParameters: params)
            }
            let t0 = Date()
            var text = ""
            var info: [String: Any] = [:]
            for try await item in session.streamDetails(to: prompt) {
                if let chunk = item.chunk { text += chunk }
                if let i = item.info {
                    info = ["tokensPerSecond": i.tokensPerSecond,
                            "generatedTokens": i.generationTokenCount,
                            "promptTokens": i.promptTokenCount,
                            "proposed": i.proposedDraftTokens ?? 0,
                            "accepted": i.acceptedDraftTokens ?? 0,
                            "promptTime": i.promptTime,
                            "generateTime": i.generateTime]
                }
            }
            return ["text": text, "wallMs": Date().timeIntervalSince(t0) * 1000, "info": info]
        }

        var plain: [[String: Any]] = []
        var spec: [[String: Any]] = []
        for _ in 0..<max(1, runs) { plain.append(try await once(speculative: false)) }
        for _ in 0..<max(1, runs) { spec.append(try await once(speculative: true)) }

        func tps(_ xs: [[String: Any]]) -> Double {
            let v = xs.compactMap { ($0["info"] as? [String: Any])?["tokensPerSecond"] as? Double }.sorted()
            return v.isEmpty ? 0 : v[v.count / 2]
        }
        func accept(_ xs: [[String: Any]]) -> Double {
            let pairs = xs.compactMap { r -> Double? in
                guard let i = r["info"] as? [String: Any],
                      let p = i["proposed"] as? Int, let a = i["accepted"] as? Int, p > 0 else { return nil }
                return Double(a) / Double(p)
            }
            return pairs.isEmpty ? 0 : pairs.reduce(0, +) / Double(pairs.count)
        }
        let identical = (plain.first?["text"] as? String) == (spec.first?["text"] as? String)
        let result: [String: Any] = [
            "model": modelId ?? "?", "draft": draftId ?? "?",
            "numDraftTokens": numDraftTokens,
            "plainTps": tps(plain), "specTps": tps(spec),
            "speedup": tps(plain) > 0 ? tps(spec) / tps(plain) : 0,
            "acceptance": accept(spec),
            "identicalOutput": identical,
            "plainWallMs": plain.first?["wallMs"] ?? 0,
            "specWallMs": spec.first?["wallMs"] ?? 0,
            "plainText": plain.first?["text"] ?? "",
            "specText": spec.first?["text"] ?? "",
        ]
        ModelHost.raw("  spec: \(String(format: "%.1f", tps(plain))) -> \(String(format: "%.1f", tps(spec))) tok/s, acceptance \(String(format: "%.0f%%", accept(spec) * 100)), identical=\(identical)")
        return JSONBox(result)
    }

    func unloadDraft() async {
        draftContainer = nil
        draftId = nil
    }
}

/// Append-only raw log, newest last, capped.
final class RawLog: @unchecked Sendable {
    static let shared = RawLog()
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) {
        lock.lock()
        lines.append(s)
        if lines.count > 4000 { lines.removeFirst(lines.count - 4000) }
        lock.unlock()
    }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
    func clear() { lock.lock(); lines.removeAll(); lock.unlock() }
}
