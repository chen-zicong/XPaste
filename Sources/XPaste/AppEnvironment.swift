import AppKit
import ApplicationServices
import Foundation
import XPasteCore

@MainActor
final class AppEnvironment {
    private struct ShortcutPair {
        let history: GlobalShortcut
        let favorites: GlobalShortcut
    }

    static let shared = AppEnvironment()

    let settings: AppSettings
    let repository: HistoryRepository
    let model: AppModel
    let accessibilityPermission = AccessibilityPermissionController()
    let monitor = ClipboardMonitor()
    let hotKeys = GlobalHotKeyManager()
    let isUITest: Bool
    let isIntegrationTest: Bool
    let dataURL: URL

    private(set) var panelController: PanelController?
    private var panelReleaseTask: Task<Void, Never>?
    private var monitorHandlersReady = false
    private var appliedMaxItems: Int?
    private var publishTask: Task<Void, Never>?
    private var activePublishID: UUID?
    private var shortcutApplyTask: Task<Void, Never>?
    private var lastValidShortcuts: ShortcutPair?

    private init() {
        isUITest = ProcessInfo.processInfo.arguments.contains("--ui-test")
        isIntegrationTest = ProcessInfo.processInfo.arguments.contains("--integration-test")
        if isUITest || isIntegrationTest {
            dataURL = ProcessInfo.processInfo.environment["XPASTE_DATA_DIRECTORY"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("XPaste-Test-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            let defaults = UserDefaults(suiteName: "XPaste-Test-\(ProcessInfo.processInfo.processIdentifier)")!
            settings = AppSettings(defaults: defaults)
        } else {
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dataURL = applicationSupport.appendingPathComponent("XPaste", isDirectory: true)
            settings = AppSettings()
        }
        repository = HistoryRepository(baseURL: dataURL)
        model = AppModel(settings: settings, repository: repository)
        if isUITest, ProcessInfo.processInfo.arguments.contains("--ui-test-stats") {
            model.page = .statistics
        }
    }

    func start() {
        accessibilityPermission.startMonitoring()
        model.onCopyRequest = { [weak self] item, autoPaste in
            self?.publish(item, autoPaste: autoPaste)
        }
        model.onHideRequest = { [weak self] in self?.panelController?.hide() }

        hotKeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .history:
                self.toggleHistoryPanel()
            case .favorites:
                self.showPanel(page: .favorites)
            }
        }
        settings.onChange = { [weak self] change in self?.apply(change) }
        applySettings()

        Task { [weak self] in
            guard let self else { return }
            await self.monitor.setHandlers(
                onCapture: { [weak self] capture in
                    guard let self, self.settings.isMonitoringEnabled, !self.isUITest else { return }
                    self.model.record(capture)
                },
                onAccessStateChange: { [weak self] denied in
                    self?.model.pasteboardAccessDenied = denied
                }
            )
            self.monitorHandlersReady = true
            self.applyMonitoringSettings()
        }

        Task { [weak self] in
            guard let self else { return }
            await self.model.start(seedDemoData: self.isUITest)
            if self.isUITest {
                let page: PanelPage = ProcessInfo.processInfo.arguments.contains("--ui-test-stats") ? .statistics : .history
                self.showPanel(page: page)
                if ProcessInfo.processInfo.arguments.contains("--ui-test-expanded") {
                    self.model.showDetails()
                }
            }
        }
    }

    func showPanel(page: PanelPage) {
        ensurePanelController().show(page: page)
    }

    func toggleHistoryPanel() {
        ensurePanelController().toggleHistory()
    }

    func stop() {
        accessibilityPermission.stopMonitoring()
        shortcutApplyTask?.cancel()
        cancelPendingPublish()
        Task { await monitor.stop() }
        if isUITest { try? FileManager.default.removeItem(at: dataURL) }
    }

    func applySettings() {
        applyMonitoringSettings()
        applyShortcutSettings()
        applyMaxItemsSetting()
        model.refreshVisibleItemsForSettings()
    }

    private func apply(_ change: SettingsChange) {
        switch change {
        case .shortcuts:
            scheduleShortcutApply()
        case .monitoring:
            applyMonitoringSettings()
        case .historySort:
            model.refreshVisibleItemsForSettings()
        case .maxItems:
            applyMaxItemsSetting()
        case .other:
            break
        }
    }

    private func applyMonitoringSettings() {
        guard monitorHandlersReady else { return }
        let enabled = settings.isMonitoringEnabled && !isUITest
        let interval = settings.pollInterval
        Task { await monitor.configure(enabled: enabled, interval: interval) }
    }

    private func applyShortcutSettings() {
        if settings.historyShortcut == settings.favoritesShortcut {
            restoreLastValidShortcuts(
                message: "历史和收藏快捷键不能相同；已恢复上一次可用组合"
            )
        } else {
            let conflicts = hotKeys.register(history: settings.historyShortcut, favorites: settings.favoritesShortcut)
            if conflicts.isEmpty {
                lastValidShortcuts = ShortcutPair(
                    history: settings.historyShortcut,
                    favorites: settings.favoritesShortcut
                )
                model.shortcutConflictMessage = nil
            } else {
                let names = conflicts.map { $0 == .history ? "历史" : "收藏" }.sorted().joined(separator: "、")
                restoreLastValidShortcuts(
                    message: "\(names)快捷键不可用；已恢复上一次可用组合"
                )
            }
        }
    }

    private func applyMaxItemsSetting() {
        if appliedMaxItems != settings.maxItems {
            appliedMaxItems = settings.maxItems
            model.enforceCurrentLimit()
        }
    }

