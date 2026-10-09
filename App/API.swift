import Foundation
import UIKit

/// The control API. Every route returns JSON. Designed to be driven by a script or an agent.
enum API {
    static let routes: [String: String] = [
        "GET /ping": "liveness, no token",
        "GET /status": "app + model + memory + thermal",
        "GET /device": "full hardware/entitlement probe",
        "GET /log": "recent log lines",
        "GET /models": "preset model ids",
        "POST /load {model, cacheLimitMB?}": "download if needed and load an MLX model (preset name or HF repo id)",
        "POST /unload": "free the model",
        "POST /generate {prompt, maxTokens?, temperature?, system?}": "measured generation",
        "GET /history": "past generation records",
        "POST /bench/metal {kernels?, batches?}": "native weight-streaming bench (GPU-timed, verified)",
        "POST /bench/blit {mib?}": "raw GPU copy bandwidth",
        "POST /bench/model {prompt?, maxTokens?, runs?}": "repeat generation N times, report median tok/s and thermal drift",
    ]

    static func handle(_ method: String, _ path: String, _ q: [String: String], _ b: [String: Any]) async -> (Int, Any) {
        do {
            switch (method, path) {
            case ("GET", "/ping"):
                return (200, ["ok": true, "app": "LoopLab", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?"])
            case ("GET", "/"), ("GET", "/routes"):
                return (200, routes)
            case ("GET", "/status"):
                var s = await ModelHost.shared.status()
                s["thermal"] = DeviceProbe.thermalString()
                s["availableToProcess"] = DeviceProbe.availableMemory()
                s["physFootprint"] = DeviceProbe.physFootprint()
                return (200, s)
            case ("GET", "/device"):
                return (200, await MainActor.run { DeviceProbe.snapshot() })
            case ("GET", "/log"):
                return (200, ["lines": Log.shared.all().suffix(Int(q["n"] ?? "100") ?? 100)])
            case ("GET", "/models"):
                return (200, ModelHost.presets)
            case ("POST", "/load"):
                let m = b["model"] as? String ?? q["model"] ?? "qwen3-0.6b"
                let lim = b["cacheLimitMB"] as? Int ?? 64
                return (200, try await ModelHost.shared.load(m, cacheLimitMB: lim))
            case ("POST", "/unload"):
                await ModelHost.shared.unload()
                return (200, await ModelHost.shared.status())
            case ("POST", "/generate"):
                guard let p = b["prompt"] as? String else { return (400, ["error": "prompt required"]) }
                let r = try await ModelHost.shared.generate(
                    prompt: p, maxTokens: b["maxTokens"] as? Int ?? 256,
                    temperature: Float(b["temperature"] as? Double ?? 0), system: b["system"] as? String)
                return (200, r)
            case ("GET", "/history"):
                return (200, ["records": await ModelHost.shared.history])
            case ("POST", "/bench/metal"):
                let k = b["kernels"] as? [String] ?? ["thread", "simd"]
                let bs = b["batches"] as? [Int] ?? [1, 2, 4, 8]
                return (200, try MetalBench.run(kernels: k, batches: bs))
            case ("POST", "/bench/blit"):
                return (200, MetalBench.blitBandwidth(mib: b["mib"] as? Int ?? 512))
            case ("POST", "/bench/model"):
                let runs = b["runs"] as? Int ?? 3
                let prompt = b["prompt"] as? String ?? "Write a short paragraph about the ocean."
                var tps: [Double] = []
                var recs: [[String: Any]] = []
                for _ in 0..<runs {
                    let r = try await ModelHost.shared.generate(prompt: prompt, maxTokens: b["maxTokens"] as? Int ?? 128)
                    if let i = r["mlxInfo"] as? [String: Any], let t = i["tokensPerSecond"] as? Double { tps.append(t) }
                    recs.append(r.filter { $0.key != "text" && $0.key != "prompt" })
                }
                let sorted = tps.sorted()
                return (200, ["medianTokensPerSecond": sorted.isEmpty ? 0 : sorted[sorted.count / 2], "all": tps, "runs": recs])
            default:
                return (404, ["error": "no route \(method) \(path)", "routes": routes])
            }
        } catch {
            Log.shared.add("\(method) \(path) failed: \(error)")
            return (500, ["error": "\(error)"])
        }
    }
}
