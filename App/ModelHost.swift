import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import HuggingFace
import Tokenizers

/// Plug-and-play model host: any MLX checkpoint id on the Hugging Face Hub (mlx-community/...)
/// or a local directory. One model resident at a time; every generation is measured.
/// Sendable carrier for JSON-shaped results crossing actor boundaries.
struct JSONBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ v: [String: Any]) { value = v }
}

actor ModelHost {
    static let shared = ModelHost()

    enum State: String { case idle, downloading, loading, ready, generating, failed }

    private(set) var state: State = .idle
    private(set) var modelId: String?
    private(set) var progress: Double = 0
    private(set) var lastError: String?
    private(set) var loadSeconds: Double?
    private(set) var numParams: Int?
    private(set) var lastRead: [String: Any] = [:]
    var container: ModelContainer?
    /// Optional smaller model used to propose tokens for speculative decoding.
    /// When set, generation uses a quantized KV cache (e.g. 8 or 4 bits) instead of fp16.
    var kvBitsOverride: Int?

    var draftContainer: ModelContainer?
    var draftId: String?
    private var history: [[String: Any]] = []
    var historyCount: Int { history.count }
    /// JSON-encoded so the value is Sendable across the actor boundary.
    func historyJSON() -> Data { (try? JSONSerialization.data(withJSONObject: ControlServer.sanitize(history))) ?? Data("[]".utf8) }

    /// Curated starting points. Any other repo id works too.
    /// Every id here was checked to exist on the Hub. Ouro entries are the looped models.
    static let presets: [String: String] = [
        "ouro-1.4b": "mlx-community/Ouro-1.4B-4bit",
        "ouro-1.4b-thinking": "mlx-community/Ouro-1.4B-Thinking-4bit",
        "ouro-2.6b": "mlx-community/Ouro-2.6B-4bit",
        "qwen3-0.6b": "mlx-community/Qwen3-0.6B-4bit",
        "qwen3-1.7b": "mlx-community/Qwen3-1.7B-4bit",
        "qwen3-4b": "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        "qwen2.5-coder-1.5b": "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
        "qwen3.5-0.8b": "mlx-community/Qwen3.5-0.8B-4bit",
        "qwen3.5-2b": "mlx-community/Qwen3.5-2B-4bit",
        "qwen3.5-4b": "mlx-community/Qwen3.5-4B-4bit",
        "llama3.2-1b": "mlx-community/Llama-3.2-1B-Instruct-4bit",
        "gemma3-1b": "mlx-community/gemma-3-1b-it-qat-4bit",
    ]

    func status() -> JSONBox { JSONBox(statusDict()) }

    private func statusDict() -> [String: Any] {
        var s: [String: Any] = ["state": state.rawValue, "progress": progress]
        if let modelId { s["model"] = modelId }
        if let lastError { s["error"] = lastError }
        if let loadSeconds { s["loadSeconds"] = loadSeconds }
        if let numParams { s["params"] = numParams }
        s.merge(lastRead) { a, _ in a }
        s["mlxMemory"] = Self.mlxMemory()
        s["generations"] = history.count
        return s
    }

    static func mlxMemory() -> [String: Any] {
        [
            "active": Memory.activeMemory,
            "cache": Memory.cacheMemory,
            "peak": Memory.peakMemory,
            "cacheLimit": Memory.cacheLimit,
            "memoryLimit": Memory.memoryLimit,
        ]
    }

    func unload() {
        container = nil
        modelId = nil
        state = .idle
        Memory.clearCache()
    }

    func load(_ idOrPreset: String, cacheLimitMB: Int = 64) async throws -> JSONBox {
        let id = Self.presets[idOrPreset] ?? idOrPreset
        if modelId == id, container != nil { return status() }
        unload()
        state = .downloading; progress = 0; lastError = nil; modelId = id
        Memory.cacheLimit = cacheLimitMB * 1024 * 1024
        Memory.peakMemory = 0
        let t0 = Date()
        do {
            let dir: URL
            if ModelStore.isInstalled(id) {
                dir = ModelStore.dir(for: id)
                TermSink.shared.line("  from library: \(dir.lastPathComponent)")
            } else {
                TermSink.shared.line("  downloading \(id) into the library")
                let downloader = #hubDownloader()
                let resolved = try await resolve(configuration: ModelConfiguration(id: id), from: downloader, useLatest: false) { p in
                    TermSink.shared.progress(p.fractionCompleted)
                    Task { await ModelHost.shared.setProgress(p.fractionCompleted) }
                }
                dir = try ModelStore.adopt(from: resolved.modelDirectory, id: id)
                TermSink.shared.line("  saved to Files › LoopLab › Models › \(dir.lastPathComponent)")
            }
            if let fix = ModelStore.normalizeTokenizer(in: dir) { TermSink.shared.line("  tokenizer: \(fix)") }
            state = .loading
            let tRead = Date()
            let c = try await LLMModelFactory.shared.loadContainer(
                from: dir, using: #huggingFaceTokenizerLoader())
            let readS = Date().timeIntervalSince(tRead)
            let diskBytes = ModelStore.size(of: dir)
            TermSink.shared.line(String(format: "  read %.2f GB in %.2f s (%.2f GB/s)", Double(diskBytes) / 1e9, readS, readS > 0 ? Double(diskBytes) / readS / 1e9 : 0))
            numParams = await c.perform { $0.model.numParameters() }
            container = c
            loadSeconds = Date().timeIntervalSince(t0)
            lastRead = ["readSeconds": readS, "diskBytes": diskBytes, "fromLibrary": true]
            state = .ready
            Log.shared.add("loaded \(id) in \(String(format: "%.1f", loadSeconds ?? 0)) s, params=\(numParams ?? 0)")
            return status()
        } catch {
            state = .failed
            let msg = "\(error)"
            lastError = msg.contains("401") || msg.contains("Invalid username")
                ? "\(id) could not be downloaded (does it exist?). Hub said: \(msg)"
                : msg
            Log.shared.add("load failed \(id): \(error)")
            throw error
        }
    }

    func setProgress(_ p: Double) { progress = p }

    /// How many times the looped stack is applied for the loaded model (no-op for non-looped models).
    @discardableResult
    func setLoops(_ n: Int) async -> JSONBox {
        guard let c = container else { return JSONBox(["error": "no model loaded"]) }
        try? await c.perform { context in
            if let ouro = context.model as? OuroModel { ouro.setLoopCount(n) }
        }
        return JSONBox(["loops": n, "model": modelId ?? "?"])
    }

    /// Decode throughput of the *loaded* model: N runs of the same prompt, reporting per-run tok/s,
    /// TTFT and thermal, plus min/median/max. This is the number to compare against published results.
    func benchDecode(prompt: String, maxTokens: Int = 128, runs: Int = 3,
                     cacheLimitMB: Int? = nil, memoryLimitGB: Double? = nil,
                     kvBits: Int? = nil) async throws -> JSONBox {
        // apply memory policy knobs so the same model can be measured under different settings
        if let c = cacheLimitMB { Memory.cacheLimit = c * 1024 * 1024 }
        if let g = memoryLimitGB { Memory.memoryLimit = Int(g * 1_073_741_824) }
        kvBitsOverride = kvBits
        let limits = ["cacheLimit": Memory.cacheLimit, "memoryLimit": Memory.memoryLimit,
                      "recommendedWorkingSet": GPU.maxRecommendedWorkingSetBytes() ?? 0,
                      "kvBits": kvBits as Any]
        var per: [[String: Any]] = []
        for i in 0..<max(1, runs) {
            let r = try await generate(prompt: prompt, maxTokens: maxTokens, temperature: 0).value
            let info = r["mlxInfo"] as? [String: Any] ?? [:]
            per.append(["run": i,
                        "tokensPerSecond": info["tokensPerSecond"] ?? 0,
                        "generatedTokens": info["generatedTokens"] ?? 0,
                        "promptTokens": info["promptTokenCount"] ?? 0,
                        "ttftMs": r["ttftMs"] ?? 0,
                        "promptTime": info["promptTime"] ?? 0,
                        "generateTime": info["generateTime"] ?? 0,
                        "thermal": r["thermalAfter"] ?? "?",
                        "available": r["availableAfter"] ?? 0,
                        "mlxMemory": r["mlxMemory"] ?? [:],
                        "textSample": String((r["text"] as? String ?? "").prefix(120))])
        }
        let tps = per.compactMap { $0["tokensPerSecond"] as? Double }.sorted()
        return JSONBox([
            "model": modelId ?? "?",
            "prompt": prompt,
            "limits": limits,
            "maxTokens": maxTokens,
            "runs": per,
            "min": tps.first ?? 0,
            "median": tps.isEmpty ? 0 : tps[tps.count / 2],
            "max": tps.last ?? 0,
            "thermal": DeviceProbe.thermalString(),
            "mlxMemory": Self.mlxMemory(),
        ])
    }

    /// Generate with full measurement. Returns text + timing + memory + thermal before/after.
    func generate(prompt: String, maxTokens: Int = 256, temperature: Float = 0, system: String? = nil,
                  thinking: Bool = false,
                  topP: Float? = nil, repetitionPenalty: Float? = nil, seed: UInt64? = nil,
                  onFirstToken: (@Sendable () -> Void)? = nil,
                  onChunk: (@Sendable (String) -> Void)? = nil) async throws -> JSONBox {
        guard let c = container else { throw NSError(domain: "ModelHost", code: 2, userInfo: [NSLocalizedDescriptionKey: "no model loaded"]) }
        state = .generating
        defer { state = .ready }
        let thermalBefore = DeviceProbe.thermalString()
        let availBefore = DeviceProbe.availableMemory()
        var chat: [Chat.Message] = []
        if let system { chat.append(.system(system)) }
        chat.append(.user(prompt))
        // Hybrid-reasoning models (Qwen3, Qwen3.5) think by default; the template flag turns it off.
        let input = try await c.prepare(input: UserInput(chat: chat, additionalContext: ["enable_thinking": thinking]))
        let promptTokens = input.text.tokens.size
        var params = GenerateParameters(maxTokens: maxTokens, temperature: temperature)
        if let topP { params.topP = topP }
        if let repetitionPenalty, repetitionPenalty != 1 { params.repetitionPenalty = repetitionPenalty }
        if let seed { params.seed = seed }
        if let kv = kvBitsOverride {
            params.kvBits = kv
            params.quantizedKVStart = 0
        }
        let t0 = Date()
        let stream = try await c.generate(input: input, parameters: params)
        var text = ""
        var firstTokenAt: Date?
        var chunks = 0
        var info: [String: Any] = [:]
        for await item in stream {
            if let chunk = item.chunk {
                if firstTokenAt == nil { firstTokenAt = Date(); onFirstToken?(); if TermSink.shared.echoTokens { TermSink.shared.write("  │ ") } }
                if TermSink.shared.echoTokens { TermSink.shared.write(chunk.replacingOccurrences(of: "\n", with: "\n  │ ")) }
                onChunk?(chunk)
                text += chunk
                chunks += 1
            }
            if let i = item.info {
                info = [
                    "promptTokens": i.promptTokenCount,
                    "generatedTokens": i.generationTokenCount,
                    "promptTokensPerSecond": i.promptTokensPerSecond,
                    "tokensPerSecond": i.tokensPerSecond,
                ]
            }
        }
        let t1 = Date()
        if firstTokenAt != nil && TermSink.shared.echoTokens { TermSink.shared.write("\n") }
        let ttft = (firstTokenAt ?? t1).timeIntervalSince(t0)
        var rec: [String: Any] = [
            "model": modelId ?? "",
            "prompt": prompt,
            "text": text,
            "promptTokens": promptTokens,
            "chunks": chunks,
            "ttftMs": ttft * 1000,
            "wallMs": t1.timeIntervalSince(t0) * 1000,
            "thermalBefore": thermalBefore,
            "thermalAfter": DeviceProbe.thermalString(),
            "availableBefore": availBefore,
            "availableAfter": DeviceProbe.availableMemory(),
            "physFootprint": DeviceProbe.physFootprint(),
            "mlxMemory": Self.mlxMemory(),
            "at": ISO8601DateFormatter().string(from: t0),
        ]
        rec["mlxInfo"] = info
        history.append(rec)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        return JSONBox(rec)
    }
}
