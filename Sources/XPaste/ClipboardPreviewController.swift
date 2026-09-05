import AppKit
import QuartzCore
import SwiftUI

private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClipboardPreviewController: NSWindowController {
    var onClose: (() -> Void)?
    var onResignKey: (() -> Void)?
    private var hasUserSize = false
    private var transitionID = UUID()
    private(set) var isPresented = false

    init(model: AppModel) {
        let window = PreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 548),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("XPaste.Preview")
        window.title = "XPaste 预览"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 340)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: ClipboardDetailView(model: model))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(above parent: NSWindow) {
        guard let window, !isPresented else { return }
        let wasVisible = window.isVisible
        transitionID = UUID()
        isPresented = true
        window.ignoresMouseEvents = false
        let available = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
        let size = hasUserSize ? window.frame.size : NSSize(width: 600, height: 548)
        var frame = NSRect(
            x: parent.frame.midX - size.width / 2 + 24,
            y: parent.frame.midY - size.height / 2 - 20,
            width: min(size.width, available.width - 32),
            height: min(size.height, available.height - 32)
        )
        frame.origin.x = min(max(frame.minX, available.minX + 16), available.maxX - frame.width - 16)
        frame.origin.y = min(max(frame.minY, available.minY + 16), available.maxY - frame.height - 16)
        window.setFrame(frame, display: false)
        window.level = parent.level
        if window.parent !== parent { parent.addChildWindow(window, ordered: .above) }
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !wasVisible {
            setAlphaImmediately(animate ? 0 : 1)
            if animate { window.setFrame(frame.offsetBy(dx: 0, dy: -6), display: false) }
        }
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? PanelMotion.windowIn : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(frame, display: true)
        }
    }

    func dismiss(animated: Bool = false) {
        guard let window else { return }
        isPresented = false
        transitionID = UUID()
        let closingTransition = transitionID
        guard animated, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
            setAlphaImmediately(1)
            window.ignoresMouseEvents = false
            return
        }
        // A fading preview must not consume clicks or delay keyboard focus restoration.
        window.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelMotion.windowOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transitionID == closingTransition, !self.isPresented else { return }
                window.parent?.removeChildWindow(window)
                window.orderOut(nil)
                self.setAlphaImmediately(1)
                window.ignoresMouseEvents = false
            }
        }
    }

    private func setAlphaImmediately(_ alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window?.animator().alphaValue = alpha
        }
    }
}

extension ClipboardPreviewController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?()
        return false
    }

    func windowDidResignKey(_ notification: Notification) { onResignKey?() }
    func windowDidEndLiveResize(_ notification: Notification) { hasUserSize = true }
}
