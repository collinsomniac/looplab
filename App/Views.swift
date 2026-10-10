import SwiftUI
import UIKit

// MARK: - shared bits

struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary) }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct KV: View {
    let k: String; let v: String; var mono = true
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).font(.subheadline)
            Spacer(minLength: 8)
            Text(v).font(mono ? .subheadline.monospaced() : .subheadline).multilineTextAlignment(.trailing)
        }
    }
}

/// Numbers arrive as Int / UInt64 / Double / NSNumber depending on how the probe built them;
/// normalise before formatting (UInt64 silently failed an `as? Int` cast, which showed 0.00 GB).
func bytes(_ any: Any?) -> Int {
    switch any {
    case let v as Int: return v
    case let v as UInt64: return Int(clamping: v)
    case let v as Int64: return Int(clamping: v)
    case let v as UInt: return Int(clamping: v)
    case let v as Double: return Int(v)
    case let v as NSNumber: return v.intValue
    default: return 0
    }
}
func gb(_ b: Int) -> String { String(format: "%.2f GB", Double(b) / 1_073_741_824) }
func mb(_ b: Int) -> String { String(format: "%.0f MB", Double(b) / 1_048_576) }
func gbAny(_ v: Any?) -> String { gb(bytes(v)) }

// MARK: - Chat

