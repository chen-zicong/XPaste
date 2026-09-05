import AppKit
import SwiftUI

/// Keeps an exact reference to Settings, including while closed or minimized.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: AppModel, accessibilityPermission: AccessibilityPermissionController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "XPaste 设置"
        window.identifier = NSUserInterfaceItemIdentifier("XPaste.Settings")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: SettingsView(
            model: model,
            accessibilityPermission: accessibilityPermission
        ))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        // Accessory apps need explicit activation when invoked from another app.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
