import SwiftUI
import UIKit

@main
struct LoopLabApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in URLActions.handle(url) }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        ControlServer.shared.handler = { m, p, q, b in await API.handle(m, p, q, b) }
        ControlServer.shared.start()
        Log.shared.add("launch: available=\(DeviceProbe.availableMemory() / 1_048_576) MB, thermal=\(DeviceProbe.thermalString())")
        return true
    }
}

/// looplab://load?model=qwen3-0.6b · looplab://generate?prompt=hi · looplab://bench
enum URLActions {
    static func handle(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let host = url.host ?? ""
        Log.shared.add("url action: \(host) \(q)")
        Task {
            switch host {
            case "load": _ = await API.handle("POST", "/load", q, ["model": q["model"] ?? "qwen3-0.6b"])
            case "generate": _ = await API.handle("POST", "/generate", q, ["prompt": q["prompt"] ?? "Hello"])
            case "bench": _ = await API.handle("POST", "/bench/metal", q, [:])
            case "server": ControlServer.shared.restart()
            default: break
            }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            ChatView().tabItem { Label("Run", systemImage: "bolt") }
            DeviceView().tabItem { Label("Device", systemImage: "cpu") }
            JobsView().tabItem { Label("Jobs", systemImage: "square.stack.3d.up") }
            ControlView().tabItem { Label("Control", systemImage: "antenna.radiowaves.left.and.right") }
        }
    }
}

struct ChatView: View {
    @State private var model = "qwen3-0.6b"
    @State private var prompt = "Explain what a looped transformer is in two sentences."
    @State private var output = ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    Picker("Preset", selection: $model) {
                        ForEach(ModelHost.presets.keys.sorted(), id: \.self) { Text($0) }
                    }
                    TextField("or any mlx-community repo id", text: $model).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button(busy ? "Working…" : "Load") { run { _ = await API.handle("POST", "/load", [:], ["model": model]) } }.disabled(busy)
                }
                Section("Prompt") {
                    TextEditor(text: $prompt).frame(minHeight: 80)
                    Button(busy ? "Generating…" : "Generate") {
                        run {
                            let (_, r) = await API.handle("POST", "/generate", [:], ["prompt": prompt])
                            if let d = r as? [String: Any] {
                                output = d["text"] as? String ?? "\(d)"
                                let info = d["mlxInfo"] as? [String: Any] ?? [:]
                                status = String(format: "%.1f tok/s · TTFT %.0f ms · %@", info["tokensPerSecond"] as? Double ?? 0, d["ttftMs"] as? Double ?? 0, d["thermalAfter"] as? String ?? "")
                            }
                        }
                    }.disabled(busy)
                }
                if !status.isEmpty { Section("Measured") { Text(status).font(.caption.monospaced()) } }
                if !output.isEmpty { Section("Output") { Text(output).textSelection(.enabled) } }
            }
            .navigationTitle("LoopLab")
            .task { await refresh() }
        }
    }

    func run(_ f: @escaping () async -> Void) { busy = true; Task { await f(); await refresh(); busy = false } }
    func refresh() async {
        let s = await ModelHost.shared.status().value
        status = status.isEmpty ? "\(s["state"] ?? "") \(s["model"] ?? "")" : status
    }
}

