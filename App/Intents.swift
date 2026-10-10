import AppIntents
import Foundation
import UIKit

// MARK: - Model entity (the picker Shortcuts shows instead of a text field)

struct LocalModelEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "On-Device Model"
    static var defaultQuery = LocalModelQuery()

    var id: String          // repo id
    var title: String
    var subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    init(_ m: InstalledModel, loaded: Bool) {
        id = m.id
        title = m.name
        var parts = [m.sizeText, m.modelType]
        if m.looped { parts.append("looped") }
        if m.thinkingCapable { parts.append("can think") }
        if loaded { parts.insert("loaded", at: 0) }
        subtitle = parts.joined(separator: " · ")
    }
}

struct LocalModelQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [LocalModelEntity] {
        let loaded = await ModelHost.shared.modelId
        return identifiers.compactMap { id in ModelStore.find(id).map { LocalModelEntity($0, loaded: $0.id == loaded) } }
    }
    func suggestedEntities() async throws -> [LocalModelEntity] {
        let loaded = await ModelHost.shared.modelId
        return ModelStore.installed().map { LocalModelEntity($0, loaded: $0.id == loaded) }
    }
    func entities(matching string: String) async throws -> [LocalModelEntity] {
        try await suggestedEntities().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }
    /// When the user leaves Model empty: the model already in memory, else the first installed one.
    func defaultResult() async -> LocalModelEntity? {
        let loaded = await ModelHost.shared.modelId
        let all = ModelStore.installed()
        if let m = all.first(where: { $0.id == loaded }) ?? all.first { return LocalModelEntity(m, loaded: m.id == loaded) }
        return nil
    }
}

// MARK: - Effort (one dial, mapped per model family)

enum Effort: String, AppEnum {
    case fast, balanced, thorough
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Effort"
    static var caseDisplayRepresentations: [Effort: DisplayRepresentation] = [
        .fast: "Fast", .balanced: "Balanced", .thorough: "Thorough",
    ]
}

/// Defaults read from the model's own files, then adjusted by effort.
struct InferencePlan {
    var temperature: Float
    var topP: Float
    var thinking: Bool
    var loops: Int?
    var maxTokens: Int

    static func make(for m: InstalledModel, effort: Effort, maxTokens: Int?) -> InferencePlan {
        var p = InferencePlan(
            temperature: Float(m.temperature ?? 0.7), topP: Float(m.topP ?? 0.9),
            thinking: false, loops: nil, maxTokens: maxTokens ?? 512)
        switch effort {
        case .fast:
            p.temperature = min(p.temperature, 0.3)
            if m.looped { p.loops = 2 }        // measured: 1 loop is unusable, 2 is the quality plateau
        case .balanced:
            if m.looped { p.loops = 2 }
        case .thorough:
            if m.looped { p.loops = 4 }
            if m.thinkingCapable { p.thinking = true; p.maxTokens = max(p.maxTokens, 1536) }
        }
        return p
    }
}

// MARK: - Errors

enum LoopLabIntentError: Error, CustomLocalizedStringResourceConvertible {
    case failed(String)
    case noModels
    case notInstalled(String)
    case timedOut(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .failed(let s): return "LoopLab: \(s)"
        case .noModels: return "LoopLab has no models yet. Open LoopLab › Models and download one."
        case .notInstalled(let s): return "\(s) is not in the LoopLab library. Download it in LoopLab › Models first."
        case .timedOut(let s): return "LoopLab: \(s) took too long. Turn on “Open LoopLab” in this action (iOS limits background work), or pick a smaller model."
        }
    }
}

// MARK: - shared plumbing

enum IntentRuntime {
    /// Model switching is serialised: chained actions never load two models at once.
    static func ensure(_ m: LocalModelEntity?, timeout: Double = 90) async throws -> InstalledModel {
        let chosen: InstalledModel
        if let m {
            guard let found = ModelStore.find(m.id) else { throw LoopLabIntentError.notInstalled(m.title) }
            chosen = found
        } else {
            guard let d = await LocalModelQuery().defaultResult(), let found = ModelStore.find(d.id) else { throw LoopLabIntentError.noModels }
            chosen = found
        }
        if await ModelHost.shared.modelId == chosen.id { return chosen }
        try await withTimeout(timeout, what: "Loading \(chosen.name)") {
            _ = try await ModelHost.shared.load(chosen.id, cacheLimitMB: 256)
        }
        return chosen
    }

