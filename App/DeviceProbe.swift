import Foundation
import Darwin
import Metal
import UIKit
import os

/// Everything the app can learn about this device without private APIs.
/// Reported over the control API so experiments are always tagged with the hardware state.
enum DeviceProbe {

    static func machineIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        return mirror.children.compactMap { ($0.value as? Int8).flatMap { $0 == 0 ? nil : Character(UnicodeScalar(UInt8($0))) } }
            .map(String.init).joined()
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 { return value }
        var v32: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname(name, &v32, &size, nil, 0) == 0 { return Int64(v32) }
        return nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func thermalString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Bytes this process may still allocate before jetsam. The key number for model sizing.
    static func availableMemory() -> Int { Int(os_proc_available_memory()) }

    /// Resident footprint as the OS accounts it (what jetsam compares against).
    static func physFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : -1
    }

    /// Reads the signed entitlements actually granted (from the embedded provisioning profile).
    static func grantedEntitlements() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<plist"), let end = text.range(of: "</plist>")
        else { return ["profile": "none (unsigned or simulator)"] }
        let plistData = Data(text[start.lowerBound..<end.upperBound].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let ents = plist["Entitlements"] as? [String: Any] else { return ["profile": "unparseable"] }
        var out: [String: String] = [:]
        for (k, v) in ents { out[k] = "\(v)" }
        if let exp = plist["ExpirationDate"] as? Date { out["_profileExpires"] = ISO8601DateFormatter().string(from: exp) }
        if let team = plist["TeamName"] as? String { out["_team"] = team }
        return out
    }

    static func metal() -> [String: Any] {
        guard let dev = MTLCreateSystemDefaultDevice() else { return ["available": false] }
        var families: [String] = []
        let check: [(MTLGPUFamily, String)] = [
            (.apple7, "apple7"), (.apple8, "apple8"), (.apple9, "apple9"), (.metal3, "metal3"),
        ]
        for (f, n) in check where dev.supportsFamily(f) { families.append(n) }
        if #available(iOS 26.0, *) { if dev.supportsFamily(.apple10) { families.append("apple10") } }
        return [
            "available": true,
            "name": dev.name,
            "families": families,
            "recommendedMaxWorkingSetSize": dev.recommendedMaxWorkingSetSize,
            "maxBufferLength": dev.maxBufferLength,
            "maxThreadgroupMemoryLength": dev.maxThreadgroupMemoryLength,
            "maxThreadsPerThreadgroup": [dev.maxThreadsPerThreadgroup.width, dev.maxThreadsPerThreadgroup.height, dev.maxThreadsPerThreadgroup.depth],
            "hasUnifiedMemory": dev.hasUnifiedMemory,
            "supportsRaytracing": dev.supportsRaytracing,
            "supportsDynamicLibraries": dev.supportsDynamicLibraries,
            "readWriteTextureSupport": dev.readWriteTextureSupport.rawValue,
            "argumentBuffersSupport": dev.argumentBuffersSupport.rawValue,
            "currentAllocatedSize": dev.currentAllocatedSize,
        ]
    }

    static func snapshot() -> [String: Any] {
        let pi = ProcessInfo.processInfo
        return [
            "machine": machineIdentifier(),
            "os": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "physicalMemory": pi.physicalMemory,
            "availableToProcess": availableMemory(),
            "physFootprint": physFootprint(),
            "cpu": [
                "activeProcessorCount": pi.activeProcessorCount,
                "processorCount": pi.processorCount,
                "perflevels": sysctlInt("hw.nperflevels") ?? -1,
                "pCores": sysctlInt("hw.perflevel0.physicalcpu") ?? -1,
                "eCores": sysctlInt("hw.perflevel1.physicalcpu") ?? -1,
                "pL2": sysctlInt("hw.perflevel0.l2cachesize") ?? -1,
                "eL2": sysctlInt("hw.perflevel1.l2cachesize") ?? -1,
                "l1d": sysctlInt("hw.l1dcachesize") ?? -1,
                "cacheline": sysctlInt("hw.cachelinesize") ?? -1,
                "pagesize": sysctlInt("hw.pagesize") ?? -1,
                "brand": sysctlString("machdep.cpu.brand_string") ?? "",
            ],
            "thermal": thermalString(),
            "lowPowerMode": pi.isLowPowerModeEnabled,
            "batteryLevel": UIDevice.current.batteryLevel,
            "metal": metal(),
            "entitlements": grantedEntitlements(),
            "uptimeSeconds": pi.systemUptime,
        ]
    }
}