    private func publish(_ item: ClipboardItem, autoPaste: Bool) {
        guard let panelController else { return }
        let request = panelController.makeCopyRequest(itemID: item.id, autoPaste: autoPaste)
        publishTask?.cancel()
        let publishID = UUID()
        activePublishID = publishID

        publishTask = Task { [weak self, weak panelController] in
            guard let self, let panelController else { return }
            defer {
                if self.activePublishID == publishID {
                    self.activePublishID = nil
                    self.publishTask = nil
                }
            }

            guard !Task.isCancelled,
                  activePublishID == publishID,
                  panelController.isCurrent(request) else { return }

            let content: ClipboardPublish
            switch item.kind {
            case .text:
                content = .text(item.text ?? "")
            case .files:
                do {
                    let report = try await repository.resolveFileReferences(id: item.id)
                    guard !report.availableURLs.isEmpty else {
                        if report.entries.contains(where: { $0.availability == .authorizationRequired }) {
                            model.errorMessage = HistoryRepositoryError.fileAuthorizationRequired.localizedDescription
                        } else {
                            model.errorMessage = HistoryRepositoryError.fileReferenceUnavailable.localizedDescription
                        }
                        return
                    }
                    if report.unavailableCount > 0 {
                        model.showToast("已跳过 \(report.unavailableCount) 个不可用文件")
                    }
                    content = .files(report.availableURLs)
                } catch {
                    model.errorMessage = error.localizedDescription
                    return
                }
            case .image:
                guard let fileName = item.imageFileName else {
                    model.errorMessage = "图片文件已丢失"
                    return
                }
                let url = repository.assetURL(fileName: fileName)
                guard let data = try? await Task.detached(priority: .userInitiated, operation: {
                    try Data(contentsOf: url, options: .mappedIfSafe)
                }).value else {
                    if !Task.isCancelled,
                       activePublishID == publishID,
                       panelController.isCurrent(request) {
                        model.errorMessage = "图片文件已丢失"
                    }
                    return
                }
                content = .image(data)
            }

            guard !Task.isCancelled,
                  activePublishID == publishID,
                  panelController.isCurrent(request) else { return }
            guard await monitor.publish(content) else {
                if !Task.isCancelled,
                   activePublishID == publishID,
                   panelController.isCurrent(request) {
                    model.errorMessage = "写入系统剪贴板失败"
                }
                return
            }
            guard !Task.isCancelled,
                  activePublishID == publishID,
                  panelController.isCurrent(request) else { return }
            panelController.completeCopy(request)
        }
    }

    private func ensurePanelController() -> PanelController {
        panelReleaseTask?.cancel()
        if let panelController { return panelController }
        let controller = PanelController(
            model: model,
            accessibilityPermission: accessibilityPermission
        ) { [weak self] in
            self?.preferredExternalApplicationPID()
        }
        controller.onHidden = { [weak self, weak controller] in
            self?.schedulePanelRelease(controller)
        }
        controller.onSessionInvalidated = { [weak self] in
            self?.cancelPendingPublish()
        }
        controller.onPasteEventSent = { [weak self] itemID in
            Task { [weak self] in
                await self?.model.recordPasteEventSent(id: itemID)
            }
        }
        panelController = controller
        return controller
    }

    private func cancelPendingPublish() {
        publishTask?.cancel()
        publishTask = nil
        activePublishID = nil
    }

    private func scheduleShortcutApply() {
        shortcutApplyTask?.cancel()
        shortcutApplyTask = Task { [weak self] in
            // Yield once so the recorder can redraw before Carbon registration runs.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.applyShortcutSettings()
            self.shortcutApplyTask = nil
        }
    }

    private func restoreLastValidShortcuts(message: String) {
        if lastValidShortcuts == nil {
            let fallback = ShortcutPair(history: .defaultHistory, favorites: .defaultFavorites)
            let fallbackConflicts = hotKeys.register(
                history: fallback.history,
                favorites: fallback.favorites
            )
            if fallbackConflicts.isEmpty {
                lastValidShortcuts = fallback
                settings.restoreShortcutsWithoutNotification(
                    history: fallback.history,
                    favorites: fallback.favorites
                )
                model.shortcutConflictMessage = "所选快捷键不可用；已恢复默认组合"
                return
            }
        }
        guard let lastValidShortcuts else {
            model.shortcutConflictMessage = message.replacingOccurrences(
                of: "已恢复上一次可用组合",
                with: "请选择其他组合"
            )
            return
        }
        _ = hotKeys.register(
            history: lastValidShortcuts.history,
            favorites: lastValidShortcuts.favorites
        )
        settings.restoreShortcutsWithoutNotification(
            history: lastValidShortcuts.history,
            favorites: lastValidShortcuts.favorites
        )
        model.shortcutConflictMessage = message
    }

    private func preferredExternalApplicationPID() -> pid_t? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !isXPaste(application),
              !application.isTerminated else { return nil }
        return application.processIdentifier
    }

    private func isXPaste(_ application: NSRunningApplication) -> Bool {
        application.processIdentifier == ProcessInfo.processInfo.processIdentifier ||
            application.bundleIdentifier == "com.chenzicong.xpaste"
    }

    private func schedulePanelRelease(_ controller: PanelController?) {
        panelReleaseTask?.cancel()
        panelReleaseTask = Task { [weak self, weak controller] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled,
                  let self,
                  let controller,
                  self.panelController === controller,
                  !controller.isVisible else { return }
            self.panelController = nil
            await ThumbnailCache.shared.removeAll()
        }
    }
}
