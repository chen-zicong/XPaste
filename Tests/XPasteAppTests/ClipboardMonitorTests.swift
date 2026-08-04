import AppKit
import XCTest
@testable import XPaste

final class ClipboardMonitorTests: XCTestCase {
    func testFilePublishWritesFinderCompatibleURLsAndValidatesEveryPath() async {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.xpaste.tests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: pasteboard)
        let paths = [
            "/tmp/XPaste first file.txt",
            "/tmp/XPaste-第二个文件.pdf"
        ]

        let didPublish = await monitor.publish(.files(paths.map { URL(fileURLWithPath: $0) }))
        XCTAssertTrue(didPublish)

        // Finder and IM clients request some NSURL pasteboard representations
        // after XPaste has returned and switched applications. Exercise that
        // lifetime boundary instead of validating only inside publish().
        try? await Task.sleep(for: .milliseconds(250))

        let writtenURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        XCTAssertEqual(writtenURLs.map(\.standardizedFileURL.path), paths)
        XCTAssertTrue(pasteboard.types?.contains(.fileURL) == true)
        XCTAssertNil(
            pasteboard.pasteboardItems?.first?.string(forType: ClipboardMonitor.internalMarker),
            "File publishing must not substitute XPaste's marker for the system file URL flavors"
        )
    }

    func testFilePublishRejectsAnEmptySelection() async {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.xpaste.tests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: pasteboard)

        let didPublish = await monitor.publish(.files([]))
        XCTAssertFalse(didPublish)
        XCTAssertTrue((pasteboard.types ?? []).isEmpty)
    }
}
