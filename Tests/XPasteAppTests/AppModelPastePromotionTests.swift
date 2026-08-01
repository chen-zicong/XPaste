import Foundation
import XCTest
@testable import XPaste
import XPasteCore

@MainActor
final class AppModelPastePromotionTests: XCTestCase {
    func testPasteEventSentMovesOldItemToTopWithoutChangingCaptureTime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XPasteAppTests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "XPasteAppTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults)
        settings.promotePastedItems = true
        let repository = HistoryRepository(baseURL: directory)
        _ = try await repository.load()
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        var state = try await repository.record(
            CapturePayload(
                kind: .text,
                text: "old",
                contentHash: ContentHasher.text("old"),
                capturedAt: oldDate
            ),
            maxItems: 10
        )
        let oldID = try XCTUnwrap(state.items.first?.id)
        state = try await repository.record(
            CapturePayload(
                kind: .text,
                text: "new",
                contentHash: ContentHasher.text("new"),
                capturedAt: newDate
            ),
            maxItems: 10
        )

        let model = AppModel(settings: settings, repository: repository)
        await model.start()
        XCTAssertEqual(model.visibleItems.first?.text, "new")

        await model.recordPasteEventSent(id: oldID)

        XCTAssertEqual(model.visibleItems.first?.id, oldID)
        let promoted = try XCTUnwrap(model.visibleItems.first)
        XCTAssertEqual(promoted.createdAt, oldDate)
        XCTAssertGreaterThan(promoted.lastUsedAt, newDate)
        XCTAssertEqual(promoted.captureCount, 1)
    }
}