struct DeviceView: View {
    @State private var json = ""
    @State private var bench = ""
    var body: some View {
        NavigationStack {
            List {
                Section { Button("Refresh probe") { load() }; Button("Run Metal bench") { runBench() } }
                if !bench.isEmpty { Section("Metal bench") { Text(bench).font(.caption2.monospaced()).textSelection(.enabled) } }
                Section("Device") { Text(json).font(.caption2.monospaced()).textSelection(.enabled) }
            }
            .navigationTitle("Device")
            .onAppear { load() }
        }
    }
    func load() {
        let d = DeviceProbe.snapshot()
        json = String(data: (try? JSONSerialization.data(withJSONObject: ControlServer.sanitize(d), options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
    }
    func runBench() {
        bench = "running…"
        Task.detached {
            let r = (try? MetalBench.run()) ?? ["error": "failed"]
            let s = String(data: (try? JSONSerialization.data(withJSONObject: ControlServer.sanitize(r), options: [.prettyPrinted])) ?? Data(), encoding: .utf8) ?? ""
            await MainActor.run { bench = s }
        }
    }
}

struct JobsView: View {
    @State private var jobs: [[String: Any]] = []
    @State private var note = ""
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section("Reach this app") {
                    LabeledContent("Loopback", value: "http://127.0.0.1:\(ControlServer.shared.port)")
                    LabeledContent("Tailnet", value: NetInfo.tailscaleIPv4().map { "http://\($0):\(ControlServer.shared.port)" } ?? "no tailnet address")
                    Button("Copy tailnet URL") {
                        if let ts = NetInfo.tailscaleIPv4() { UIPasteboard.general.string = "http://\(ts):\(ControlServer.shared.port)" }
                    }
                    Text("Keeps your VPN setting untouched: this listens on the Tailscale address as well as loopback.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("Quick batteries") {
                    Button("Substrate: metal + blit + memory") { runQuick("substrate") }
                    Button("Model smoke test (qwen3-0.6b)") { runQuick("smoke") }
                    Button("Loop-count sweep (needs a loaded model)") { runQuick("loops") }
                }
                if !note.isEmpty { Section("Status") { Text(note).font(.caption.monospaced()) } }
                Section("Jobs") {
                    ForEach(Array(jobs.enumerated()), id: \.offset) { _, j in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(j["id"] ?? "")  \(j["state"] ?? "")").font(.caption.monospaced())
                            Text("\(j["label"] ?? "") · steps \(j["steps"] ?? 0)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Jobs")
            .onReceive(timer) { _ in jobs = JobRunner.shared.list() }
            .onAppear { jobs = JobRunner.shared.list() }
        }
    }

    func runQuick(_ kind: String) {
        let spec: [String: Any]
        switch kind {
        case "substrate":
            spec = ["label": "substrate", "steps": [
                ["op": "probe"],
                ["op": "bench_metal", "batches": [1, 2, 4, 8], "reps": 20],
                ["op": "bench_blit", "mib": 256],
                ["op": "write_test", "bytes": 402653184],
            ]]
        case "smoke":
            spec = ["label": "smoke", "steps": [
                ["op": "load", "model": "qwen3-0.6b"],
                ["op": "generate", "prompt": "Explain what a looped transformer is in two sentences.", "maxTokens": 64],
                ["op": "generate", "prompt": "Write a Python function that returns the nth Fibonacci number.", "maxTokens": 96],
            ]]
        default:
            spec = ["label": "loops", "steps": [
                ["op": "generate", "prompt": "Compute 17 + 26 step by step.", "maxTokens": 48],
                ["op": "sleep", "seconds": 1],
                ["op": "generate", "prompt": "Compute 17 + 26 step by step.", "maxTokens": 48],
            ]]
        }
        let r = JobRunner.shared.start(spec: spec)
        note = "started \(r["id"] ?? r)"
        jobs = JobRunner.shared.list()
    }
}

struct ControlView: View {
    @State private var tick = 0
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        NavigationStack {
            List {
                Section("Loopback control server") {
                    LabeledContent("Address", value: "http://127.0.0.1:\(ControlServer.shared.port)")
                    LabeledContent("Running", value: ControlServer.shared.running ? "yes" : "no")
                    LabeledContent("Requests", value: "\(ControlServer.shared.requests)")
                    LabeledContent("Token", value: ControlServer.shared.token).textSelection(.enabled)
                    Button("Copy token") { UIPasteboard.general.string = ControlServer.shared.token }
                    Button("Restart server") { ControlServer.shared.restart() }
                }
                Section("Log") {
                    ForEach(Array(Log.shared.all().suffix(40).reversed().enumerated()), id: \.offset) { _, l in
                        Text(l).font(.caption2.monospaced())
                    }
                }
            }
            .navigationTitle("Control")
            .onReceive(timer) { _ in tick += 1 }
            .id(tick)
        }
    }
}
