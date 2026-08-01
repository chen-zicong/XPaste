import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A focused AppKit control keeps shortcut capture local to the active field.
/// This avoids installing a view-wide event monitor every time Settings redraws.
struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: GlobalShortcut
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(shortcut: $shortcut)
    }

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.shortcut = shortcut
        button.shortcutDidChange = { [weak coordinator = context.coordinator] shortcut in
            coordinator?.shortcut.wrappedValue = shortcut
        }
        button.recorderAccessibilityLabel = accessibilityLabel
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        context.coordinator.shortcut = $shortcut
        button.recorderAccessibilityLabel = accessibilityLabel
        if !button.isRecording {
            button.shortcut = shortcut
        }
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: Coordinator) {
        button.cancelRecording()
    }

    @MainActor
    final class Coordinator {
        var shortcut: Binding<GlobalShortcut>

        init(shortcut: Binding<GlobalShortcut>) {
            self.shortcut = shortcut
        }
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var shortcut = GlobalShortcut.defaultHistory {
        didSet {
            guard !isRecording else { return }
            refreshAppearance()
        }
    }

    var shortcutDidChange: ((GlobalShortcut) -> Void)?
    var recorderAccessibilityLabel = "全局快捷键" {
        didSet { refreshAccessibility() }
    }

    private(set) var isRecording = false
    private var feedbackMessage: String?
    private var feedbackReset: DispatchWorkItem?
    private var outsideClickMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 138, height: 28)
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign, isRecording {
            finishRecording()
        }
        return didResign
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        guard !event.isARepeat else { return }

        // Escape always cancels and leaves the existing shortcut untouched.
        if event.keyCode == UInt16(kVK_Escape) {
            finishRecording()
            window?.makeFirstResponder(nil)
            return
        }

        let modifiers = carbonModifiers(from: event.modifierFlags)
        let recordedShortcut = GlobalShortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: modifiers
        )
        guard recordedShortcut.isReasonable else {
            showFeedback("需搭配 ⌘、⌥ 或 ⌃；F 键可单独使用")
            return
        }
        shortcut = recordedShortcut
        shortcutDidChange?(recordedShortcut)
        finishRecording()
        window?.makeFirstResponder(nil)
    }

    private func configure() {
        target = self
        action = #selector(beginRecording)
        bezelStyle = .rounded
        controlSize = .regular
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        focusRingType = .exterior
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        refreshAppearance()
    }

    @objc private func beginRecording() {
        feedbackReset?.cancel()
        feedbackMessage = nil
        isRecording = true
        refreshAppearance()
        window?.makeFirstResponder(self)
        installOutsideClickMonitor()
    }

    func cancelRecording() {
        finishRecording()
    }

    private func finishRecording() {
        feedbackReset?.cancel()
        feedbackMessage = nil
        isRecording = false
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        refreshAppearance()
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isRecording, event.window === self.window else { return event }
            let location = self.convert(event.locationInWindow, from: nil)
            if !self.bounds.contains(location) {
                self.finishRecording()
            }
            return event
        }
    }

    private func showFeedback(_ message: String) {
        NSSound.beep()
        feedbackReset?.cancel()
        feedbackMessage = message
        refreshAppearance()

        let reset = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            self.feedbackMessage = nil
            self.refreshAppearance()
        }
        feedbackReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: reset)
    }

    private func refreshAppearance() {
        if let feedbackMessage {
            title = feedbackMessage
            contentTintColor = .systemOrange
        } else if isRecording {
            title = "请按组合键…"
            contentTintColor = .controlAccentColor
        } else {
            title = shortcut.displayName
            contentTintColor = .labelColor
        }
        toolTip = isRecording
            ? "按下新的组合键；按 Esc 取消"
            : "点击后录制新的全局快捷键"
        refreshAccessibility()
    }

    private func refreshAccessibility() {
        setAccessibilityLabel(recorderAccessibilityLabel)
        setAccessibilityValue(
            isRecording
                ? "录制中，请按组合键；按 Escape 取消"
                : shortcut.displayName
        )
        setAccessibilityHelp(
            isRecording
                ? "按下新的组合键；按 Escape 取消"
                : "当前为 \(shortcut.displayName)。按下以录制新的组合键。"
        )
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
