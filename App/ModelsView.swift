import SwiftUI
import UniformTypeIdentifiers

/// The on-device library: what is installed, how big, what it can do; download, load, delete,
/// benchmark flash reads, and import a folder from Files.
@MainActor final class Library: ObservableObject {
    static let shared = Library()
    @Published var models: [InstalledModel] = []
    @Published var busy: String?
    @Published var message: String?

    func refresh() { models = ModelStore.installed() }

    func download(_ id: String) {
        guard busy == nil else { return }
        busy = id; message = nil
        Task {
            let run = TermSink.shared.begin("download-\(id.split(separator: "/").last ?? "")")
            TermSink.shared.line("$ download \(id)")
            do {
                _ = try await ModelHost.shared.load(id, cacheLimitMB: 256)
                message = "\(id) saved to the library"
            } catch { message = "\(error)"; TermSink.shared.line("  error: \(error)") }
            TermSink.shared.end()
            _ = run
            busy = nil; refresh()
            AppState.shared.refreshLocal()
        }
    }

    func delete(_ m: InstalledModel) {
        Task {
            if await ModelHost.shared.modelId == m.id { await ModelHost.shared.unload() }
            do { try ModelStore.delete(m.id); message = "deleted \(m.name)" } catch { message = "\(error)" }
            refresh()
        }
    }

    func importFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard ModelStore.isModelDir(url) else { message = "That folder has no config.json + .safetensors"; return }
        let id = "local/\(url.lastPathComponent)"
        let dest = ModelStore.dir(for: id)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: url, to: dest)
            let marker = ["id": id, "source": "files"]
            try? JSONSerialization.data(withJSONObject: marker).write(to: dest.appendingPathComponent(".looplab.json"))
            message = "imported \(url.lastPathComponent)"
        } catch { message = "\(error)" }
        refresh()
    }

    func readBench(_ m: InstalledModel) {
        busy = m.id
        Task.detached {
            let r = ModelStore.readBench(id: m.id)
            await MainActor.run {
                let seq = r["seqGBps"] as? Double ?? 0, rnd = r["randomGBps"] as? Double ?? 0
                Library.shared.message = String(format: "%@: sequential %.2f GB/s · random 4 MB %.2f GB/s · p95 %.1f ms",
                                                m.name, seq, rnd, r["randomMsP95"] as? Double ?? 0)
                Library.shared.busy = nil
                AppState.shared.pushToDesktop(["op": "read_bench", "source": "library"].merging(r) { a, _ in a })
            }
        }
    }
}

struct ModelsView: View {
    @ObservedObject var lib = Library.shared
    @ObservedObject var app = AppState.shared
    @State private var custom = ""
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Stored in Files › On My iPhone › LoopLab › Models. Shortcuts actions list exactly these.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let m = lib.message { Text(m).font(.caption2).foregroundStyle(.blue) }
                }
                Section("Installed (\(lib.models.count))") {
                    if lib.models.isEmpty { Text("Nothing yet — download one below.").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(lib.models) { m in row(m) }
                }
                Section("Download") {
                    ForEach(app.modelPresets.keys.sorted(), id: \.self) { k in
                        let id = app.modelPresets[k] ?? k
                        if !lib.models.contains(where: { $0.id == id }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(k).font(.subheadline)
                                    Text(id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if lib.busy == id { ProgressView(value: app.modelLoadProgress).frame(width: 60) }
                                else { Button("Get") { lib.download(id) }.buttonStyle(.bordered).disabled(lib.busy != nil) }
                            }
                        }
                    }
                    HStack {
                        TextField("org/name from Hugging Face", text: $custom).font(.caption.monospaced())
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Get") { lib.download(custom.trimmingCharacters(in: .whitespaces)) }
                            .disabled(!custom.contains("/") || lib.busy != nil)
                    }
                    Button { importing = true } label: { Label("Import a folder from Files", systemImage: "folder.badge.plus") }
                }
            }
            .navigationTitle("Models")
            .onAppear { lib.refresh() }
            .refreshable { lib.refresh() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { r in
                if case .success(let url) = r { lib.importFolder(url) }
            }
        }
    }

    @ViewBuilder private func row(_ m: InstalledModel) -> some View {
        let loaded = app.loadedModel == m.id
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(m.name).font(.subheadline.weight(.medium)).lineLimit(1)
                if loaded { Text("loaded").font(.caption2).padding(.horizontal, 5).background(.green.opacity(0.2), in: Capsule()) }
                Spacer()
                Text(m.sizeText).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                tag(m.modelType); tag("\(m.layers) layers")
                if m.looped { tag("looped") }
                if m.thinkingCapable { tag("can think") }
                if let t = m.temperature { tag(String(format: "temp %.1f", t)) }
            }
            HStack {
                Button(loaded ? "Unload" : "Load") { loaded ? app.unload() : app.load(m.id) }.buttonStyle(.bordered)
                Button("Read speed") { lib.readBench(m) }.buttonStyle(.bordered).disabled(lib.busy != nil)
                Spacer()
                Button(role: .destructive) { lib.delete(m) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 10).monospaced()).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
    }
}
