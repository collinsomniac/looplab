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
    private var container: ModelContainer?
    private var history: [[String: Any]] = []
    var historyCount: Int { history.count }
    /// JSON-encoded so the value is Sendable across the actor boundary.
    func historyJSON() -> Data { (try? JSONSerialization.data(withJSONObject: ControlServer.sanitize(history))) ?? Data("[]".utf8) }

    /// Curated starting points. Any other repo id works too.
    static let presets: [String: String] = [
        "nanbeige-3b": "mlx-community/Nanbeige4.2-3B-4bit",
        "qwen3-0.6b": "mlx-community/Qwen3-0.6B-4bit",
        "qwen3-1.7b": "mlx-community/Qwen3-1.7B-4bit",
        "gemma3-1b": "mlx-community/gemma-3-1b-it-qat-4bit",
        "llama3.2-1b": "mlx-community/Llama-3.2-1B-Instruct-4bit",
    ]

    func status() -> JSONBox { JSONBox(statusDict()) }

    private func statusDict() -> [String: Any] {
        var s: [String: Any] = ["state": state.rawValue, "progress": progress]
        if let modelId { s["model"] = modelId }
        if let lastError { s["error"] = lastError }
        if let loadSeconds { s["loadSeconds"] = loadSeconds }
        if let numParams { s["params"] = numParams }
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
            let config = ModelConfiguration(id: id)
            let downloader = #hubDownloader()
            let resolved = try await resolve(configuration: config, from: downloader, useLatest: false) { p in
                Task { await ModelHost.shared.setProgress(p.fractionCompleted) }
            }
            state = .loading
            let c = try await LLMModelFactory.shared.loadContainer(
                from: resolved.modelDirectory, using: #huggingFaceTokenizerLoader())
            numParams = await c.perform { $0.model.numParameters() }
            container = c
            loadSeconds = Date().timeIntervalSince(t0)
            state = .ready
            Log.shared.add("loaded \(id) in \(String(format: "%.1f", loadSeconds ?? 0)) s, params=\(numParams ?? 0)")
            return status()
        } catch {
            state = .failed
            lastError = "\(error)"
            Log.shared.add("load failed \(id): \(error)")
            throw error
        }
    }

    func setProgress(_ p: Double) { progress = p }

    /// Generate with full measurement. Returns text + timing + memory + thermal before/after.
    func generate(prompt: String, maxTokens: Int = 256, temperature: Float = 0, system: String? = nil) async throws -> JSONBox {
        guard let c = container else { throw NSError(domain: "ModelHost", code: 2, userInfo: [NSLocalizedDescriptionKey: "no model loaded"]) }
        state = .generating
        defer { state = .ready }
        let thermalBefore = DeviceProbe.thermalString()
        let availBefore = DeviceProbe.availableMemory()
        var chat: [Chat.Message] = []
        if let system { chat.append(.system(system)) }
        chat.append(.user(prompt))
        let input = try await c.prepare(input: UserInput(chat: chat))
        let promptTokens = input.text.tokens.size
        let params = GenerateParameters(maxTokens: maxTokens, temperature: temperature)
        let t0 = Date()
        let stream = try await c.generate(input: input, parameters: params)
        var text = ""
        var firstTokenAt: Date?
        var chunks = 0
        var info: [String: Any] = [:]
        for await item in stream {
            if let chunk = item.chunk {
                if firstTokenAt == nil { firstTokenAt = Date() }
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