struct ChatView: View {
    @ObservedObject var app = AppState.shared
    @State private var input = ""
    @State private var showConfig = true
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modelBar
                Divider()
                if showConfig { configBar; Divider() }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if app.messages.isEmpty && app.streaming.isEmpty {
                                Text("Load a model, then ask something.")
                                    .font(.footnote).foregroundStyle(.secondary).padding(.top, 20)
                            }
                            ForEach(Array(app.messages.enumerated()), id: \.offset) { _, m in
                                bubble(m.role, m.text)
                            }
                            if !app.streaming.isEmpty { bubble("model", app.streaming, live: true) }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: app.streaming) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: app.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                Divider()
                metricsBar
                inputBar
            }
            .navigationTitle("LoopLab")
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { showConfig.toggle() } label: { Image(systemName: showConfig ? "slider.horizontal.3" : "slider.horizontal.below.rectangle") }
            } }
        }
    }

    private var modelBar: some View {
        VStack(spacing: 6) {
            HStack {
                Menu {
                    Section("Installed") {
                        ForEach(ModelStore.installed()) { m in
                            Button("\(m.name)  ·  \(m.sizeText)") { app.load(m.id) }
                        }
                    }
                    Section("Download & load") {
                        ForEach(app.modelPresets.keys.sorted(), id: \.self) { key in
                            if !ModelStore.isInstalled(app.modelPresets[key] ?? key) {
                                Button("\(key)") { app.load(key) }
                            }
                        }
                    }
                } label: {
                    Label(app.loadedModel ?? app.configuredModel, systemImage: "cube.box")
                        .font(.subheadline).lineLimit(1)
                }
                Spacer()
                if app.modelState == "downloading" || app.modelState == "loading" {
                    ProgressView(value: app.modelState == "downloading" ? app.modelLoadProgress : 0.5)
                        .frame(width: 90)
                    Text(app.modelState).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(app.loadedModel != nil ? "loaded" : "not loaded")
                        .font(.caption2).foregroundStyle(app.loadedModel != nil ? .green : .secondary)
                    Button(app.loadedModel != nil ? "Unload" : "Load") {
                        app.loadedModel != nil ? app.unload() : app.load(app.configuredModel)
                    }.font(.caption).buttonStyle(.bordered)
                }
            }
            if let e = app.modelError { Text(e).font(.caption2).foregroundStyle(.red).lineLimit(3) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var configBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("system prompt (optional)", text: $app.systemPrompt, axis: .vertical)
                .font(.footnote).lineLimit(1...3).textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("max tokens \(Int(app.maxTokens))").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $app.maxTokens, in: 16...2048, step: 16).frame(width: 150)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "temperature %.2f", app.temperature)).font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $app.temperature, in: 0...1.5, step: 0.05).frame(width: 150)
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var metricsBar: some View {
        HStack(spacing: 14) {
            Label(String(format: "%.1f tok/s", app.generating ? app.liveTPS : app.lastTPS), systemImage: "speedometer")
                .font(.caption.monospaced())
                .foregroundStyle(app.generating ? .orange : .primary)
            Label(String(format: "ttft %.0f ms", app.lastTTFT), systemImage: "timer").font(.caption.monospaced())
            Label("\(app.lastGenTokens) tok", systemImage: "text.alignleft").font(.caption.monospaced())
            Spacer()
            Label(mb(app.memoryAvailable), systemImage: "memorychip").font(.caption.monospaced())
            Text(app.thermal).font(.caption2).foregroundStyle(app.thermal == "nominal" ? .green : .orange)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $input, axis: .vertical)
                .lineLimit(1...4).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { send() }
            Button(action: send) {
                if app.generating { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
            }
            .disabled(app.generating || app.loadedModel == nil || input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func send() {
        let t = input; input = ""
        app.send(t)
    }

    @ViewBuilder private func bubble(_ role: String, _ text: String, live: Bool = false) -> some View {
        HStack {
            if role == "you" { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(role == "you" ? "You" : role == "error" ? "Error" : "Model")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(text.isEmpty ? "…" : text)
                    .font(.callout)
                    .foregroundStyle(role == "error" ? Color.red : Color.primary)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(role == "you" ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12))
            if role != "you" { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Queue

struct QueueView: View {
    @ObservedObject var app = AppState.shared
    @ObservedObject var term = Terminal.shared
    @State private var showSettings = false
    @State private var follow = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                runStrip
                terminal
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "circle.fill").font(.system(size: 9))
                            .foregroundStyle(app.queueReachable ? .green : (app.queueError == nil ? .orange : .red))
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { app.refreshQueue(); Task { await term.loadHistory() } } label: { Image(systemName: "arrow.clockwise") }
                    Button { UIPasteboard.general.string = term.shown } label: { Image(systemName: "doc.on.doc") }
                }
            }
            .sheet(isPresented: $showSettings) { settings }
            .onAppear {
                if !app.lastRunFinished { app.refreshQueue() }
                Task { await term.loadHistory() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { app.runQueue() } label: {
                Label(app.queueRunning ? "Running" : "Run queue", systemImage: app.queueRunning ? "hourglass" : "play.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent).disabled(app.queueRunning)
            if app.queueRunning {
                ProgressView(value: Double(app.queueStepIndex), total: Double(max(app.queueStepTotal, 1))).frame(maxWidth: 120)
                Text("\(app.queueStepIndex)/\(app.queueStepTotal)").font(.caption.monospaced())
            }
            Spacer()
            Toggle(isOn: $follow) { Image(systemName: "arrow.down.to.line") }.toggleStyle(.button).font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Every run as a tab: pending jobs, this session's runs, and runs stored on the desktop.
    private var runStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(app.queueItems.filter { $0.state == "pending" }, id: \.id) { item in
                    chip(item.id, sub: "queued · \(item.steps)", key: "pending:\(item.id)", color: .orange) {
                        term.showPending(item.id, steps: app.queueSpecs[item.id] ?? [])
                    }
                }
                ForEach(term.sessionRuns.reversed(), id: \.self) { r in
                    chip(Self.short(r), sub: r == TermSinkSnapshot.current ? "live" : "this session", key: r,
                         color: r == TermSinkSnapshot.current ? .green : .blue) { term.select(r) }
                }
                ForEach(term.desktopRuns.filter { !term.sessionRuns.contains($0) }.prefix(30), id: \.self) { r in
                    chip(Self.short(r), sub: Self.stamp(r), key: r, color: .secondary) { term.select(r) }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
    }

    private func chip(_ title: String, sub: String, key: String, color: Color, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption.monospaced()).lineLimit(1)
                Text(sub).font(.system(size: 9)).foregroundStyle(color)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(term.selected == key ? Color.accentColor.opacity(0.25) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    if term.loading { ProgressView().padding() }
                    Text(term.shown.isEmpty ? "$ _\n\n(tap Run queue — every command and its output streams here)" : term.shown)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(red: 0.80, green: 0.95, blue: 0.80))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .background(Color.black)
            .onChange(of: term.shown.count) { _, _ in if follow { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: term.selected) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Desktop") {
                    TextField("queue URL", text: $app.queueURL).font(.caption.monospaced())
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("token (optional)", text: $app.queueToken).font(.caption.monospaced())
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Save & check") { app.saveQueueSettings(); app.checkDesktop() }
                    if let e = app.queueError { Text(e).font(.caption2).foregroundStyle(.red) }
                    else if app.queueReachable { Text("reachable").font(.caption2).foregroundStyle(.green) }
                }
            }
            .navigationTitle("Queue settings")
            .toolbar { Button("Done") { showSettings = false } }
        }
        .presentationDetents([.medium])
    }

    static func short(_ r: String) -> String { String(r.split(separator: "@").first ?? Substring(r)) }
    static func stamp(_ r: String) -> String {
        guard let s = r.split(separator: "@").last, s.count >= 13 else { return "desktop" }
        let a = Array(s); return "\(String(a[4...5]))/\(String(a[6...7])) \(String(a[9...10])):\(String(a[11...12]))"
    }
}

enum TermSinkSnapshot { static var current: String? { TermSink.shared.run } }

// MARK: - Tests

struct TestsView: View {
    @ObservedObject var app = AppState.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Procedures") {
                    testButton("Metal streaming bench (verified)", "Benchmark weight reads at 1/2/4/8 tokens per read, GPU-timed, every output checked", "metal")
                    testButton("Memory bandwidth (blit)", "Raw GPU copy speed — the ceiling any kernel runs into", "blit")
                    testButton("Allocation ceiling", "Allocate 512 MB → 2 GB and report which sizes actually survive", "memory")
                }
                Section("Results") {
                    if app.testResults.isEmpty { Text("nothing run yet").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(Array(app.testResults.enumerated()), id: \.offset) { _, r in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.name).font(.caption).fontWeight(.semibold)
                            Text(r.detail).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Text("Results are pushed to the desktop automatically, so the assistant reads them without you relaying anything.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Tests")
        }
    }

    @ViewBuilder private func testButton(_ title: String, _ sub: String, _ id: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(sub).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if app.testRunning { ProgressView() }
            else { Button("Run") { app.runTest(id) }.font(.caption).buttonStyle(.bordered) }
        }
    }
}

// MARK: - Device

struct DeviceView: View {
    @ObservedObject var app = AppState.shared
    @State private var showRaw = false

    var body: some View {
        NavigationStack {
            List {
                Section("Build") {
                    KV(k: "version", v: "\(app.version) (\(app.build))")
                    KV(k: "profile expires", v: (app.entitlements["_profileExpires"] ?? "?").prefix(10).description)
                    if !app.reinstallHint.isEmpty {
                        Text(app.reinstallHint).font(.caption2).foregroundStyle(.orange)
                    } else {
                        Text("Memory entitlement granted ✓").font(.caption2).foregroundStyle(.green)
                    }
                }
                Section("Memory") {
                    KV(k: "available to process", v: gb(app.memoryAvailable))
                    KV(k: "physical RAM", v: gbAny(app.device["physicalMemory"]))
                    KV(k: "phys footprint", v: mb(bytes(app.device["physFootprint"])))
                    KV(k: "GPU working set", v: gbAny((app.device["metal"] as? [String: Any])?["recommendedMaxWorkingSetSize"]))
                }
                Section("GPU") {
                    KV(k: "device", v: app.metalName)
                    KV(k: "families", v: app.metalFamilies.joined(separator: " "))
                    KV(k: "max buffer", v: gbAny((app.device["metal"] as? [String: Any])?["maxBufferLength"]))
                }
                Section("CPU") {
                    if let c = app.device["cpu"] as? [String: Any] {
                        KV(k: "cores", v: "\(c["pCores"] ?? 0) P + \(c["eCores"] ?? 0) E")
                        KV(k: "P L2 / E L2", v: "\(mb(bytes(c["pL2"]))) / \(mb(bytes(c["eL2"])))")
                        KV(k: "cache line", v: "\(c["cacheline"] ?? 0) B")
                        KV(k: "page size", v: "\(c["pagesize"] ?? 0) B")
                    }
                }
                Section("State") {
                    KV(k: "thermal", v: app.thermal)
                    KV(k: "low power", v: "\((app.device["lowPowerMode"] as? Bool ?? false))")
                    KV(k: "machine", v: app.device["machine"] as? String ?? "?")
                    KV(k: "os", v: app.device["os"] as? String ?? "?")
                }
                Section("Entitlements") {
                    ForEach(app.entitlements.keys.sorted(), id: \.self) { k in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(k).font(.caption2.monospaced())
                            Text(app.entitlements[k] ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                Section {
                    NavigationLink("Control server & log") { ControlView() }
                    Toggle("Raw JSON", isOn: $showRaw)
                    if showRaw {
                        Text(String(data: (try? JSONSerialization.data(withJSONObject: ControlServer.sanitize(app.device), options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? "")
                            .font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Device")
        }
    }
}

// MARK: - Control

struct ControlView: View {
    @ObservedObject var app = AppState.shared

    var body: some View {
        Group {
            List {
                Section("Loopback control server") {
                    KV(k: "bound hosts", v: app.controlHosts.isEmpty ? "—" : app.controlHosts.joined(separator: ", "))
                    KV(k: "running", v: app.controlRunning ? "yes" : "no")
                    KV(k: "requests served", v: "\(app.controlRequests)")
                    KV(k: "port", v: "\(ControlServer.shared.port)")
                    HStack { Text("token").foregroundStyle(.secondary); Spacer(); Text(app.token).font(.footnote.monospaced()).textSelection(.enabled) }
                    Button("Copy token") { UIPasteboard.general.string = app.token }
                    Button("Restart server") { ControlServer.shared.restart() }
                }
                Section("Log") {
                    ForEach(Array(app.logLines.suffix(50).reversed().enumerated()), id: \.offset) { _, l in
                        Text(l).font(.caption2.monospaced())
                    }
                }
            }
            .navigationTitle("Control")
        }
    }
}
