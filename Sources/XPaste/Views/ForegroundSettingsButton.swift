import AppKit
import SwiftUI

struct ForegroundSettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    private let beforeOpen: () -> Void
    private let label: () -> Label

    init(
        beforeOpen: @escaping () -> Void = {},
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.beforeOpen = beforeOpen
        self.label = label
    }

    var body: some View {
        Button(action: showSettings) {
            label()
        }
    }

    private func showSettings() {
        beforeOpen()
        openSettings()

        // MenuBarExtra actions finish on the current AppKit tracking turn.
        // Activating on the next turn prevents the previous app reclaiming focus.
        DispatchQueue.main.async {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.windows
                .first(where: { $0.isVisible && $0.canBecomeKey && !($0 is NSPanel) })?
                .makeKeyAndOrderFront(nil)
        }
    }
}
