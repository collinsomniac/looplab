import Foundation
import SwiftUI
import UIKit

/// Single source of truth for the UI. Everything the screens show comes from here, so surfaces update
/// themselves instead of needing a button press to reveal state.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // identity / build
    @Published var version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    @Published var build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    @Published var reinstallHint: String = ""

    // control server
    @Published var controlRunning = false
    @Published var controlHosts: [String] = []
    @Published var controlRequests = 0
    @Published var token = ""

    // device
    @Published var device: [String: Any] = [:]
    @Published var entitlements: [String: String] = [:]
    @Published var memoryAvailable = 0
    @Published var thermal = "?"
    @Published var metalName = "?"
    @Published var metalWorkingSet = 0
    @Published var metalFamilies: [String] = []

    // model
    @Published var modelPresets: [String: String] = [:]
    @Published var configuredModel = "qwen3-0.6b"
    @Published var modelState = "idle"
    @Published var modelLoadProgress: Double = 0
    @Published var loadedModel: String?
    @Published var modelError: String?

    // generation config (the knobs we care about for research)
    @Published var maxTokens: Double = 256
    @Published var temperature: Double = 0
    @Published var systemPrompt = ""

    // chat
    @Published var messages: [(role: String, text: String)] = []
    @Published var streaming = ""
    @Published var generating = false
    @Published var lastTPS: Double = 0
    @Published var liveTPS: Double = 0
    @Published var liveTokens: Int = 0
    @Published var lastTTFT: Double = 0
    @Published var lastPromptTokens = 0
    @Published var lastGenTokens = 0
    @Published var genStart = Date()

    // queue
    @Published var queueURL = UserDefaults.standard.string(forKey: "queueBase") ?? "https://desktop-3rsf4r5.tailce70fb.ts.net:8443"
    @Published var queueToken = UserDefaults.standard.string(forKey: "queueToken") ?? ""
    @Published var queueReachable = false
    @Published var queueError: String?
    @Published var queueItems: [(id: String, label: String, steps: Int, state: String)] = []
    @Published var queueRunning = false
    @Published var queueCurrentJob: String?
    @Published var queueStepIndex = 0
    @Published var queueStepTotal = 0
    @Published var jobLog: [String] = []
    @Published var lastRunFinished = false
    @Published var visibleTab = "chat"
    @Published var queueRuns: [String: String] = [:]   // job id -> terminal run id
    var queueSpecs: [String: [[String: Any]]] = [:]

    // tests
    @Published var testResults: [(name: String, detail: String, ok: Bool)] = []
    @Published var testRunning = false

    @Published var logLines: [String] = []

    private var timer: Timer?
    private var refreshTick = 0

    init() {
        token = ControlServer.shared.token
        modelPresets = ModelHost.presets
        refreshLocal()
        Library.shared.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLocal() }
        }
    }

    func refreshLocal() {
        controlRunning = ControlServer.shared.running
        controlHosts = ControlServer.shared.boundHosts
        controlRequests = ControlServer.shared.requests
        logLines = Array(Log.shared.all().suffix(60))
        thermal = DeviceProbe.thermalString()
        memoryAvailable = DeviceProbe.availableMemory()

        Task { await refreshModel() }
        refreshTick += 1
        if refreshTick % 10 != 1 { return }   // full probe every ~15 s; thermal/memory above stay live
        let d = DeviceProbe.snapshot()
        device = d
        entitlements = (d["entitlements"] as? [String: String]) ?? [:]
        if let m = d["metal"] as? [String: Any] {
            metalName = m["name"] as? String ?? "?"
            metalWorkingSet = m["recommendedMaxWorkingSetSize"] as? Int ?? 0
            metalFamilies = m["families"] as? [String] ?? []
        }
        if !entitlements.keys.contains("com.apple.developer.kernel.increased-memory-limit"), reinstallHint.isEmpty {
            reinstallHint = "Memory limit entitlement is NOT granted (≈3.5 GB). Install this build from the desktop with iloader to raise it to ≈6 GB."
        }
    }

    func refreshModel() async {
        let s = await ModelHost.shared.status().value
        modelState = s["state"] as? String ?? "idle"
        modelLoadProgress = s["progress"] as? Double ?? 0
        loadedModel = s["model"] as? String
        modelError = s["error"] as? String
    }

    // MARK: actions

    func load(_ id: String) {
        configuredModel = id
        modelError = nil
        Task {
            do { _ = try await ModelHost.shared.load(id) }
            catch { modelError = "\(error)" }
            await refreshModel()
        }
    }

    func unload() { Task { await ModelHost.shared.unload(); await ModelHost.shared.resetChat(); await refreshModel() } }

    /// Start a fresh conversation: drops the KV cache as well as the transcript.
    func newChat() {
        messages.removeAll(); streaming = ""
        Task { await ModelHost.shared.resetChat() }
    }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !generating else { return }
        messages.append(("you", prompt))
        generating = true
        streaming = ""
        genStart = Date()
        lastTPS = 0; lastTTFT = 0; liveTPS = 0; liveTokens = 0
        Task {
            do {
                // Chat uses the persistent session so turn 2+ reuses the prompt cache instead of
                // prefilling the whole history again.
                let r = try await ModelHost.shared.chat(
                    prompt: prompt, system: systemPrompt.isEmpty ? nil : systemPrompt,
                    maxTokens: Int(maxTokens), temperature: Float(temperature), thinking: false,
                    onFirstToken: { [weak self] in
                        Task { @MainActor in self?.lastTTFT = Date().timeIntervalSince(self?.genStart ?? Date()) * 1000 }
                    }, onChunk: { [weak self] piece in
                        Task { @MainActor in
                            guard let self else { return }
                            self.streaming += piece
                            self.liveTokens += 1
                            let dt = Date().timeIntervalSince(self.genStart)
                            if dt > 0.5 { self.liveTPS = Double(self.liveTokens) / dt }
                        }
                    }).value
                let info = r["mlxInfo"] as? [String: Any] ?? [:]
                lastTPS = info["tokensPerSecond"] as? Double ?? 0
                lastPromptTokens = info["promptTokens"] as? Int ?? 0
                lastGenTokens = info["generatedTokens"] as? Int ?? 0
                if lastTTFT == 0 { lastTTFT = r["ttftMs"] as? Double ?? 0 }
                let text = r["text"] as? String ?? ""
                messages.append(("model", text))
                streaming = ""
                pushToDesktop(["op": "generate", "prompt": prompt, "text": text, "mlxInfo": info,
                               "ttftMs": r["ttftMs"] ?? 0, "thermalAfter": r["thermalAfter"] ?? "",
                               "mlxMemory": r["mlxMemory"] ?? [:], "source": "chat"])
            } catch {
                messages.append(("error", "\(error)"))
            }
            generating = false
        }
    }

    // MARK: queue

    func queueRequest(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: queueURL + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 30
        if !queueToken.isEmpty { r.setValue(queueToken, forHTTPHeaderField: "X-Token") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: ControlServer.sanitize(body))
        }
        return r
    }

    func saveQueueSettings() {
        UserDefaults.standard.set(queueURL, forKey: "queueBase")
        UserDefaults.standard.set(queueToken, forKey: "queueToken")
    }

    func checkDesktop() {
        queueError = nil
        Task {
            guard let req = queueRequest("/health") else { queueError = "bad URL"; return }
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if obj["ok"] as? Bool == true {
                    queueReachable = true
                    queueItems = (obj["queuedIds"] as? [String] ?? []).map { ($0, "", 0, "pending") }
                    jobLog.append("desktop OK · queued \(obj["queued"] ?? 0) · results \(obj["resultLines"] ?? 0)")
                } else { queueError = "unexpected reply: \(obj)" }
            } catch { queueReachable = false; queueError = "\(error)" }
        }
    }

    func refreshQueue() {
        queueError = nil
        Task {
            guard let req = queueRequest("/queue") else { queueError = "bad URL"; return }
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let jobs = obj["jobs"] as? [[String: Any]] ?? []
                queueReachable = true
                queueItems = jobs.map { j in
                    (j["id"] as? String ?? "?", j["label"] as? String ?? "", (j["steps"] as? [Any])?.count ?? 0, "pending")
                }
                for j in jobs { if let id = j["id"] as? String { queueSpecs[id] = j["steps"] as? [[String: Any]] ?? [] } }
                jobLog.append("queue: \(queueItems.count) item(s) pending")
            } catch { queueReachable = false; queueError = "\(error)" }
        }
    }

    func runQueue() {
        guard !queueRunning else { return }
        queueRunning = true
        lastRunFinished = false
        queueError = nil
        jobLog.append("run requested at \(Self.clock())")
        Task {
            var processed = 0
            while true {
                guard let req = queueRequest("/queue"), let (data, _) = try? await URLSession.shared.data(for: req),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let jobs = obj["jobs"] as? [[String: Any]], !jobs.isEmpty else {
                    break
                }
                guard let job = jobs.first else { break }
                let id = job["id"] as? String ?? "unnamed"
                let steps = job["steps"] as? [[String: Any]] ?? []
                queueCurrentJob = id
                queueStepTotal = steps.count
                queueStepIndex = 0
                queueItems = queueItems.map { $0.id == id ? ($0.id, $0.label, $0.steps, "running") : $0 }
                let run = TermSink.shared.begin(id)
                queueRuns[id] = run
                let term = TermSink.shared
                term.line("# \(run)")
                term.line("# \(job["label"] as? String ?? "")")
                term.line("# device \(DeviceProbe.snapshot()["machine"] ?? "?") · build \(version) (\(build)) · thermal \(DeviceProbe.thermalString())\n")
                let jobStart = Date()
                for (i, step) in steps.enumerated() {
                    queueStepIndex = i + 1
                    let t0 = Date()
                    term.line(String(format: "[%@ %3d/%d] $ ", Self.clock(), i + 1, steps.count) + Terminal.command(step))
                    var out: [String: Any] = ["job": id, "i": i, "op": step["op"] as? String ?? "?", "run": run]
                    if let e = await JobRunnerBridge.run(step) { out.merge(e) { a, _ in a } }
                    out["ms"] = Int(Date().timeIntervalSince(t0) * 1000)
                    out["thermal"] = DeviceProbe.thermalString()
                    out["tab"] = visibleTab
                    out["echo"] = TermSink.shared.echoTokens
                    out["battery"] = UIDevice.current.batteryLevel
                    for l in Self.resultLines(out) { term.line("  " + l) }
                    term.line(String(format: "  (%.2f s · %@)", Date().timeIntervalSince(t0), out["thermal"] as? String ?? ""))
                    sendToDesktop("/results", out)
                }
                term.line(String(format: "\n# done in %.1f s", Date().timeIntervalSince(jobStart)))
                TermSink.shared.end()
                sendToDesktop("/results", ["job": id, "op": "job_end", "steps": steps.count])
                sendToDesktop("/queue/done", ["id": id, "run": queueRuns[id] ?? ""])
                queueItems = queueItems.map { $0.id == id ? ($0.id, $0.label, $0.steps, "done") : $0 }
                jobLog.append("✓ \(id) done")
                processed += 1
                if processed > 20 { break }
            }
            queueRunning = false
            queueCurrentJob = nil
            lastRunFinished = true
            jobLog.append("queue drained at \(Self.clock())")
        }
    }

    /// The interesting part of a step result, as terminal lines (no wall of JSON).
    static func resultLines(_ o: [String: Any]) -> [String] {
        if let e = o["error"] { return ["error: \(e)"] }
        func f(_ v: Any?, _ d: Int = 1) -> String { String(format: "%.\(d)f", (v as? Double) ?? Double((v as? Int) ?? 0)) }
        switch o["op"] as? String ?? "" {
        case "generate":
            let i = o["mlxInfo"] as? [String: Any] ?? [:]
            return ["\(i["generatedTokens"] ?? 0) tok · \(f(i["tokensPerSecond"])) tok/s · ttft \(f(o["ttftMs"], 0)) ms · prompt \(i["promptTokens"] ?? 0) tok"]
        case "decide":
            let p = (o["probabilities"] as? [String: Double] ?? [:]).sorted { $0.value > $1.value }
                .map { "\($0.key)=\(String(format: "%.3f", $0.value))" }.joined(separator: " ")
            return ["-> \(o["answer"] ?? "?")   [\(p)]  \(f(o["totalMs"], 0)) ms · \(o["promptTokens"] ?? 0) tok"]
        case "load":
            return ["\(o["state"] ?? "?") · \(o["params"] ?? "?") params · \(f(o["loadSeconds"], 2)) s"]
        case "bench_decode":
            let rs = (o["runs"] as? [[String: Any]] ?? []).map { f($0["tokensPerSecond"]) }.joined(separator: ", ")
            return ["tok/s runs [\(rs)] median \(f(o["median"]))"]
        case "bench_spec":
            return ["plain \(f(o["plainTps"])) -> spec \(f(o["specTps"])) tok/s  x\(f(o["speedup"], 2))  identical=\(o["identicalOutput"] ?? "?")"]
        case "read_bench":
            return ["seq \(f(o["seqGBps"], 2)) GB/s · random 4MB \(f(o["randomGBps"], 2)) GB/s · p50 \(f(o["randomMsP50"], 1)) ms p95 \(f(o["randomMsP95"], 1)) ms"]
        case "probe":
            return ["available \(String(format: "%.2f", Double(bytes(o["availableToProcess"])) / 1_073_741_824)) GB · thermal \(o["thermal"] ?? "?")"]
        default:
            let skip: Set<String> = ["job", "i", "op", "run", "ms", "thermal", "text", "plainText", "specText"]
            let d = o.filter { !skip.contains($0.key) }
            let data = (try? JSONSerialization.data(withJSONObject: ControlServer.sanitize(d), options: [.sortedKeys])) ?? Data()
            let s = String(data: data, encoding: .utf8) ?? ""
            return [s.count > 600 ? String(s.prefix(600)) + "…" : s]
        }
    }

    static func clock() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date()) }

    static func summarize(_ out: [String: Any]) -> String {
        switch out["op"] as? String ?? "" {
        case "bench_metal":
            let rs = out["results"] as? [[String: Any]] ?? []
            return rs.map { "B\($0["batch"] ?? 0)=\(String(format: "%.1f", $0["gbPerS"] as? Double ?? 0))GB/s" }.joined(separator: " ")
        case "generate":
            let i = out["mlxInfo"] as? [String: Any] ?? [:]
            return String(format: "%.1f tok/s · %d tok · ttft %.0fms", i["tokensPerSecond"] as? Double ?? 0,
                          i["generatedTokens"] as? Int ?? 0, out["ttftMs"] as? Double ?? 0)
        case "probe":
            return String(format: "avail %.2f GB", (out["availableToProcess"] as? Double ?? 0) / 1073741824.0)
        case "write_test":
            return "\(out["allocated"] ?? false) pages=\(out["pagesTouched"] ?? 0)"
        default: return ""
        }
    }

    func sendToDesktop(_ path: String, _ body: [String: Any]) {
        guard let req = queueRequest(path, method: "POST", body: body) else { return }
        URLSession.shared.dataTask(with: req).resume()
    }

    func pushToDesktop(_ body: [String: Any]) { sendToDesktop("/results", body) }

    // MARK: tests

    func runTest(_ name: String) {
        guard !testRunning else { return }
        testRunning = true
        Task {
            let t0 = Date()
            var ok = true
            var detail = ""
            switch name {
            case "metal":
                let r = try? MetalBench.run(kernels: ["thread", "simd"], batches: [1, 2, 4, 8], reps: 25)
                let rs = (r?["results"] as? [[String: Any]]) ?? []
                ok = rs.allSatisfy { r in
                    if let b = r["ok"] as? Bool { return b }
                    if let i = r["ok"] as? Int { return i != 0 }
                    return false
                }
                detail = rs.map { "\($0["kernel"] ?? "") B\($0["batch"] ?? 0): \(String(format: "%.1f", $0["gbPerS"] as? Double ?? 0)) GB/s" }.joined(separator: " · ")
                if let r { pushToDesktop(["op": "bench_metal", "results": r["results"] ?? [], "source": "tests"]) }
            case "blit":
                let r = MetalBench.blitBandwidth(mib: 512)
                detail = String(format: "%.1f GB/s (read+write), %.2f ms", r["readPlusWriteGBs"] as? Double ?? 0, r["ms"] as? Double ?? 0)
                pushToDesktop(["op": "bench_blit", "result": r, "source": "tests"])
            case "memory":
                var parts: [String] = []
                for mb in [512, 1024, 1536, 2048] {
                    let r = try? await JobRunner.shared.execute(["op": "write_test", "bytes": mb * 1024 * 1024])
                    let okA = r?["allocated"] as? Bool ?? false
                    parts.append("\(mb)MB \(okA ? "ok" : "FAILED")")
                    if let r { pushToDesktop(["op": "write_test", "bytes": mb * 1024 * 1024, "result": r, "source": "tests"]) }
                    if !okA { break }
                }
                detail = parts.joined(separator: " · ")
            default: break
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            testResults.insert((name: name, detail: "\(detail)  [\(ms) ms]", ok: ok), at: 0)
            if testResults.count > 12 { testResults.removeLast() }
            testRunning = false
            _ = ok
        }
    }
}
