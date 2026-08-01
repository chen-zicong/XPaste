import Foundation
import XCTest
@testable import XPaste
import XPasteCore

@MainActor
final class AppModelSelectionTests: XCTestCase {
    func testPageSwitchSelectsFirstItemAndAlwaysRequestsReveal() async throws {
        let fixture = try SelectionTestFixture()
        defer { fixture.cleanUp() }

        let repository = HistoryRepository(baseURL: fixture.directory)
        _ = try await repository.load()
        var state = try await record("older", at: 100, in: repository)
        let olderID = try XCTUnwrap(state.items.first?.id)
        state = try await record("newest", at: 200, in: repository)
        let newestID = try XCTUnwrap(state.items.first?.id)
        _ = try await repository.setFavorite(id: newestID, value: true)

        let model = AppModel(settings: AppSettings(defaults: fixture.defaults), repository: repository)
        await model.start()
        model.selectedID = olderID
        let initialRevealToken = model.selectionRevealToken

        model.show(page: .favorites)

        XCTAssertEqual(model.visibleItems.map(\.id), [newestID])
        XCTAssertEqual(model.selectedID, newestID)
        XCTAssertNotEqual(model.selectionRevealToken, initialRevealToken)

        // The first history item is the same UUID. The explicit token must
        // still change, otherwise ScrollView.onChange(selectedID) never fires.
        let favoritesRevealToken = model.selectionRevealToken
        model.show(page: .history)

        XCTAssertEqual(model.visibleItems.first?.id, newestID)
        XCTAssertEqual(model.selectedID, newestID)
        XCTAssertNotEqual(model.selectionRevealToken, favoritesRevealToken)
    }

    func testMovingAtListBoundaryStillRequestsReveal() async throws {
        let fixture = try SelectionTestFixture()
        defer { fixture.cleanUp() }

        let repository = HistoryRepository(baseURL: fixture.directory)
        _ = try await repository.load()
        let state = try await record("only", at: 100, in: repository)
        let onlyID = try XCTUnwrap(state.items.first?.id)
        let model = AppModel(settings: AppSettings(defaults: fixture.defaults), repository: repository)
        await model.start()
        XCTAssertEqual(model.selectedID, onlyID)

        let beforeDown = model.selectionRevealToken
        model.selectNext(offset: 1)
        XCTAssertEqual(model.selectedID, onlyID)
        XCTAssertNotEqual(model.selectionRevealToken, beforeDown)

        let beforeUp = model.selectionRevealToken
        model.selectNext(offset: -1)
        XCTAssertEqual(model.selectedID, onlyID)
        XCTAssertNotEqual(model.selectionRevealToken, beforeUp)
    }

    func testMovingBetweenItemsUsesSingleSelectionChangeWithoutRevealToken() async throws {
        let fixture = try SelectionTestFixture()
        defer { fixture.cleanUp() }

        let repository = HistoryRepository(baseURL: fixture.directory)
        _ = try await repository.load()
        var state = try await record("older", at: 100, in: repository)
        let olderID = try XCTUnwrap(state.items.first?.id)
        state = try await record("newer", at: 200, in: repository)
        let newerID = try XCTUnwrap(state.items.first?.id)

        let model = AppModel(settings: AppSettings(defaults: fixture.defaults), repository: repository)
        await model.start()
        XCTAssertEqual(model.selectedID, newerID)

        let beforeDown = model.selectionRevealToken
        model.selectNext(offset: 1)
        XCTAssertEqual(model.selectedID, olderID)
        XCTAssertEqual(model.selectionRevealToken, beforeDown)

        let beforeUp = model.selectionRevealToken
        model.selectNext(offset: -1)
        XCTAssertEqual(model.selectedID, newerID)
        XCTAssertEqual(model.selectionRevealToken, beforeUp)
    }

    func testFreshPresentationOfCurrentPageResetsAndRevealsFirstItem() async throws {
        let fixture = try SelectionTestFixture()
        defer { fixture.cleanUp() }

        let repository = HistoryRepository(baseURL: fixture.directory)
        _ = try await repository.load()
        var state = try await record("older", at: 100, in: repository)
        let olderID = try XCTUnwrap(state.items.first?.id)
        state = try await record("newest", at: 200, in: repository)
        let newestID = try XCTUnwrap(state.items.first?.id)

        let model = AppModel(settings: AppSettings(defaults: fixture.defaults), repository: repository)
        await model.start()
        model.selectedID = olderID
        let beforePresentation = model.selectionRevealToken

        model.show(page: .history, resetSelection: true)

        XCTAssertEqual(model.selectedID, newestID)
        XCTAssertNotEqual(model.selectionRevealToken, beforePresentation)
    }

    func testShowingCurrentPageWithoutFreshPresentationPreservesSelection() async throws {
        let fixture = try SelectionTestFixture()
        defer { fixture.cleanUp() }

        let repository = HistoryRepository(baseURL: fixture.directory)
        _ = try await repository.load()
        var state = try await record("older", at: 100, in: repository)
        let olderID = try XCTUnwrap(state.items.first?.id)
        state = try await record("newest", at: 200, in: repository)
        _ = try XCTUnwrap(state.items.first?.id)

        let model = AppModel(settings: AppSettings(defaults: fixture.defaults), repository: repository)
        await model.start()
        model.selectedID = olderID

        model.show(page: .history)

        XCTAssertEqual(model.selectedID, olderID)
    }

    private func record(
        _ text: String,
        at timestamp: TimeInterval,
        in repository: HistoryRepository
    ) async throws -> RepositoryState {
        try await repository.record(
            CapturePayload(
                kind: .text,
                text: text,
                contentHash: ContentHasher.text(text),
                capturedAt: Date(timeIntervalSince1970: timestamp)
            ),
            maxItems: 10
        )
    }
}

private final class SelectionTestFixture {
    let directory: URL
    let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XPasteSelectionTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "XPasteSelectionTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
