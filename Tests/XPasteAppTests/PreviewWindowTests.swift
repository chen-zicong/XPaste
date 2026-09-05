import AppKit
import XCTest
import XPasteCore
@testable import XPaste

@MainActor
final class PreviewWindowTests: XCTestCase {
    func testPreviewPreservesMainFrameSelectionAndPasteSession() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.show(page: .history)
        await settle()
        let main = try fixture.window("XPaste.History")
        main.setFrame(NSRect(x: main.frame.minX + 20, y: main.frame.minY, width: 700, height: 440), display: true)
        let frame = main.frame
        let id = try XCTUnwrap(fixture.model.selectedID)
        let request = fixture.controller.makeCopyRequest(itemID: id, autoPaste: true)
        fixture.model.showDetails()
        await settle()
        let preview = try fixture.window("XPaste.Preview")
        XCTAssertTrue(main.isVisible)
        XCTAssertTrue(preview.isVisible)
        XCTAssertTrue(preview.parent === main)
        XCTAssertEqual(main.frame, frame)
        XCTAssertEqual(fixture.model.selectedID, id)
        XCTAssertTrue(fixture.controller.isCurrent(request))
        XCTAssertEqual(request.targetApplicationPID, 12345)
        preview.performClose(nil)
        await settle()
        XCTAssertTrue(main.isVisible)
        XCTAssertFalse(preview.isVisible)
        XCTAssertFalse(fixture.model.isDetailVisible)
        XCTAssertEqual(fixture.model.selectedID, id)
        XCTAssertTrue(fixture.controller.isCurrent(request))
    }

    func testPreviewReusesWindowAndKeepsUnfinishedDrafts() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.show(page: .history)
        fixture.model.showDetails()
        await settle()
        let preview = try fixture.window("XPaste.Preview")
        let first = try XCTUnwrap(fixture.model.selectedItem)
        fixture.model.isPreviewEditing = true
        fixture.model.updateDraft(id: first.id, text: "unfinished draft")
        fixture.model.selectNext(offset: 1)
        await settle()
        XCTAssertFalse(fixture.model.isPreviewEditing)
        XCTAssertTrue(preview.isVisible)
        XCTAssertTrue(try fixture.window("XPaste.Preview") === preview)
        fixture.model.select(first)
        XCTAssertEqual(fixture.model.draftText(for: first), "unfinished draft")
        XCTAssertFalse(fixture.model.isPreviewEditing)
        fixture.controller.hide()
        XCTAssertFalse(preview.isVisible)
        XCTAssertNil(preview.parent)
        XCTAssertFalse(fixture.model.isDetailVisible)
        XCTAssertEqual(fixture.model.draftText(for: first), "unfinished draft")
    }

    func testEmptySearchAndStatisticsDismissPreview() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.show(page: .history)
        fixture.model.showDetails()
        await settle()
        fixture.model.query = "no-matching-content-4711"
        await settle()
        XCTAssertNil(fixture.model.selectedItem)
        XCTAssertFalse(fixture.model.isDetailVisible)
        XCTAssertFalse(try fixture.window("XPaste.Preview").isVisible)
        fixture.model.query = ""
        fixture.model.showDetails()
        fixture.model.show(page: .statistics)
        XCTAssertFalse(fixture.model.isDetailVisible)
        XCTAssertFalse(try fixture.window("XPaste.Preview").isVisible)
    }

    func testDirtyEditorCannotPasteOldTextAndClosePreservesDraft() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let item = try XCTUnwrap(fixture.model.selectedItem)
        var copies = 0
        fixture.model.onCopyRequest = { _, _ in copies += 1 }
        fixture.model.showDetails()
        fixture.model.isPreviewEditing = true
        fixture.model.updateDraft(id: item.id, text: "changed content")
        fixture.model.copy(item, autoPaste: true)
        XCTAssertEqual(copies, 0)
        XCTAssertNotNil(fixture.model.toastMessage)
        fixture.model.isDetailVisible = false
        XCTAssertFalse(fixture.model.isPreviewEditing)
        XCTAssertEqual(fixture.model.draftText(for: item), "changed content")
        fixture.model.copy(item, autoPaste: false)
        XCTAssertEqual(copies, 1) // Read mode displays, and copies, the saved version.
    }

    func testSpaceClosesPreviewButDoesNotConsumeEditorInput() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.show(page: .history)
        fixture.model.showDetails()
        await settle()
        let preview = try fixture.window("XPaste.Preview")
        preview.makeKey()
        await settle()
        XCTAssertTrue(preview.isKeyWindow)
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: preview.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        fixture.model.isPreviewEditing = true
        await settle()
        XCTAssertEqual((preview.firstResponder as? NSTextView)?.isEditable, true)
        XCTAssertFalse(fixture.controller.handle(space))
        XCTAssertTrue(fixture.model.isDetailVisible)
        fixture.model.isPreviewEditing = false
        preview.makeFirstResponder(nil)
        XCTAssertTrue(fixture.controller.handle(space))
        XCTAssertFalse(fixture.model.isDetailVisible)
    }

    func testOutsideFocusDismissesBothUnlessPinned() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        defer { other.orderOut(nil) }
        fixture.controller.show(page: .history)
        fixture.model.showDetails()
        await settle()
        other.makeKeyAndOrderFront(nil)
        await settle()
        XCTAssertFalse(fixture.controller.isVisible)
        XCTAssertFalse(try fixture.window("XPaste.Preview").isVisible)
        fixture.model.isPanelPinned = true
        fixture.controller.show(page: .history)
        fixture.model.showDetails()
        await settle()
        other.makeKeyAndOrderFront(nil)
        await settle()
        XCTAssertTrue(fixture.controller.isVisible)
        XCTAssertTrue(try fixture.window("XPaste.Preview").isVisible)
    }

    func testReopeningDuringDismissalDoesNotHideNewPreview() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.show(page: .history)
        fixture.model.showDetails()
        await settle()
        let preview = try fixture.window("XPaste.Preview")
        fixture.model.isDetailVisible = false
        fixture.model.showDetails()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(preview.isVisible)
        XCTAssertEqual(preview.alphaValue, 1, accuracy: 0.01)
        XCTAssertFalse(preview.ignoresMouseEvents)
        XCTAssertTrue(fixture.model.isDetailVisible)
        XCTAssertNotNil(preview.parent)
    }

    func testHidingParentDuringPreviewAnimationRemovesChildImmediately() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.show(page: .history)
        fixture.model.showDetails()
        let preview = try fixture.window("XPaste.Preview")
        fixture.model.isDetailVisible = false
        fixture.controller.hide()
        XCTAssertFalse(preview.isVisible)
        XCTAssertNil(preview.parent)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(preview.isVisible)
        XCTAssertEqual(preview.alphaValue, 1, accuracy: 0.01)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(160)) }

    @MainActor
    private final class Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        let model: AppModel
        let controller: PanelController

        init() async throws {
            _ = NSApplication.shared
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("XPaste-Preview-Test-\(UUID().uuidString)")
            suite = "XPaste.PreviewTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            let repository = HistoryRepository(baseURL: directory)
            _ = try await repository.load()
            for (index, text) in ["First preview", "Second preview"].enumerated() {
                _ = try await repository.record(CapturePayload(kind: .text, text: text, contentHash: ContentHasher.text(text), capturedAt: Date().addingTimeInterval(Double(-index))), maxItems: 100)
            }
            model = AppModel(settings: AppSettings(defaults: defaults), repository: repository)
            await model.start()
            controller = PanelController(model: model, accessibilityPermission: AccessibilityPermissionController(processTrusted: { false }, preflightPostEventAccess: { false }, requestPostEventAccess: { false }), targetApplicationProvider: { 12345 })
        }

        func window(_ identifier: String) throws -> NSWindow {
            try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == identifier && ($0.isVisible || identifier == "XPaste.Preview") })
        }

        func cleanUp() {
            controller.hide()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
