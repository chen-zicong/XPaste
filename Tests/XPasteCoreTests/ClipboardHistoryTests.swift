import XCTest
@testable import XPasteCore

final class ClipboardHistoryTests: XCTestCase {
    func testDuplicateIsPromotedAndKeepsFavorite() {
        let old = makeText("same", favorite: true, date: Date(timeIntervalSince1970: 10))
        var history = ClipboardHistory(items: [old])
        let promoted = history.promoteDuplicate(
            hash: old.contentHash,
            kind: .text,
            at: Date(timeIntervalSince1970: 20),
            sourceApp: "com.apple.Safari"
        )
        XCTAssertEqual(promoted?.id, old.id)
        XCTAssertEqual(history.items.first?.isFavorite, true)
        XCTAssertEqual(history.items.first?.sourceAppBundleIdentifier, "com.apple.Safari")
    }

    func testPruningNeverRemovesFavorites() {
        let favorite = makeText("favorite", favorite: true, date: Date(timeIntervalSince1970: 1))
        let regular = (2...6).map { makeText("item-\($0)", date: Date(timeIntervalSince1970: TimeInterval($0))) }
        var history = ClipboardHistory(items: [favorite] + regular)
        let removed = history.prune(maxItems: 3)
        XCTAssertEqual(history.items.count, 3)
        XCTAssertTrue(history.items.contains(where: { $0.id == favorite.id }))
        XCTAssertEqual(removed.count, 3)
    }

    func testAllFavoritesCanExceedLimit() {
        var history = ClipboardHistory(items: (0..<5).map { makeText("f\($0)", favorite: true) })
        XCTAssertTrue(history.prune(maxItems: 2).isEmpty)
        XCTAssertEqual(history.items.count, 5)
    }

    func testSearchRequiresEveryTermAndIgnoresCase() {
        let item = makeText("SwiftUI Clipboard Manager")
        let other = makeText("unrelated")
        let history = ClipboardHistory(items: [item, other])
        XCTAssertEqual(history.filtered(query: "swiftui MANAGER", favoritesOnly: false, filter: .all).map(\.id), [item.id])
    }

    func testSearchSupportsChineseSubstring() {
        let item = makeText("高性能的剪贴板工具")
        let history = ClipboardHistory(items: [item])
        XCTAssertEqual(history.filtered(query: "剪贴板", favoritesOnly: false, filter: .all).count, 1)
    }

    func testKindFilter() {
        let text = makeText("hello")
        let files = ClipboardItem(kind: .files, filePaths: ["/tmp/demo.pdf"], contentHash: ContentHasher.files(["/tmp/demo.pdf"]), contentBytes: 13)
        let history = ClipboardHistory(items: [text, files])
        XCTAssertEqual(history.filtered(query: "", favoritesOnly: false, filter: .files).map(\.id), [files.id])
    }

    func testStorageStatsBreakdown() {
        let text = ClipboardItem(kind: .text, text: "abc", contentHash: ContentHasher.text("abc"), contentBytes: 3)
        let image = ClipboardItem(kind: .image, contentHash: "image", contentBytes: 100, thumbnailBytes: 20)
        let stats = StorageStats(items: [text, image], metadataBytes: 7)
        XCTAssertEqual(stats.totalBytes, 130)
        XCTAssertEqual(stats.textBytes, 3)
        XCTAssertEqual(stats.imageBytes, 120)
        XCTAssertEqual(stats.metadataBytes, 7)
    }

    func testHashIsDeterministicAndContentSensitive() {
        XCTAssertEqual(ContentHasher.text("hello"), ContentHasher.text("hello"))
        XCTAssertNotEqual(ContentHasher.text("hello"), ContentHasher.text("Hello"))
    }

    func testTenThousandItemSearchIsResponsive() {
        let items = (0..<10_000).map { makeText("第 \($0) 条 Swift clipboard sample") }
        let history = ClipboardHistory(items: items)
        let start = ContinuousClock.now
        let result = history.filtered(query: "9999 Swift", favoritesOnly: false, filter: .text)
        let elapsed = start.duration(to: .now)
        XCTAssertEqual(result.count, 1)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    private func makeText(_ text: String, favorite: Bool = false, date: Date = Date()) -> ClipboardItem {
        ClipboardItem(
            kind: .text,
            text: text,
            createdAt: date,
            isFavorite: favorite,
            contentHash: ContentHasher.text(text),
            contentBytes: text.utf8.count
        )
    }
}
