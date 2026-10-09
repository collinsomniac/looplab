import Foundation

/// Interface inventory, used to find the Tailscale address so the control API can be reached
/// from the tailnet without disturbing the user's VPN choice.
enum NetInfo {

    struct Addr { var name: String; var address: String; var family: String }

    static func addresses() -> [Addr] {
        var out: [Addr] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            if let sa = ifa.ifa_addr {
                let fam = sa.pointee.sa_family
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let addr = String(cString: host)
                    if fam == UInt8(AF_INET) { out.append(Addr(name: name, address: addr, family: "ipv4")) }
                    else if fam == UInt8(AF_INET6) && !addr.hasPrefix("fe80") { out.append(Addr(name: name, address: addr, family: "ipv6")) }
                }
            }
            ptr = ifa.ifa_next
        }
        return out
    }

    /// Tailscale uses the CGNAT range 100.64.0.0/10.
    static func tailscaleIPv4() -> String? {
        addresses().first { a in
            guard a.family == "ipv4" else { return false }
            let parts = a.address.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { return false }
            return parts[0] == 100 && (64...127).contains(parts[1])
        }?.address
    }

    static func summary() -> [String: Any] {
        ["tailscaleIPv4": tailscaleIPv4() ?? "none", "addresses": addresses().map { ["if": $0.name, "addr": $0.address, "fam": $0.family] }]
    }
}
