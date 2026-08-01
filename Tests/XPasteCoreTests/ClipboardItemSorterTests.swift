import Foundation
import XCTest
@testable import XPasteCore

final class ClipboardItemSorterTests: XCTestCase {
    func testRecentUseOrderPreservesCaptureSemantics() {
        let oldCapture = Date(timeIntervalSince1970: 100)
        let newCapture = Date(timeIntervalSince1970: 200)
        let pastedAt = Date(timeIntervalSince1970: 300)
        let old = makeItem("old", createdAt: oldCapture, lastUsedAt: pastedAt)
        let new = makeItem("new", createdAt: newCapture, lastUsedAt: newCapture)

        XCTAssertEqual(
            ClipboardItemSorter.sorted([old, new], by: .captureTime).map(\.text),
            ["new", "old"]
        )
        XCTAssertEqual(
            ClipboardItemSorter.sorted([old, new], by: .recentUse).map(\.text),
            ["old", "new"]
        )

        let promoted = ClipboardItemSorter.sorted([old, new], by: .recentUse)[0]
        XCTAssertEqual(promoted.createdAt, oldCapture)
        XCTAssertEqual(promoted.lastUsedAt, pastedAt)
        XCTAssertEqual(promoted.captureCount, 1)
    }

    private func makeItem(_ text: String, createdAt: Date, lastUsedAt: Date) -> ClipboardItem {
        ClipboardItem(
            kind: .text,
            text: text,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            contentHash: ContentHasher.text(text),
            contentBytes: text.utf8.count
        )
    }
}
