import Foundation
import UIKit

/// Runs a *job*: an ordered list of steps, executed inside the app while it is on screen.
///
/// Why: iOS suspends an app the moment it leaves the foreground, and Metal work cannot run in the
/// background. So the practical pattern is a single tap (or one HTTP call) that starts a whole battery
/// of measurements; results are appended to JSONL in the app's Documents directory and can be pushed to
/// another machine (e.g. the desktop over Tailscale) when the job finishes.
///
/// Step kinds:
///   {"op":"probe"}                                   device snapshot
///   {"op":"bench_metal","kernels":["thread","simd"],"batches":[1,2,4,8]}
///   {"op":"bench_blit","mib":512}
///   {"op":"write_test","bytes":268435456}            allocate + touch N bytes, report whether it survived
///   {"op":"load","model":"qwen3-0.6b","cacheLimitMB":64}
///   {"op":"unload"}
///   {"op":"generate","prompt":"...","maxTokens":64,"temperature":0,"runs":1}
///   {"op":"sleep","seconds":2}
///   {"op":"mark","label":"..."}
final class JobRunner: @unchecked Sendable {
    static let shared = JobRunner()

    private let lock = NSLock()
    private var running: String?
    private var jobs: [String: [String: Any]] = [:]      // id -> meta
    private var results: [String: [[String: Any]]] = [:] // id -> steps