    static func withTimeout<T: Sendable>(_ seconds: Double, what: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await body() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                throw LoopLabIntentError.timedOut(what)
            }
            let r = try await g.next()!
            g.cancelAll()
            return r
        }
    }

    static func stripThink(_ s: String) -> String {
        var t = s
        if let end = t.range(of: "</think>") { t = String(t[end.upperBound...]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Terminal + desktop record for actions run from Shortcuts.
    static func traced<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let started = !TermSink.shared.active
        if started { _ = TermSink.shared.begin("shortcut-\(name)") }
        defer { if started { TermSink.shared.end() } }
        TermSink.shared.line("$ shortcut \(name)")
        return try await body()
    }
}

// MARK: - Generate Text

struct GenerateTextIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Generate Text (On-Device)"
    static var description = IntentDescription("Runs a model on this iPhone and returns its reply as text. Nothing leaves the device. Settings left empty use the model's own defaults.")
    static var openAppWhenRun = false

    @Parameter(title: "Prompt") var prompt: String
    @Parameter(title: "Instructions", description: "Optional system instructions.") var instructions: String?
    @Parameter(title: "Model", description: "Leave empty to use the model already loaded.") var model: LocalModelEntity?
    @Parameter(title: "Effort", default: .balanced) var effort: Effort
    @Parameter(title: "Max Tokens", description: "Empty = 512 (1536 when thinking).") var maxTokens: Int?
    @Parameter(title: "Temperature", description: "Empty = the model's default.") var temperature: Double?
    @Parameter(title: "Seed", description: "Same seed + same input = same output.") var seed: Int?
    @Parameter(title: "Open LoopLab", description: "Run in the foreground: needed for large models and long outputs.", default: false) var foreground: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Generate text from \(\.$prompt)") {
            \.$model
            \.$instructions
            \.$effort
            \.$maxTokens
            \.$temperature
            \.$seed
            \.$foreground
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if foreground { try await requestToContinueInForeground("Opening LoopLab to run the model in the foreground.") }
        let text: String = try await IntentRuntime.traced("generate") {
            let m = try await IntentRuntime.ensure(model)
            var plan = InferencePlan.make(for: m, effort: effort, maxTokens: maxTokens)
            if let temperature { plan.temperature = Float(min(2, max(0, temperature))) }
            if let loops = plan.loops { await ModelHost.shared.setLoops(loops) }
            TermSink.shared.line("  model=\(m.name) effort=\(effort.rawValue) temp=\(plan.temperature) topP=\(plan.topP) think=\(plan.thinking) loops=\(plan.loops.map(String.init) ?? "-") max=\(plan.maxTokens)")
            let p = plan
            let r = try await IntentRuntime.withTimeout(foreground ? 600 : 25, what: "Generating") {
                try await ModelHost.shared.generate(
                    prompt: prompt, maxTokens: p.maxTokens, temperature: p.temperature,
                    system: instructions, thinking: p.thinking, topP: p.topP,
                    seed: seed.map { UInt64(max(0, $0)) }).value
            }
            return IntentRuntime.stripThink(r["text"] as? String ?? "")
        }
        return .result(value: text)
    }
}

// MARK: - Decide

struct DecideIntent: AppIntent {
    static var title: LocalizedStringResource = "Decide (On-Device)"
    static var description = IntentDescription("Picks the best option for a piece of text in one model pass — no text is generated. Returns the option, so you can branch on it with If.")
    static var openAppWhenRun = false

    @Parameter(title: "Input") var input: String
    @Parameter(title: "Question") var question: String
    @Parameter(title: "Options") var options: [String]
    @Parameter(title: "Model", description: "Leave empty to use the model already loaded.") var model: LocalModelEntity?
    @Parameter(title: "Minimum Confidence", description: "Below this, return the Fallback instead. 0 = always pick.", default: 0) var minConfidence: Double
    @Parameter(title: "Fallback", default: "unsure") var fallback: String

