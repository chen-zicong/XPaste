import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        AppEnvironment.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.shared.stop()
    }
}

@main
struct XPasteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let environment = AppEnvironment.shared

    var body: some Scene {
        MenuBarExtra("XPaste", systemImage: environment.settings.isMonitoringEnabled ? "doc.on.clipboard" : "pause.circle") {
            MenuBarContentView(model: environment.model)
        }
        .menuBarExtraStyle(.menu)

    }
}

private struct MenuBarContentView: View {
    let model: AppModel

    var body: some View {
        Button("打开历史") { AppEnvironment.shared.showPanel(page: .history) }
            .keyboardShortcut("v", modifiers: [.control, .option])
        Button("打开收藏") { AppEnvironment.shared.showPanel(page: .favorites) }
        Button("存储统计") { AppEnvironment.shared.showPanel(page: .statistics) }

        Divider()

        Button(model.settings.isMonitoringEnabled ? "暂停记录" : "继续记录") {
            model.settings.isMonitoringEnabled.toggle()
        }

        Divider()

        ForegroundSettingsButton(
            beforeOpen: { model.onHideRequest?() }
        ) {
            Text("设置…")
        }
        Button("退出 XPaste") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
