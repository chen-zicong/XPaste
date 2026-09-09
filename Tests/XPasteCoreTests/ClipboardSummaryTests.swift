import XCTest
@testable import XPasteCore

final class ClipboardSummaryTests: XCTestCase {
    func testLongBodyIsBoundedButOriginalAndSearchRemainComplete() {
        let text = String(repeating: "长文本🙂", count: 20_000) + " 唯一尾部关键字"
        let item = makeItem(text)
        XCTAssertLessThanOrEqual(item.title.unicodeScalars.count, 256)
        XCTAssertLessThanOrEqual(item.previewText.unicodeScalars.count, 512)
        XCTAssertEqual(item.text, text)
        XCTAssertEqual(ClipboardHistory(items: [item]).filtered(query: "唯一尾部关键字", favoritesOnly: false, filter: .text).count, 1)
    }

    func testSummariesUpdateOnMutationAndSurviveArchiveRoundTrip() throws {
        var item = makeItem("\n标题\n第二行")
        XCTAssertEqual(item.title, "标题")
        XCTAssertEqual(item.previewText, " 标题 第二行")
        item.text = "新的标题\n新内容"
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)
        XCTAssertEqual(decoded.title, "新的标题")
        XCTAssertEqual(decoded.previewText, "新的标题 新内容")
        XCTAssertEqual(decoded, item)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("textSummary"))
        item.text = nil
        XCTAssertEqual(item.title, "空文本")
        XCTAssertEqual(item.previewText, "")
    }

    func testCombiningSequenceCannotBypassSummaryLimit() {
        let item = makeItem("a" + String(repeating: "\u{301}", count: 100_000))
        XCTAssertLessThanOrEqual(item.title.unicodeScalars.count, 256)
        XCTAssertLessThanOrEqual(item.previewText.unicodeScalars.count, 512)
    }

    private func makeItem(_ text: String) -> ClipboardItem {
        ClipboardItem(kind: .text, text: text, contentHash: "fixture", contentBytes: text.utf8.count)
    }
}
