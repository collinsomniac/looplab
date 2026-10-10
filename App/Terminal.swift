import Foundation
import SwiftUI

/// Thread-safe terminal output. Anything (queue runner, model host, Shortcuts actions) writes here;
/// the UI drains it at 10 Hz and the desktop receives it once a second, appended verbatim to
/// D:\loopscope\terminal\<run>\terminal.log. The phone keeps only this session's text.
final class TermSink: @unchecked Sendable {
    static let shared = TermSink()
    private let lock = NSLock()
    private(set) var run: String?
    private var ui: [(run: String, text: String)] = []
    private var net: [String: String] = [:]
    private var netOrder: [String] = []
    private var flusher = false
    private var lastTenth = -1

    var active: Bool { lock.lock(); defer { lock.unlock() }; return run != nil }
    /// Stream generated tokens into the terminal. A job can switch it off ({"op":"echo","on":false})
    /// to measure what live display costs.
    var echoTokens = true

    func begin(_ name: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let id = "\(name)@\(f.string(from: Date()))"
        lock.lock(); run = id; lastTenth = -1; lock.unlock()
        startFlusher()
        return id
    }

    func end() {
        lock.lock(); run = nil; lock.unlock()
        Task { await flush() }
    }

    func write(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        guard let r = run else { return }
        if let last = ui.last, last.run == r { ui[ui.count - 1].text += s } else { ui.append((r, s)) }
        if net[r] == nil { netOrder.append(r) }
        net[r, default: ""] += s
    }

    func line(_ s: String) { write(s + "\n") }

    func progress(_ f: Double) {
        let tenth = Int(f * 10)
        lock.lock(); let show = run != nil && tenth > lastTenth; if show { lastTenth = tenth }; lock.unlock()
        if show { line("  download \(tenth * 10)%") }
    }

    func drainUI() -> [(run: String, text: String)] {
        lock.lock(); defer { lock.unlock() }
        let out = ui; ui.removeAll(); return out
    }

    private func drainNet() -> [(String, String)] {
        lock.lock(); defer { lock.unlock() }
        let out = netOrder.compactMap { r in net[r].map { (r, $0) } }
        net.removeAll(); netOrder.removeAll(); return out
    }

    private func requeue(_ r: String, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        if net[r] == nil { netOrder.insert(r, at: 0) }
        net[r] = text + (net[r] ?? "")
    }

    private func startFlusher() {
        lock.lock(); let start = !flusher; flusher = true; lock.unlock()
        guard start else { return }
        Task.detached {
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await TermSink.shared.flush()
            }
        }
    }

    func flush() async {
        for (r, text) in drainNet() {
            guard let req = Desktop.request("/log", method: "POST", body: ["run": r, "text": text]) else { continue }
            if (try? await URLSession.shared.data(for: req)) == nil { requeue(r, text); return }
        }
    }
}

/// Desktop endpoint helpers shared by the queue, the terminal and the intents.
enum Desktop {
    static var base: String {
        UserDefaults.standard.string(forKey: "queueBase") ?? "https://desktop-3rsf4r5.tailce70fb.ts.net:8443"
    }
    static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: base + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 30
        if let t = UserDefaults.standard.string(forKey: "queueToken"), !t.isEmpty { r.setValue(t, forHTTPHeaderField: "X-Token") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: ControlServer.sanitize(body))
        }
        return r
    }
}

/// What the Queue tab shows: one terminal per run, newest selected while running.
@MainActor final class Terminal: ObservableObject {
    static let shared = Terminal()
    /// Lines per run. Rendering is lazy (only visible lines are laid out), and the UI refreshes at
    /// 4 Hz, so a long run costs the same to display as a short one.
    @Published private(set) var lines: [String: [String]] = [:]
    @Published var sessionRuns: [String] = []
    @Published var desktopRuns: [String] = []
    @Published var selected: String?
    @Published var loading = false
    private var timer: Timer?
    static let lineCap = 4000

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in Terminal.shared.pump() }
        }
    }

    private func append(_ text: String, to r: String) {
        var ls = lines[r] ?? [""]
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        ls[ls.count - 1] += parts[0]
        for p in parts.dropFirst() { ls.append(String(p)) }
        if ls.count > Self.lineCap { ls.removeFirst(ls.count - Self.lineCap); ls[0] = "… earlier lines are in the desktop log …" }
        lines[r] = ls
    }

    func pump() {
        let batch = TermSink.shared.drainUI()
        guard !batch.isEmpty else { return }
        for (r, t) in batch {
            if !sessionRuns.contains(r) { sessionRuns.append(r); selected = r }
            append(t, to: r)
        }
    }

    var shownLines: [String] { selected.flatMap { lines[$0] } ?? [] }
    var shown: String { shownLines.joined(separator: "\n") }

    func select(_ r: String) {
        selected = r
        if lines[r] == nil { Task { await fetch(r) } }
    }

    func showPending(_ id: String, steps: [[String: Any]]) {
        let key = "pending:\(id)"
        var s = ["# \(id) — queued, \(steps.count) steps (not run yet)", ""]
        for (i, st) in steps.enumerated() { s.append(String(format: "%3d  $ ", i + 1) + Terminal.command(st)) }
        lines[key] = s
        selected = key
    }

    func loadHistory() async {
        guard let req = Desktop.request("/runs"),
              let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        desktopRuns = ((obj["runs"] as? [[String: Any]]) ?? []).compactMap { $0["run"] as? String }
    }

    func fetch(_ r: String) async {
        loading = true; defer { loading = false }
        let q = r.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? r
        guard let req = Desktop.request("/log?run=\(q)"),
              let (data, _) = try? await URLSession.shared.data(for: req) else {
            lines[r] = ["# could not reach the desktop to load \(r)"]; return
        }
        lines[r] = [""]
        append(String(data: data, encoding: .utf8) ?? "", to: r)
    }

    /// One step spec as a shell-style command line.
    static func command(_ step: [String: Any]) -> String {
        let op = step["op"] as? String ?? "?"
        let args = step.keys.filter { $0 != "op" }.sorted().map { k -> String in
            let v = step[k]!
            if let s = v as? String {
                let e = s.replacingOccurrences(of: "\n", with: "\\n")
                return "\(k)=\"\(e.count > 90 ? String(e.prefix(90)) + "…" : e)\""
            }
            if let a = v as? [Any] { return "\(k)=[\(a.map { "\($0)" }.joined(separator: ","))]" }
            return "\(k)=\(v)"
        }
        return ([op] + args).joined(separator: " ")
    }
}
