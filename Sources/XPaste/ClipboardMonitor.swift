import AppKit
import Foundation

enum ClipboardCapture: @unchecked Sendable {
    case text(String, sourceApp: String?)
    case image(Data, sourceApp: String?)
    case files([CapturedFileReference], sourceApp: String?)
}

struct CapturedFileReference: Sendable {
    let path: String
    let bookmarkData: Data?
}

enum ClipboardPublish: Sendable {
    case text(String)
    case image(Data)
    case files([URL])
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
    private var retainedPublishedObjects: [NSPasteboardWriting] = []
    private var activeSecurityScopedURLs: [URL] = []
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
            let fileURLs: [URL]
            switch content {
            case .text(let text):
                let item = NSPasteboardItem()
                guard item.setString(text, forType: .string),
                      item.setString(token, forType: Self.internalMarker) else { return false }
                objects = [item]
                fileURLs = []
            case .image(let data):
                let item = NSPasteboardItem()
                guard item.setData(data, forType: .png),
                      item.setString(token, forType: Self.internalMarker) else { return false }
                objects = [item]
                fileURLs = []
            case .files(let URLs):
                fileURLs = URLs.map(\.standardizedFileURL)
                guard !fileURLs.isEmpty else { return false }
                objects = fileURLs.map { $0 as NSURL }
            }

            pasteboard.clearContents()
            releasePublishedResources()
            let startedAccess = fileURLs.filter { $0.startAccessingSecurityScopedResource() }
            guard pasteboard.writeObjects(objects) else {
                startedAccess.forEach { $0.stopAccessingSecurityScopedResource() }
                return false
            }
            let finalCount = pasteboard.changeCount

            if !fileURLs.isEmpty {
                let writtenURLs = pasteboard.readObjects(
                    forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]
                ) as? [URL] ?? []
                guard writtenURLs.map(\.standardizedFileURL.path) == fileURLs.map(\.path),
                      pasteboard.changeCount == finalCount else {
                    startedAccess.forEach { $0.stopAccessingSecurityScopedResource() }
                    return false
                }
                ownWrite = nil
                activeSecurityScopedURLs = startedAccess
            } else {
                guard pasteboard.pasteboardItems?.first?.string(forType: Self.internalMarker) == token,
                      pasteboard.changeCount == finalCount else { return false }
                ownWrite = (finalCount, token)
            }
            retainedPublishedObjects = objects
            lastChangeCount = finalCount
            return true
        }
    }

    private func releasePublishedResources() {
        activeSecurityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        activeSecurityScopedURLs.removeAll(keepingCapacity: true)
        retainedPublishedObjects.removeAll(keepingCapacity: true)
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
            releasePublishedResources()

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
                let references = urls.map { URL -> CapturedFileReference in
                    let started = URL.startAccessingSecurityScopedResource()
                    defer { if started { URL.stopAccessingSecurityScopedResource() } }
                    let bookmark = try? URL.bookmarkData(
                        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                        includingResourceValuesForKeys: [.fileResourceIdentifierKey],
                        relativeTo: nil
                    )
                    return CapturedFileReference(path: URL.path, bookmarkData: bookmark)
                }
                capture = .files(references, sourceApp: sourceApp)
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
