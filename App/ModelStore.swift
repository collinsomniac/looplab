import Foundation

/// One model on disk, plus what we can read about it without loading it.
struct InstalledModel: Identifiable, Hashable, Sendable {
    var id: String            // Hugging Face repo id, e.g. "mlx-community/Qwen3-1.7B-4bit"
    var dir: URL
    var bytes: Int64
    var modelType: String
    var layers: Int
    var thinkingCapable: Bool // chat template has an enable_thinking switch
    var looped: Bool          // recurrent-depth model (Ouro)
    var temperature: Double?  // from generation_config.json
    var topP: Double?
    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
    var sizeText: String { String(format: "%.2f GB", Double(bytes) / 1e9) }
}

/// Persistent model library in the app's Documents folder, so it shows up in
/// Files › On My iPhone › LoopLab › Models (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace).
///
/// Layout: Models/<org>__<name>/{config.json, *.safetensors, tokenizer files, .looplab.json}
/// A model counts as installed when config.json and at least one .safetensors are present, so a user
/// can also drop a folder in from Files or a Mac and it will be picked up.
enum ModelStore {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let r = docs.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return r
    }

    static func slug(_ id: String) -> String { id.replacingOccurrences(of: "/", with: "__") }
    static func dir(for id: String) -> URL { root.appendingPathComponent(slug(id), isDirectory: true) }

    static func isInstalled(_ id: String) -> Bool { isModelDir(dir(for: id)) }

    static func isModelDir(_ d: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: d.appendingPathComponent("config.json").path) else { return false }
        let files = (try? fm.contentsOfDirectory(atPath: d.path)) ?? []
        return files.contains { $0.hasSuffix(".safetensors") }
    }

    /// Every installed model, largest-first is not useful; sort by name.
    static func installed() -> [InstalledModel] {
        let fm = FileManager.default
        let subs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return subs.filter { isModelDir($0) }
            .map { profile(dir: $0) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func find(_ id: String) -> InstalledModel? {
        let d = dir(for: id)
        return isModelDir(d) ? profile(dir: d) : nil
    }

    static func profile(dir: URL) -> InstalledModel {
        func json(_ name: String) -> [String: Any] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let marker = json(".looplab.json")
        let id = marker["id"] as? String
            ?? dir.lastPathComponent.replacingOccurrences(of: "__", with: "/", options: [], range: dir.lastPathComponent.range(of: "__"))
        let cfg = json("config.json")
        let text = cfg["text_config"] as? [String: Any] ?? [:]
        let gen = json("generation_config.json")
        let type = cfg["model_type"] as? String ?? "?"
        var template = (json("tokenizer_config.json")["chat_template"] as? String) ?? ""
        if let jinja = try? String(contentsOf: dir.appendingPathComponent("chat_template.jinja"), encoding: .utf8) {
            template += jinja
        }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        return InstalledModel(
            id: id, dir: dir, bytes: size(of: dir), modelType: type,
            layers: (cfg["num_hidden_layers"] as? Int) ?? (text["num_hidden_layers"] as? Int) ?? 0,
            thinkingCapable: template.contains("enable_thinking"),
            looped: type == "ouro",
            temperature: num(gen["temperature"]), topP: num(gen["top_p"]))
    }

    static func size(of dir: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in e {
                total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// Move a freshly downloaded snapshot (Hub cache, symlinks into a blob store) into the library,
    /// then delete the cache copy so the model is stored once.
    static func adopt(from src: URL, id: String) throws -> URL {
        let fm = FileManager.default
        let dest = dir(for: id)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let srcPath = src.standardizedFileURL.path
        if let e = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let u as URL in e {
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                let rel = String(u.standardizedFileURL.path.dropFirst(srcPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let target = dest.appendingPathComponent(rel)
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                let real = u.resolvingSymlinksInPath()
                do { try fm.moveItem(at: real, to: target) } catch { try fm.copyItem(at: real, to: target) }
            }
        }
        let marker = ["id": id, "source": "huggingface", "adopted": ISO8601DateFormatter().string(from: Date())]
        if let d = try? JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted]) {
            try? d.write(to: dest.appendingPathComponent(".looplab.json"))
        }
        // Remove the Hub cache repo ("models--org--name") the snapshot lived in.
        var p = src
        for _ in 0..<4 {
            if p.lastPathComponent.hasPrefix("models--") { try? fm.removeItem(at: p); break }
            p = p.deletingLastPathComponent()
        }
        return dest
    }

    static func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: dir(for: id))
    }

    /// Flash read speed of a model's weights: sequential and random 4 MiB reads (the access pattern
    /// of streaming MoE experts). noCache bypasses the unified buffer cache (F_NOCACHE) so we measure
    /// storage, not RAM.
    static func readBench(id: String, megabytes: Int = 512, noCache: Bool = true, randomReads: Int = 64) -> [String: Any] {
        guard let m = find(id) else { return ["error": "\(id) is not installed"] }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: m.dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "safetensors" }
            .sorted { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard let f = files.first else { return ["error": "no weights"] }
        let fileSize = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let fd = open(f.path, O_RDONLY)
        guard fd >= 0 else { return ["error": "open failed"] }
        defer { close(fd) }
        if noCache { _ = fcntl(fd, F_NOCACHE, 1) }
        let chunk = 16 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buf.deallocate() }

        let want = min(megabytes << 20, fileSize)
        var done = 0
        let t0 = Date()
        while done < want {
            let n = pread(fd, buf, min(chunk, want - done), off_t(done))
            if n <= 0 { break }
            done += n
        }
        let seqS = Date().timeIntervalSince(t0)

        let block = 4 << 20
        var lat: [Double] = []
        var rbytes = 0
        if fileSize > block {
            for _ in 0..<randomReads {
                let off = Int.random(in: 0...(fileSize - block)) & ~16383
                let t = Date()
                let n = pread(fd, buf, block, off_t(off))
                lat.append(Date().timeIntervalSince(t) * 1000)
                if n > 0 { rbytes += n }
            }
        }
        lat.sort()
        let randS = lat.reduce(0, +) / 1000
        return [
            "model": id, "file": f.lastPathComponent, "fileBytes": fileSize, "noCache": noCache,
            "seqBytes": done, "seqGBps": seqS > 0 ? Double(done) / seqS / 1e9 : 0,
            "randomBlockMB": 4, "randomReads": lat.count,
            "randomGBps": randS > 0 ? Double(rbytes) / randS / 1e9 : 0,
            "randomMsP50": lat.isEmpty ? 0 : lat[lat.count / 2],
            "randomMsP95": lat.isEmpty ? 0 : lat[min(lat.count - 1, lat.count * 95 / 100)],
        ]
    }
}