    private var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running != nil }

    func list() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return jobs.values.sorted { ($0["startedAt"] as? String ?? "") > ($1["startedAt"] as? String ?? "") }
    }

    func results(for id: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return results[id] ?? []
    }

    @discardableResult
    func start(spec: [String: Any]) -> [String: Any] {
        lock.lock()
        if let r = running { lock.unlock(); return ["error": "job \(r) already running"] }
        let id = "job-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 1000...9999))"
        running = id
        jobs[id] = ["id": id, "startedAt": ISO8601DateFormatter().string(from: Date()), "state": "running",
                    "steps": (spec["steps"] as? [Any])?.count ?? 0, "label": spec["label"] ?? ""]
        results[id] = []
        lock.unlock()

        let steps = (spec["steps"] as? [[String: Any]]) ?? []
        let postTo = spec["postTo"] as? String
        Task.detached { [weak self] in
            guard let self else { return }
            for (i, step) in steps.enumerated() {
                if Task.isCancelled { break }
                let t0 = Date()
                var out: [String: Any] = ["i": i, "op": step["op"] as? String ?? "?"]
                do {
                    out.merge(try await self.execute(step)) { _, b in b }
                } catch {
                    out["error"] = "\(error)"
                }
                out["ms"] = Int(Date().timeIntervalSince(t0) * 1000)
                self.append(id: id, result: out)
                if let postTo, let url = URL(string: postTo) { self.post(url: url, job: id, payload: out) }
            }
            self.finish(id: id)
            Log.shared.add("job \(id) finished")
        }
        return ["id": id, "started": true, "steps": steps.count]
    }

    private func append(id: String, result: [String: Any]) {
        lock.lock(); results[id, default: []].append(result); lock.unlock()
        let line = (try? JSONSerialization.data(withJSONObject: ControlServer.sanitize(result))) ?? Data()
        let f = dir.appendingPathComponent("\(id).jsonl")
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(line); h.write(Data("\n".utf8)); try? h.close() }
        else { try? (line + Data("\n".utf8)).write(to: f) }
    }

    private func finish(id: String) {
        lock.lock()
        jobs[id]?["state"] = "done"
        jobs[id]?["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        running = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock(); running = nil; lock.unlock()
    }

    /// Exposed so the remote queue can run the same step kinds without duplicating them.
    func execute(_ step: [String: Any]) async throws -> [String: Any] {
        switch step["op"] as? String ?? "" {
        case "probe":
            return await MainActor.run { DeviceProbe.snapshot() }
        case "mark":
            return ["label": step["label"] ?? ""]
        case "sleep":
            let s = (step["seconds"] as? Double) ?? (step["seconds"] as? Int).map(Double.init) ?? 1
            try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
            return ["slept": s]
        case "bench_metal":
            return try MetalBench.run(kernels: step["kernels"] as? [String] ?? ["thread", "simd"],
                                      batches: step["batches"] as? [Int] ?? [1, 2, 4, 8],
                                      reps: step["reps"] as? Int ?? 20)
        case "bench_blit":
            return MetalBench.blitBandwidth(mib: step["mib"] as? Int ?? 512)
        case "load":
            let m = step["model"] as? String ?? "qwen3-0.6b"
            return try await ModelHost.shared.load(m, cacheLimitMB: step["cacheLimitMB"] as? Int ?? 64).value
        case "unload":
            await ModelHost.shared.unload()
            return await ModelHost.shared.status().value
        case "generate":
            let runs = step["runs"] as? Int ?? 1
            var last: [String: Any] = [:]
            for _ in 0..<max(1, runs) {
                last = try await ModelHost.shared.generate(
                    prompt: step["prompt"] as? String ?? "Hello",
                    maxTokens: step["maxTokens"] as? Int ?? 64,
                    temperature: Float(step["temperature"] as? Double ?? 0),
                    system: step["system"] as? String,
                    thinking: step["thinking"] as? Bool ?? false).value
            }
            return last
        case "decide":
            return try await ModelHost.shared.decide(
                state: step["input"] as? String ?? "",
                question: step["question"] as? String ?? "",
                options: step["options"] as? [String] ?? ["yes", "no"],
                instructions: step["instructions"] as? String).value
        case "load_draft":
            return try await ModelHost.shared.loadDraft(step["model"] as? String ?? "qwen3-0.6b").value
        case "unload_draft":
            await ModelHost.shared.unloadDraft()
            return ["draft": "unloaded"]
        case "bench_spec":
            return try await ModelHost.shared.benchSpec(
                prompt: step["prompt"] as? String ?? "Write one sentence about the sea.",
                maxTokens: step["maxTokens"] as? Int ?? 128,
                runs: step["runs"] as? Int ?? 2,
                numDraftTokens: step["numDraftTokens"] as? Int ?? 5).value
        case "set_loops":
            return await ModelHost.shared.setLoops(step["loops"] as? Int ?? 4).value
        case "bench_loops":
            // same prompt at each loop count: shows what recurrence buys and what it costs
            var out: [[String: Any]] = []
            let counts = step["counts"] as? [Int] ?? [1, 2, 3, 4]
            let prompt = step["prompt"] as? String ?? "Write one sentence about the sea."
            let maxTokens = step["maxTokens"] as? Int ?? 128
            for n in counts {
                _ = await ModelHost.shared.setLoops(n)
                let r = try await ModelHost.shared.benchDecode(
                    prompt: prompt, maxTokens: maxTokens, runs: step["runs"] as? Int ?? 2).value
                var row = r
                row["loops"] = n
                out.append(row)
            }
            return ["results": out, "model": await ModelHost.shared.status().value["model"] ?? "?"]
        case "bench_decode":
            return try await ModelHost.shared.benchDecode(
                prompt: step["prompt"] as? String ?? "Write one sentence about the sea.",
                maxTokens: step["maxTokens"] as? Int ?? 128,
                runs: step["runs"] as? Int ?? 3,
                cacheLimitMB: step["cacheLimitMB"] as? Int,
                memoryLimitGB: step["memoryLimitGB"] as? Double,
                kvBits: step["kvBits"] as? Int).value
        case "write_test":
            let n = step["bytes"] as? Int ?? 256 * 1024 * 1024
            let before = DeviceProbe.availableMemory()
            var buf: [UInt8]? = [UInt8](repeating: 0, count: n)
            var touched = 0
            if var b = buf {
                var i = 0
                while i < n { b[i] = UInt8(i & 0xff); i += 4096; touched += 1 }
                buf = b
            }
            let after = DeviceProbe.availableMemory()
            let okAllocated = buf != nil
            buf = nil
            return ["requestedBytes": n, "allocated": okAllocated, "pagesTouched": touched,
                    "availableBefore": before, "availableAfter": after,
                    "mlxMemory": ModelHost.mlxMemory()]
        default:
            throw NSError(domain: "JobRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown op \(step["op"] ?? "?")"])
        }
    }

    private func post(url: URL, job: String, payload: [String: Any]) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ControlServer.sanitize(payload) as? [String: Any] ?? [:]
        body["job"] = job
        body["device"] = DeviceProbe.machineIdentifier()
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }

    /// Push everything recorded for a job to a URL (used at the end of a battery).
    func push(id: String, to urlString: String) -> [String: Any] {
        guard let url = URL(string: urlString) else { return ["error": "bad url"] }
        let rows = results(for: id)
        let body: [String: Any] = ["job": id, "device": DeviceProbe.machineIdentifier(),
                                   "thermal": DeviceProbe.thermalString(), "rows": rows]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ControlServer.sanitize(body))
        URLSession.shared.dataTask(with: req) { _, _, err in
            if let err { Log.shared.add("push failed: \(err)") } else { Log.shared.add("pushed job \(id)") }
        }.resume()
        return ["pushing": rows.count, "to": urlString]
    }
}