    static var parameterSummary: some ParameterSummary {
        Summary("Decide \(\.$question) for \(\.$input) from \(\.$options)") {
            \.$model
            \.$minConfidence
            \.$fallback
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard options.count >= 2 else { throw LoopLabIntentError.failed("give at least two options") }
        let answer: String = try await IntentRuntime.traced("decide") {
            _ = try await IntentRuntime.ensure(model)
            let r = try await IntentRuntime.withTimeout(20, what: "Deciding") {
                try await ModelHost.shared.decide(state: input, question: question, options: options).value
            }
            let ans = r["answer"] as? String ?? fallback
            let conf = (r["probabilities"] as? [String: Double])?[ans] ?? 0
            TermSink.shared.line(String(format: "  -> %@ (%.2f)", ans, conf))
            return conf >= minConfidence ? ans : fallback
        }
        return .result(value: answer)
    }
}

/// Same decision with every option's probability, for Shortcuts that need scores (Get Dictionary Value).
struct ScoreOptionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Score Options (On-Device)"
    static var description = IntentDescription("Returns a dictionary of option → probability for a piece of text, in one model pass.")
    static var openAppWhenRun = false

    @Parameter(title: "Input") var input: String
    @Parameter(title: "Question") var question: String
    @Parameter(title: "Options") var options: [String]
    @Parameter(title: "Model") var model: LocalModelEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Score \(\.$options) for \(\.$question) on \(\.$input)") { \.$model }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard options.count >= 2 else { throw LoopLabIntentError.failed("give at least two options") }
        let json: String = try await IntentRuntime.traced("score") {
            _ = try await IntentRuntime.ensure(model)
            let r = try await IntentRuntime.withTimeout(20, what: "Scoring") {
                try await ModelHost.shared.decide(state: input, question: question, options: options).value
            }
            let probs = r["probabilities"] as? [String: Double] ?? [:]
            let rounded = probs.mapValues { (($0 * 1000).rounded()) / 1000 }
            let data = (try? JSONSerialization.data(withJSONObject: rounded, options: [.sortedKeys])) ?? Data("{}".utf8)
            // JSON text: Shortcuts turns it into a Dictionary with "Get Dictionary from Input".
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return .result(value: json)
    }
}

// MARK: - Model management actions (for chains)

struct LoadModelIntent: AppIntent {
    static var title: LocalizedStringResource = "Load Model (On-Device)"
    static var description = IntentDescription("Loads a model into memory ahead of time, so the next actions start instantly.")
    static var openAppWhenRun = false
    @Parameter(title: "Model") var model: LocalModelEntity
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let name: String = try await IntentRuntime.traced("load") {
            try await IntentRuntime.ensure(model, timeout: 120).name
        }
        return .result(value: name)
    }
}

struct UnloadModelIntent: AppIntent {
    static var title: LocalizedStringResource = "Unload Model (On-Device)"
    static var description = IntentDescription("Frees the memory used by the loaded model.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await ModelHost.shared.unload()
        return .result()
    }
}

struct ListModelsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get On-Device Models"
    static var description = IntentDescription("Lists the models in the LoopLab library.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult & ReturnsValue<[LocalModelEntity]> {
        .result(value: try await LocalModelQuery().suggestedEntities())
    }
}

// MARK: - App Shortcuts (Siri phrases + Spotlight)

struct LoopLabShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GenerateTextIntent(),
                    phrases: ["Generate text with \(.applicationName)", "Ask \(.applicationName)"],
                    shortTitle: "Generate Text", systemImageName: "text.bubble")
        AppShortcut(intent: DecideIntent(),
                    phrases: ["Decide with \(.applicationName)"],
                    shortTitle: "Decide", systemImageName: "arrow.triangle.branch")
        AppShortcut(intent: LoadModelIntent(),
                    phrases: ["Load a model in \(.applicationName)"],
                    shortTitle: "Load Model", systemImageName: "cube.box")
    }
}
