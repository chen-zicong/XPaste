import AppKit
import ApplicationServices
import Observation

struct AccessibilityPermissionSnapshot: Equatable, Sendable {
    let isProcessTrusted: Bool
    let canPostEvents: Bool

    /// `CGPreflightPostEventAccess` is the capability-specific check. Some macOS
    /// versions briefly report it as false after the user enables XPaste in the
    /// Accessibility pane, so the canonical Accessibility trust check is also
    /// accepted instead of incorrectly telling the user they are unauthorized.
    var isAuthorized: Bool {
        canPostEvents || isProcessTrusted
    }
}

@MainActor
@Observable
final class AccessibilityPermissionController {
    private(set) var snapshot: AccessibilityPermissionSnapshot

    @ObservationIgnored private let processTrusted: () -> Bool
    @ObservationIgnored private let preflightPostEventAccess: () -> Bool
    @ObservationIgnored private let requestPostEventAccess: () -> Bool
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        processTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        preflightPostEventAccess: @escaping () -> Bool = { CGPreflightPostEventAccess() },
        requestPostEventAccess: @escaping () -> Bool = { CGRequestPostEventAccess() }
    ) {
        self.processTrusted = processTrusted
        self.preflightPostEventAccess = preflightPostEventAccess
        self.requestPostEventAccess = requestPostEventAccess
        snapshot = AccessibilityPermissionSnapshot(
            isProcessTrusted: processTrusted(),
            canPostEvents: preflightPostEventAccess()
        )
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        refreshTask?.cancel()
    }

    var isAuthorized: Bool {
        snapshot.isAuthorized
    }

    /// Re-check whenever XPaste becomes active. This covers the common flow in
    /// which the user enables XPaste in System Settings and then returns here.
    func startMonitoring() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refresh()
    }

    func stopMonitoring() {
        refreshTask?.cancel()
        refreshTask = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    @discardableResult
    func refresh() -> Bool {
        snapshot = AccessibilityPermissionSnapshot(
            isProcessTrusted: processTrusted(),
            canPostEvents: preflightPostEventAccess()
        )
        return snapshot.isAuthorized
    }

    /// The system prompt completes asynchronously on recent macOS releases.
    /// Re-check briefly afterwards, while also refreshing on app activation.
    @discardableResult
    func requestAuthorization() -> Bool {
        _ = requestPostEventAccess()
        let authorized = refresh()
        if !authorized {
            scheduleFollowUpRefreshes()
        }
        return authorized
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func scheduleFollowUpRefreshes() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            for delay in [250, 750, 1_500] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self else { return }
                if self.refresh() { return }
            }
        }
    }
}
