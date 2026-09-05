import AppKit
import SwiftUI

struct ForegroundSettingsButton<Label: View>: View {
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
        // MenuBarExtra actions finish on the current AppKit tracking turn.
        // Present after tracking ends so menu dismissal cannot reclaim focus.
        DispatchQueue.main.async {
            AppEnvironment.shared.showSettings()
        }
    }
}
