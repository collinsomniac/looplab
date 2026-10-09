import AppIntents
import Foundation

// Shortcuts surface for LoopLab: the on-device engine as two building blocks.
//  - Generate Text: prompt in, text out (the "Apple Intelligence model" equivalent).
//  - Decide: text + options in, one option out (Jev/Clef-style; Shortcuts branches on it with If).
//
// Experiment flag: these do NOT force the app open. Whether Metal work is allowed while the app is
// launched in the background by Shortcuts is exactly what we are measuring; a failure is reported
// as a readable error so the user can flip "Open LoopLab" on instead.

enum LoopLabIntentError: Error, CustomLocalizedStringResourceConvertible {
    case failed(String)
    var localizedStringResource: LocalizedStringResource {
        switch self { case .failed(let s): return "LoopLab: \(s)" }
    }
}

private func ensureModel(_ preset: String) async throws {
    let current = await ModelHost.shared.modelId
    let wanted = ModelHost.presets[preset] ?? preset
    if current != wanted {
        _ = try await ModelHost.shared.load(preset, cacheLimitMB: 256)
    }
}

struct GenerateTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Generate Text (On-Device)"
    static var description = IntentDescription("Runs a local model on this iPhone and returns its reply as text. Nothing leaves the device.")
    static var openAppWhenRun = false

    @Parameter(title: "Prompt") var prompt: String
    @Parameter(title: "Instructions", description: "Optional system instructions.") var instructions: String?
    @Parameter(title: "Model", default: "qwen2.5-coder-1.5b") var model: String
    @Parameter(title: "Max Tokens", default: 256) var maxTokens: Int
    @Parameter(title: "Think First", default: false) var thinking: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Generate text from \(\.$prompt)") {
            \.$instructions
            \.$model
            \.$maxTokens
            \.$thinking
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        do {
            try await ensureModel(model)
            let r = try await ModelHost.shared.generate(
                prompt: prompt, maxTokens: maxTokens, temperature: 0,
                system: instructions, thinking: thinking).value
            var text = r["text"] as? String ?? ""
            if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
            return .result(value: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw LoopLabIntentError.failed(error.localizedDescription)
        }
    }
}

struct DecideIntent: AppIntent {
    static var title: LocalizedStringResource = "Decide (On-Device)"
    static var description = IntentDescription("Picks the best option for a piece of text in a single model pass. Returns the option, so you can branch on it with If.")
    static var openAppWhenRun = false

    @Parameter(title: "Input") var input: String
    @Parameter(title: "Question") var question: String
    @Parameter(title: "Options") var options: [String]
    @Parameter(title: "Model", default: "qwen2.5-coder-1.5b") var model: String

    static var parameterSummary: some ParameterSummary {
        Summary("Decide \(\.$question) for \(\.$input) from \(\.$options)") {
            \.$model
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard options.count >= 2 else { throw LoopLabIntentError.failed("give at least two options") }
        do {
            try await ensureModel(model)
            let r = try await ModelHost.shared.decide(state: input, question: question, options: options).value
            return .result(value: r["answer"] as? String ?? "")
        } catch {
            throw LoopLabIntentError.failed(error.localizedDescription)
        }
    }
}

struct LoopLabShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GenerateTextIntent(),
                    phrases: ["Generate text with \(.applicationName)"],
                    shortTitle: "Generate Text", systemImageName: "text.bubble")
        AppShortcut(intent: DecideIntent(),
                    phrases: ["Decide with \(.applicationName)"],
                    shortTitle: "Decide", systemImageName: "arrow.triangle.branch")
    }
}
