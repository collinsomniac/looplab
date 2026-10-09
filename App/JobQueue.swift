import Foundation

/// Fetches job specs from the desktop queue and runs them, so the agent can prepare work remotely and
/// the user only has to tap once. Results are pushed back to the same server as they are produced.
///
/// Why a queue: iOS suspends a backgrounded app and refuses Metal work from it
/// (MTLCommandBufferError.notPermitted), so all GPU work must happen while the app is on screen.
final class JobQueue: @unchecked Sendable {
    static let shared = JobQueue()

    private let lock = NSLock()
    private var busy = false
    private(set) var lastReport: String = ""
    private(set) var base: String = UserDefaults.standard.string(forKey: "queueBase") ?? "http://100.113.239.4:8791"
    private(set) var token: String = UserDefaults.standard.string(forKey: "queueToken") ?? ""

    func setBase(_ s: String) { base = s; UserDefaults.standard.set(s, forKey: "queueBase") }
    func setToken(_ s: String) { token = s; UserDefaults.standard.set(s, forKey: "queueToken") }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: base + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 30
        if !token.isEmpty { r.setValue(token, forHTTPHeaderField: "X-Token") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: ControlServer.sanitize(body))
        }
        return r
    }

    private func send(_ path: String, _ body: [String: Any]) {
        guard let r = request(path, method: "POST", body: body) else { return }
        URLSession.shared.dataTask(with: r).resume()
    }

    func ping() async -> [String: Any] {
        guard let r = request("/health") else { return ["error": "bad base url"] }
        do {
            let (data, _) = try await URLSession.shared.data(for: r)
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? ["raw": String(data: data, encoding: .utf8) ?? ""]
        } catch { return ["error": "\(error)"] }
    }

    /// Run everything currently queued, one job after another, pushing results as we go.
    func runQueue(maxJobs: Int = 8) {
        lock.lock(); if busy { lock.unlock(); lastReport = "already running"; return }; busy = true; lock.unlock()
        Task.detached { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            for _ in 0..<maxJobs {
                guard let r = self.request("/queue"), let (data, _) = try? await URLSession.shared.data(for: r),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let jobs = obj["jobs"] as? [[String: Any]], !jobs.isEmpty else { break }
                for job in jobs {
                    let id = job["id"] as? String ?? "unnamed"
                    let steps = job["steps"] as? [[String: Any]] ?? []
                    self.report("running \(id) (\(steps.count) steps)")
                    Log.shared.add("queue: running \(id) with \(steps.count) steps")
                    // run steps synchronously here so jobs stay ordered and results stream back
                    for (i, step) in steps.enumerated() {
                        let t0 = Date()
                        var out: [String: Any] = ["job": id, "i": i, "op": step["op"] as? String ?? "?"]
                        if let e = await JobRunnerBridge.run(step) { out.merge(e) { a, _ in a } }
                        out["ms"] = Int(Date().timeIntervalSince(t0) * 1000)
                        out["thermal"] = DeviceProbe.thermalString()
                        self.send("/results", out)
                    }
                    self.send("/results", ["job": id, "op": "job_end", "steps": steps.count])
                    self.send("/queue/done", ["id": id])
                }
            }
            self.report("queue drained")
            Log.shared.add("queue drained")
        }
    }

    private func report(_ s: String) { lock.lock(); lastReport = s; lock.unlock() }
}

/// Thin bridge so the queue runs exactly the same step kinds as the local job runner.
enum JobRunnerBridge {
    static func run(_ step: [String: Any]) async -> [String: Any]? {
        do { return try await JobRunner.shared.execute(step) }
        catch { return ["error": "\(error)"] }
    }
}
