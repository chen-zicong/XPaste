import AppKit
import Foundation

enum ClipboardCapture: @unchecked Sendable {
    case text(String, sourceApp: String?)
    case image(Data, sourceApp: String?)
    case files([String], sourceApp: String?)
}

enum ClipboardPublish: Sendable {
    case text(String)
    case image(Data)
    case files([String])
}

/// Serializes every general-pasteboard read and write away from the UI actor.
/// Some apps vend pasteboard data lazily, so even `data(forType:)` can block.
actor ClipboardMonitor {
    nonisolated static let internalMarker = NSPasteboard.PasteboardType("com.xpaste.internal-item")
    private static let concealedTypes = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("com.agilebits.onepassword")
    ]

    private let pasteboard: NSPasteboard
    private var loopTask: Task<Void, Never>?
    private var pollInterval: TimeInterval = 0.45
    private var lastChangeCount: Int
    private var reportedAccessDenied = false
    private var ownWrite: (changeCount: Int, token: String)?
    private var captureHandler: (@MainActor @Sendable (ClipboardCapture) -> Void)?
    private var accessHandler: (@MainActor @Sendable (Bool) -> Void)?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    func setHandlers(
        onCapture: @escaping @MainActor @Sendable (ClipboardCapture) -> Void,
        onAccessStateChange: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        captureHandler = onCapture
        accessHandler = onAccessStateChange
    }

    /// Updating the interval never resets `lastChangeCount`; this avoids losing
    /// a copy that occurs while the user changes an unrelated setting.
    func configure(enabled: Bool, interval: TimeInterval) {
        pollInterval = max(0.2, interval)
        if enabled {
            guard loopTask == nil else { return }
            lastChangeCount = pasteboard.changeCount
            loopTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    await self.pollOnce()
                    let delay = await self.pollInterval
                    try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(75))
                }
            }
        } else {
            stop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func publish(_ content: ClipboardPublish) -> Bool {
        guard !Task.isCancelled else { return false }
        return autoreleasepool {
            let token = UUID().uuidString
            let objects: [NSPasteboardWriting]

            switch content {
            case .text(let text):
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                item.setString(token, forType: Self.internalMarker)
                objects = [item]
            case .image(let data):
                let item = NSPasteboardItem()
                item.setData(data, forType: .png)
                item.setString(token, forType: Self.internalMarker)
                objects = [item]
            case .files(let paths):
                objects = paths.enumerated().map { index, path in
                    let item = NSPasteboardItem()
                    item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
                    if index == 0 { item.setString(token, forType: Self.internalMarker) }
                    return item
                }
            }

            guard !objects.isEmpty else { return false }
            guard !Task.isCancelled else { return false }
            pasteboard.clearContents()
            guard pasteboard.writeObjects(objects) else { return false }
            let finalCount = pasteboard.changeCount
            guard pasteboard.pasteboardItems?.first?.string(forType: Self.internalMarker) == token,
                  pasteboard.changeCount == finalCount else { return false }
            lastChangeCount = finalCount
            ownWrite = (finalCount, token)
            return true
        }
    }

    private func pollOnce() async {
        let denied: Bool
        if #available(macOS 15.4, *) {
            denied = pasteboard.accessBehavior == .alwaysDeny
        } else {
            denied = false
        }
        if denied != reportedAccessDenied {
            reportedAccessDenied = denied
            if let accessHandler { await accessHandler(denied) }
        }
        guard !denied else { return }

        let capture: ClipboardCapture? = autoreleasepool {
            let observedChangeCount = pasteboard.changeCount
            guard observedChangeCount != lastChangeCount else { return nil }
            // Update first so denied, malformed, or unsupported contents are not retried forever.
            lastChangeCount = observedChangeCount

            if let ownWrite,
               ownWrite.changeCount == observedChangeCount,
               pasteboard.pasteboardItems?.first?.string(forType: Self.internalMarker) == ownWrite.token {
                return nil
            }

            let types = Set(pasteboard.types ?? [])
            guard Self.concealedTypes.allSatisfy({ !types.contains($0) }) else { return nil }

            let sourceApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let capture: ClipboardCapture?
            if let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !urls.isEmpty {
                capture = .files(urls.map(\.path), sourceApp: sourceApp)
            } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
                capture = .image(data, sourceApp: sourceApp)
            } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
                capture = .text(text, sourceApp: sourceApp)
            } else {
                capture = nil
            }

            guard pasteboard.changeCount == observedChangeCount else { return nil }
            return capture
        }

        if let capture, let captureHandler { await captureHandler(capture) }
    }
}
