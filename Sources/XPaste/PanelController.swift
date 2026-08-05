import AppKit
import ApplicationServices
import SwiftUI

private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct PanelCopyRequest: Sendable, Equatable {
    let sessionID: UUID
    let requestID: UUID
    let itemID: UUID
    let targetApplicationPID: pid_t?
    let autoPaste: Bool
    let keepPanelVisible: Bool
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let accessibilityPermission: AccessibilityPermissionController
    private let panel: ClipboardPanel
    private let targetApplicationProvider: () -> pid_t?
    private var localEventMonitor: Any?
    private var isCompletingCopy = false
    private var hasAcquiredKey = false
    private var pasteWorkItem: DispatchWorkItem?
    private var targetApplicationPID: pid_t?
    private var presentationID = UUID()
    private var activeRequestID: UUID?
    var onHidden: (() -> Void)?
    var onSessionInvalidated: (() -> Void)?
    var onPasteEventSent: ((UUID) -> Void)?
    var isVisible: Bool { panel.isVisible }

    init(
        model: AppModel,
        accessibilityPermission: AccessibilityPermissionController,
        targetApplicationProvider: @escaping () -> pid_t?
    ) {
        self.model = model
        self.accessibilityPermission = accessibilityPermission
        self.targetApplicationProvider = targetApplicationProvider
        self.panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        installKeyMonitor()
        installWorkspaceObserver()
        model.onPanelLayoutChange = { [weak self] page, detailVisible in
            self?.updatePanelLayout(page: page, detailVisible: detailVisible, animated: true)
        }
        model.onPanelPinChange = { [weak self] isPinned in
            self?.panelPinStateDidChange(isPinned)
        }
        updatePanelLayout(page: model.page, detailVisible: model.isDetailVisible, animated: false)
    }

    deinit {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func toggleHistory() {
        if panel.isVisible, model.page == .history {
            hide()
        } else {
            show(page: .history)
        }
    }

    func show(page: PanelPage) {
        invalidateSessionPreservingVisibility()
        let currentPresentationID = presentationID
        let wasVisible = panel.isVisible
        if !wasVisible {
            model.query = ""
            model.isDetailVisible = false
            targetApplicationPID = targetApplicationProvider()
        }
        hasAcquiredKey = false
        model.show(page: page, resetSelection: !wasVisible)
        panel.orderFrontRegardless()
        positionOnPointerScreen(ifNeeded: !wasVisible)
        panel.makeKey()
        // Wait one run-loop turn for SwiftUI to attach the field editor, but do
        // not use a delayed second focus request: it could steal focus back
        // after the user had already clicked or started keyboard navigation.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.presentationID == currentPresentationID,
                  self.panel.isVisible,
                  self.panel.isKeyWindow else { return }
            self.model.focusSearch()
        }
    }

    func hide(invalidateSession: Bool = true) {
        if invalidateSession {
            invalidateSessionPreservingVisibility()
        }
        hasAcquiredKey = false
        panel.orderOut(nil)
        onHidden?()
    }

    func makeCopyRequest(itemID: UUID, autoPaste: Bool) -> PanelCopyRequest {
        if model.isPanelPinned {
            let currentTarget = targetApplicationProvider()
            if currentTarget != targetApplicationPID {
                invalidateSessionPreservingVisibility()
                targetApplicationPID = currentTarget
            }
        }
        pasteWorkItem?.cancel()
        pasteWorkItem = nil
        isCompletingCopy = false
        let requestID = UUID()
        activeRequestID = requestID
        return PanelCopyRequest(
            sessionID: presentationID,
            requestID: requestID,
            itemID: itemID,
            targetApplicationPID: targetApplicationPID,
            autoPaste: autoPaste,
            keepPanelVisible: model.isPanelPinned
        )
    }

    func isCurrent(_ request: PanelCopyRequest) -> Bool {
        request.sessionID == presentationID && request.requestID == activeRequestID
    }

    func completeCopy(_ request: PanelCopyRequest) {
        guard isCurrent(request) else { return }
        pasteWorkItem?.cancel()
        pasteWorkItem = nil

        guard request.autoPaste else {
            activeRequestID = nil
            model.showToast("已复制到剪贴板")
            if model.settings.closeAfterCopy, !request.keepPanelVisible { hide() }
            return
        }

        guard let targetPID = request.targetApplicationPID,
              let targetApplication = NSRunningApplication(processIdentifier: targetPID),
              !targetApplication.isTerminated else {
            activeRequestID = nil
            model.showToast("未找到唤起前的应用；内容已复制")
            return
        }

        if request.keepPanelVisible {
            guard targetApplicationProvider() == targetPID, targetApplication.isActive else {
                failPaste(request, message: "当前应用已切换；内容已复制", revealPanel: false)
                return
            }
        }

        if !accessibilityPermission.refresh() {
            let granted = accessibilityPermission.requestAuthorization()
            guard granted || accessibilityPermission.refresh() else {
                activeRequestID = nil
                model.showToast("内容已复制；允许辅助功能后再选择一次即可粘贴")
                return
            }
            guard isCurrent(request) else { return }
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            activeRequestID = nil
            model.showToast("无法生成粘贴事件；内容已复制")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        isCompletingCopy = true
        if request.keepPanelVisible {
            schedulePasteEvent(
                request,
                targetPID: targetPID,
                keyDown: keyDown,
                keyUp: keyUp
            )
            return
        }
        if !targetApplication.isActive {
            guard targetApplication.activate(options: []) else {
                failPaste(request, message: "无法返回原应用；内容已复制", revealPanel: false)
                return
            }
            waitForTargetActivation(
                request,
                targetPID: targetPID,
                keyDown: keyDown,
                keyUp: keyUp,
                attemptsRemaining: 20
            )
        } else {
            if !request.keepPanelVisible { hide(invalidateSession: false) }
            schedulePasteEvent(
                request,
                targetPID: targetPID,
                keyDown: keyDown,
                keyUp: keyUp
            )
        }
    }

    private func waitForTargetActivation(
        _ request: PanelCopyRequest,
        targetPID: pid_t,
        keyDown: CGEvent,
        keyUp: CGEvent,
        attemptsRemaining: Int
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrent(request) else { return }
            guard let application = NSRunningApplication(processIdentifier: targetPID) else {
                self.failPaste(request, message: "原应用已退出；内容已复制", revealPanel: false)
                return
            }
            guard !application.isTerminated else {
                self.failPaste(request, message: "原应用已退出；内容已复制", revealPanel: false)
                return
            }
            if application.isActive {
                if !request.keepPanelVisible { self.hide(invalidateSession: false) }
                self.schedulePasteEvent(
                    request,
                    targetPID: targetPID,
                    keyDown: keyDown,
                    keyUp: keyUp
                )
            } else if attemptsRemaining > 0 {
                self.waitForTargetActivation(
                    request,
                    targetPID: targetPID,
                    keyDown: keyDown,
                    keyUp: keyUp,
                    attemptsRemaining: attemptsRemaining - 1
                )
            } else {
                self.failPaste(request, message: "无法返回原应用；内容已复制", revealPanel: false)
            }
        }
        pasteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func schedulePasteEvent(
        _ request: PanelCopyRequest,
        targetPID: pid_t,
        keyDown: CGEvent,
        keyUp: CGEvent
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrent(request),
                  let application = NSRunningApplication(processIdentifier: targetPID),
                  !application.isTerminated,
                  application.isActive,
                  !request.keepPanelVisible || self.targetApplicationProvider() == targetPID else {
                self?.failPaste(request, message: "未能自动粘贴；内容已复制", revealPanel: true)
                return
            }
            // Post through the HID event tap after the destination is active.
            // Process-targeted events are ignored by Finder and by several IM
            // clients even though the same physical Command-V works there.
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            self.finishPaste(request)
        }
        pasteWorkItem = workItem
        // Activation can be reported before the destination has restored its
        // first responder. A short settle interval avoids losing the paste in
        // Finder and Chromium/Electron-based message editors.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func finishPaste(_ request: PanelCopyRequest) {
        guard isCurrent(request) else { return }
        activeRequestID = nil
        pasteWorkItem = nil
        isCompletingCopy = false
        if request.keepPanelVisible {
            model.showToast("已向当前应用发送粘贴")
        }
        onPasteEventSent?(request.itemID)
    }

    private func failPaste(_ request: PanelCopyRequest, message: String, revealPanel: Bool) {
        guard isCurrent(request) else { return }
        activeRequestID = nil
        pasteWorkItem = nil
        isCompletingCopy = false
        model.showToast(message)
        if revealPanel, !panel.isVisible {
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        hasAcquiredKey = true
    }

    func windowDidResignKey(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--ui-test") { return }
        guard panel.isVisible, hasAcquiredKey, !model.isPanelPinned,
              !isCompletingCopy, panel.attachedSheet == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.model.isPanelPinned,
                  !self.panel.isKeyWindow, self.panel.attachedSheet == nil else { return }
            self.hide()
        }
    }

    private func panelPinStateDidChange(_ isPinned: Bool) {
        invalidateSessionPreservingVisibility()
        targetApplicationPID = targetApplicationProvider()
        if isPinned, panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func invalidateSessionPreservingVisibility() {
        presentationID = UUID()
        activeRequestID = nil
        pasteWorkItem?.cancel()
        pasteWorkItem = nil
        isCompletingCopy = false
        onSessionInvalidated?()
    }

    private func externalApplicationDidActivate() {
        guard panel.isVisible, model.isPanelPinned else { return }
        let currentTarget = targetApplicationProvider()
        guard targetApplicationPID != currentTarget else { return }
        invalidateSessionPreservingVisibility()
        targetApplicationPID = currentTarget
    }

    private func configurePanel() {
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: MainPanelView(model: model))
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.title = "XPaste"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.tabbingMode = .disallowed
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 760, height: 500)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }

    private func updatePanelLayout(page: PanelPage, detailVisible: Bool, animated: Bool) {
        let expanded = page == .statistics || detailVisible
        let targetWidth: CGFloat = expanded ? 920 : 620
        panel.minSize = NSSize(width: expanded ? 760 : 560, height: 500)

        let screen = panel.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame
        let width = min(targetWidth, max(560, (visibleFrame?.width ?? targetWidth) - 32))
        guard abs(panel.frame.width - width) > 0.5 else { return }

        var frame = panel.frame
        let midpoint = frame.midX
        frame.size.width = width
        frame.origin.x = midpoint - width / 2
        if let visibleFrame {
            frame.origin.x = min(
                max(frame.origin.x, visibleFrame.minX + 16),
                visibleFrame.maxX - width - 16
            )
        }
        panel.setFrame(frame, display: panel.isVisible, animate: animated && panel.isVisible)
    }

    private func positionOnPointerScreen(ifNeeded: Bool) {
        guard ifNeeded else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        var size = panel.frame.size
        size.width = min(max(size.width, panel.minSize.width), frame.width - 32)
        size.height = min(max(size.height, panel.minSize.height), frame.height - 32)
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 18
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func installKeyMonitor() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func installWorkspaceObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func workspaceApplicationDidActivate(_ notification: Notification) {
        externalApplicationDidActivate()
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let textView = panel.firstResponder as? NSTextView
        let editingBody = textView?.isFieldEditor == false
        let textInputActive = textView != nil
        let hasMarkedText = textView?.hasMarkedText() ?? false
        let isListPage = model.page != .statistics
        let hasNavigationModifiers = !flags.intersection([.command, .option, .control, .shift]).isEmpty

        if command {
            if event.keyCode == 51 {
                guard isListPage, !textInputActive else { return false }
                if let item = model.selectedItem { model.delete(item) }
                return true
            }
            switch event.charactersIgnoringModifiers {
            case "1": model.show(page: .history); return true
            case "2": model.show(page: .favorites); return true
            case "f": model.focusSearch(); return true
            case "i" where isListPage: model.toggleDetails(); return true
            case "d" where isListPage:
                if let item = model.selectedItem { model.toggleFavorite(item) }
                return true
            case "e" where isListPage:
                if let item = model.selectedItem, item.kind == .image { model.imageEditorItem = item }
                return itemCanBeEdited
            case "\r" where isListPage && !hasMarkedText: model.copySelected(autoPaste: true); return true
            case "c" where isListPage && !textInputActive:
                model.copySelected(autoPaste: false)
                return true
            default: break
            }
        }

        if event.keyCode == 53 {
            if hasMarkedText { return false }
            if model.isDetailVisible {
                model.isDetailVisible = false
            } else if !model.query.isEmpty {
                model.query = ""
            } else {
                hide()
            }
            return true
        }
        let horizontalDirection: PanelHorizontalDirection? = switch event.keyCode {
        case 123: .left
        case 124: .right
        default: nil
        }
        if let horizontalDirection,
           let destination = PanelNavigationPolicy.destination(
               currentPage: model.page,
               direction: horizontalDirection,
               hasDisallowedModifiers: hasNavigationModifiers,
               isEditingBody: editingBody,
               searchIsEmpty: model.query.isEmpty,
               hasMarkedText: hasMarkedText
           ) {
            if destination != model.page { model.show(page: destination) }
            return true
        }
        let allowsVerticalSelection = PanelNavigationPolicy.allowsVerticalSelection(
            isListPage: isListPage,
            hasDisallowedModifiers: hasNavigationModifiers,
            isEditingBody: editingBody,
            hasMarkedText: hasMarkedText
        )
        if allowsVerticalSelection, event.keyCode == 125 { model.selectNext(offset: 1); return true }
        if allowsVerticalSelection, event.keyCode == 126 { model.selectNext(offset: -1); return true }
        if event.keyCode == 49,
           PanelNavigationPolicy.allowsDetailToggle(
               isListPage: isListPage,
               hasSelection: model.selectedItem != nil,
               hasDisallowedModifiers: hasNavigationModifiers,
               isEditingBody: editingBody,
               isTextInputActive: textInputActive,
               searchIsEmpty: model.query.isEmpty,
               hasMarkedText: hasMarkedText
           ) {
            model.toggleDetails()
            return true
        }
        if isListPage, !editingBody, !hasMarkedText, event.keyCode == 36 {
            model.copySelected(autoPaste: true)
            return true
        }
        return false
    }

    private var itemCanBeEdited: Bool {
        model.selectedItem?.kind == .image
    }
}
