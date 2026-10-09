import Foundation
import Metal

/// Native counterpart of the browser bench: same 64 MiB f16 matvec, batch B = 1/2/4/8,
/// every timing from GPU timestamps (MTLCommandBuffer gpuStartTime/gpuEndTime), outputs verified.
enum MetalBench {

    static let rows = 16384
    static let cols = 2048

    static func shader(batch B: Int) -> String {
        let acc = (0..<B).map { "float a\($0) = 0.0f;" }.joined(separator: "\n    ")
        let body = (0..<B).map { "a\($0) += dot(float4(w[row * C4 + c]), float4(x[\($0) * C4 + c]));" }.joined(separator: "\n        ")
        let store = (0..<B).map { "y[\($0) * ROWS + row] = a\($0);" }.joined(separator: "\n    ")
        return """
        #include <metal_stdlib>
        using namespace metal;
        constant uint C4 = \(cols / 4);
        constant uint ROWS = \(rows);
        kernel void matvec(device const half4* w [[buffer(0)]],
                           device const half4* x [[buffer(1)]],
                           device float* y [[buffer(2)]],
                           uint row [[thread_position_in_grid]]) {
            if (row >= ROWS) return;
            \(acc)
            for (uint c = 0; c < C4; c++) {
                \(body)
            }
            \(store)
        }
        """
    }

    /// Simdgroup variant: 32 lanes share one row, reduce with simd_sum — what subgroups would give WebGPU.
    static func simdShader(batch B: Int) -> String {
        let acc = (0..<B).map { "float a\($0) = 0.0f;" }.joined(separator: "\n    ")
        let body = (0..<B).map { "a\($0) += dot(float4(w[row * C4 + c]), float4(x[\($0) * C4 + c]));" }.joined(separator: "\n        ")
        let store = (0..<B).map { "float s\($0) = simd_sum(a\($0)); if (lane == 0) y[\($0) * ROWS + row] = s\($0);" }.joined(separator: "\n    ")
        return """
        #include <metal_stdlib>
        using namespace metal;
        constant uint C4 = \(cols / 4);
        constant uint ROWS = \(rows);
        kernel void matvec(device const half4* w [[buffer(0)]],
                           device const half4* x [[buffer(1)]],
                           device float* y [[buffer(2)]],
                           uint gid [[thread_position_in_grid]],
                           uint lane [[thread_index_in_simdgroup]]) {
            uint row = gid / 32;
            if (row >= ROWS) return;
            \(acc)
            for (uint c = lane; c < C4; c += 32) {
                \(body)
            }
            \(store)
        }
        """
    }

    struct Result: Codable {
        var kernel: String
        var batch: Int
        var gpuMs: Double
        var gbPerS: Double
        var ok: Bool
        var maxRelErr: Double
    }

    static func run(kernels: [String] = ["thread", "simd"], batches: [Int] = [1, 2, 4, 8], reps: Int = 20) throws -> [String: Any] {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else {
            throw NSError(domain: "MetalBench", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Metal device"])
        }
        // weights: small deterministic halves
        var w16 = [Float16](repeating: 0, count: rows * cols)
        var s: UInt32 = 12345
        for i in 0..<w16.count {
            s = s &* 1103515245 &+ 12345
            w16[i] = Float16((Float((s >> 16) & 0x0fff) / 4096.0 - 0.5) * 0.02)
        }
        let W = dev.makeBuffer(bytes: w16, length: w16.count * 2, options: .storageModeShared)!
        // reference row sums for 256 rows (x_b = b+1 everywhere, so y_b[r] = (b+1) * rowsum[r])
        let check = (0..<256).map { ($0 * 61) % rows }
        let rowsum: [Double] = check.map { r in (0..<cols).reduce(0.0) { $0 + Double(w16[r * cols + $1]) } }

        var results: [Result] = []
        for kind in kernels {
            for B in batches {
                var x = [Float16](repeating: 0, count: B * cols)
                for b in 0..<B { for c in 0..<cols { x[b * cols + c] = Float16(Float(b + 1)) } }
                let X = dev.makeBuffer(bytes: x, length: x.count * 2, options: .storageModeShared)!
                let Y = dev.makeBuffer(length: B * rows * 4, options: .storageModeShared)!
                let src = kind == "simd" ? simdShader(batch: B) : shader(batch: B)
                let lib = try dev.makeLibrary(source: src, options: nil)
                let pso = try dev.makeComputePipelineState(function: lib.makeFunction(name: "matvec")!)
                let threads = kind == "simd" ? rows * 32 : rows
                let tg = MTLSize(width: min(256, pso.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
                func once() -> Double {
                    let cb = q.makeCommandBuffer()!
                    let enc = cb.makeComputeCommandEncoder()!
                    enc.setComputePipelineState(pso)
                    enc.setBuffer(W, offset: 0, index: 0); enc.setBuffer(X, offset: 0, index: 1); enc.setBuffer(Y, offset: 0, index: 2)
                    enc.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1), threadsPerThreadgroup: tg)
                    enc.endEncoding()
                    cb.commit(); cb.waitUntilCompleted()
                    return (cb.gpuEndTime - cb.gpuStartTime) * 1000
                }
                for _ in 0..<3 { _ = once() }
                memset(Y.contents(), 0, B * rows * 4)
                var ts = (0..<reps).map { _ in once() }
                ts.sort()
                let med = ts[ts.count / 2]
                let y = Y.contents().bindMemory(to: Float.self, capacity: B * rows)
                var maxErr = 0.0
                var ok = true
                for b in 0..<B {
                    for (k, r) in check.enumerated() {
                        let want = Double(b + 1) * rowsum[k]
                        let got = Double(y[b * rows + r])
                        let err = abs(got - want) / (1 + abs(want))
                        maxErr = max(maxErr, err)
                        if !(err < 2e-2) { ok = false }
                    }
                }
                results.append(Result(kernel: kind, batch: B, gpuMs: med, gbPerS: Double(rows * cols * 2) / med / 1e6, ok: ok, maxRelErr: maxErr))
            }
        }
        let enc = try JSONEncoder().encode(results)
        let arr = (try JSONSerialization.jsonObject(with: enc)) as? [[String: Any]] ?? []
        return ["weightMiB": rows * cols * 2 / (1 << 20), "results": arr, "thermal": DeviceProbe.thermalString()]
    }

    /// Pure memory bandwidth: copy N MiB GPU→GPU with a blit, GPU-timed.
    static func blitBandwidth(mib: Int = 512, reps: Int = 10) -> [String: Any] {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(),
              let a = dev.makeBuffer(length: mib << 20, options: .storageModePrivate),
              let b = dev.makeBuffer(length: mib << 20, options: .storageModePrivate) else { return ["error": "alloc"] }
        func once() -> Double {
            let cb = q.makeCommandBuffer()!
            let bl = cb.makeBlitCommandEncoder()!
            bl.copy(from: a, sourceOffset: 0, to: b, destinationOffset: 0, size: mib << 20)
            bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            return cb.gpuEndTime - cb.gpuStartTime
        }
        _ = once()
        var ts = (0..<reps).map { _ in once() }
        ts.sort()
        let t = ts[ts.count / 2]
        // a copy reads N and writes N bytes
        return ["mib": mib, "ms": t * 1000, "readPlusWriteGBs": Double(2 * (mib << 20)) / t / 1e9]
    }
}
