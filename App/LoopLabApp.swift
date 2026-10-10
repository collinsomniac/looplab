import SwiftUI
import UIKit

@main
struct LoopLabApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            RootView().onOpenURL { url in URLActions.handle(url) }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        ControlServer.shared.handler = { m, p, q, b in await API.handle(m, p, q, b) }
        ControlServer.shared.start()
        Log.shared.add("launch v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") "
                       + "available=\(DeviceProbe.availableMemory() / 1_048_576) MB thermal=\(DeviceProbe.thermalString())")
        return true
    }
}

/// looplab://load?model=qwen3-0.6b · looplab://generate?prompt=hi · looplab://bench · looplab://queue
enum URLActions {
    static func handle(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let host = url.host ?? ""
        Log.shared.add("url action: \(host) \(q)")
        Task { @MainActor in
            switch host {
            case "load": AppState.shared.load(q["model"] ?? "qwen3-0.6b")
            case "generate": AppState.shared.send(q["prompt"] ?? "Hello")
            case "bench": AppState.shared.runTest("metal")
            case "queue": AppState.shared.runQueue()
            case "server": ControlServer.shared.restart()
            default: break
            }
        }
    }
}

struct RootView: View {
    @ObservedObject private var app = AppState.shared
    var body: some View {
        TabView(selection: $app.visibleTab) {
            ChatView().tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.tag("chat")
            QueueView().tabItem { Label("Queue", systemImage: "list.bullet.rectangle") }.tag("queue")
            ModelsView().tabItem { Label("Models", systemImage: "cube.box") }.tag("models")
            TestsView().tabItem { Label("Tests", systemImage: "gauge.with.dots.needle.50percent") }.tag("tests")
            DeviceView().tabItem { Label("Device", systemImage: "cpu") }.tag("device")
        }
    }
}
