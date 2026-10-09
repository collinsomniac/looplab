import Foundation
import Network

/// Tiny HTTP/1.1 JSON server on 127.0.0.1 (loopback only) so another app on the same phone
/// — here the Minis assistant in iSH — can drive the app: GET /status, POST /load, POST /generate ...
/// Loopback only: nothing is reachable from the network. Every request needs the token shown in the app.
final class ControlServer: @unchecked Sendable {
    static let shared = ControlServer()
    let port: UInt16 = 8765
    private var listener: NWListener?
    private var listeners: [NWListener] = []
    private let queue = DispatchQueue(label: "looplab.control")
    private(set) var token: String = {
        if let t = UserDefaults.standard.string(forKey: "controlToken") { return t }
        let t = String((0..<16).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
        UserDefaults.standard.set(t, forKey: "controlToken")
        return t
    }()
    private(set) var running = false
    private(set) var requests = 0

    typealias Handler = @Sendable (_ method: String, _ path: String, _ query: [String: String], _ body: [String: Any]) async -> (Int, Any)
    var handler: Handler?

    /// Listen on loopback always; on the tailnet address too when available, so a paired machine
    /// (or a scheduled job on the desktop) can reach this API without changing the phone's VPN setting.
    private(set) var boundHosts: [String] = []

    func start() {
        guard listener == nil else { return }
        boundHosts = []
        bind(host: "127.0.0.1")
        if let ts = NetInfo.tailscaleIPv4() { bind(host: ts) }
    }

    private func bind(host: String) {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .ready:
                    self.running = true
                    self.boundHosts.append(host)
                    Log.shared.add("control server on \(host):\(self.port)")
                case .failed(let e):
                    Log.shared.add("control server on \(host) failed: \(e)")
                    if host == "127.0.0.1" { self.running = false }
                case .cancelled: break
                default: break
                }
            }
            l.start(queue: queue)
            listeners.append(l)
            if listener == nil { listener = l }
        } catch {
            Log.shared.add("control server bind \(host) error: \(error)")
        }
    }

    func restart() {
        listeners.forEach { $0.cancel() }
        listeners = []; listener = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                self.requests += 1
                Task { await self.respond(c, req) }
            } else if done || err != nil {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    struct Request { var method: String; var path: String; var query: [String: String]; var headers: [String: String]; var body: Data }

    static func parse(_ d: Data) -> Request? {
        guard let headEnd = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: d[..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        guard d.count - bodyStart >= len else { return nil }
        let target = String(first[1])
        var path = target, query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for kv in target[target.index(after: q)...].split(separator: "&") {
                let p = kv.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                query[p[0]] = p.count > 1 ? p[1] : ""
            }
        }
        return Request(method: String(first[0]), path: path, query: query, headers: headers, body: d[bodyStart..<(bodyStart + len)])
    }

    private func respond(_ c: NWConnection, _ r: Request) async {
        var status = 200
        var payload: Any = [:]
        let auth = r.headers["x-token"] ?? r.query["token"]
        if r.path != "/ping" && auth != token {
            status = 401; payload = ["error": "missing or wrong token (see the app's Control tab)"]
        } else {
            let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
            if let handler { (status, payload) = await handler(r.method, r.path, r.query, body) }
        }
        let json = (try? JSONSerialization.data(withJSONObject: Self.sanitize(payload), options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "ERR")\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(json)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    /// JSONSerialization rejects NaN/inf and non-JSON types; make anything printable.
    static func sanitize(_ v: Any) -> Any {
        switch v {
        case let d as [String: Any]: return d.mapValues { sanitize($0) }
        case let a as [Any]: return a.map { sanitize($0) }
        case let x as Double: return x.isFinite ? x : "\(x)"
        case let x as Float: return x.isFinite ? Double(x) : "\(x)"
        case is String, is Int, is Bool, is NSNumber, is NSNull: return v
        case let x as UInt64: return x
        case let x as Int64: return x
        case let x as UInt: return x
        default: return "\(v)"
        }
    }
}

/// In-memory ring log, readable at GET /log and in the app.
final class Log: @unchecked Sendable {
    static let shared = Log()
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)"
        lock.lock(); lines.append(line); if lines.count > 500 { lines.removeFirst(lines.count - 500) }; lock.unlock()
        print(line)
    }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
