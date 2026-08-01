import Carbon.HIToolbox
import Foundation
import XCTest
@testable import XPaste

@MainActor
final class AppSettingsTests: XCTestCase {
    func testPromotePastedItemsDefaultsOffAndPersists() throws {
        let suiteName = "XPasteAppTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.promotePastedItems)

        var changeCount = 0
        settings.onChange = { _ in changeCount += 1 }
        settings.promotePastedItems = true
        XCTAssertEqual(changeCount, 1)
        XCTAssertTrue(AppSettings(defaults: defaults).promotePastedItems)

        settings.promotePastedItems = false
        XCTAssertEqual(changeCount, 2)
        XCTAssertFalse(AppSettings(defaults: defaults).promotePastedItems)

        settings.restoreShortcutsWithoutNotification(
            history: .commandShiftV,
            favorites: .commandShiftF
        )
        XCTAssertEqual(changeCount, 2)
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.historyShortcut, .commandShiftV)
        XCTAssertEqual(restored.favoritesShortcut, .commandShiftF)
    }

    func testCustomShortcutPersistsAndReportsOnlyShortcutChange() throws {
        let suiteName = "XPasteAppTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        var changes: [SettingsChange] = []
        settings.onChange = { changes.append($0) }
        let custom = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_G),
            carbonModifiers: UInt32(cmdKey | optionKey | shiftKey)
        )

        settings.historyShortcut = custom
        settings.historyShortcut = custom

        XCTAssertEqual(changes, [.shortcuts])
        XCTAssertNotNil(defaults.data(forKey: "historyShortcut"))
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.historyShortcut, custom)
        XCTAssertEqual(restored.historyShortcut.displayName, "⌥⇧⌘G")
    }

    func testLegacyPresetStringsMigrateToStructuredShortcuts() throws {
        let suiteName = "XPasteAppTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("commandShiftV", forKey: "historyShortcut")
        defaults.set("controlShiftF", forKey: "favoritesShortcut")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.historyShortcut, .commandShiftV)
        XCTAssertEqual(settings.favoritesShortcut, .controlShiftF)
        XCTAssertNotNil(defaults.data(forKey: "historyShortcut"))
        XCTAssertNotNil(defaults.data(forKey: "favoritesShortcut"))
    }

    func testSettingsChangesAreTypedAndUnchangedValuesAreIgnored() throws {
        let suiteName = "XPasteAppTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        var changes: [SettingsChange] = []
        settings.onChange = { changes.append($0) }

        settings.pollInterval = 0.75
        settings.promotePastedItems = true
        settings.maxItems = 500
        settings.closeAfterCopy = false
        settings.closeAfterCopy = false

        XCTAssertEqual(changes, [.monitoring, .historySort, .maxItems, .other])
    }

    func testShortcutValidationAllowsFunctionKeysButRejectsUnsafePlainKeys() {
        XCTAssertTrue(GlobalShortcut(
            keyCode: UInt32(kVK_F1),
            carbonModifiers: 0
        ).isReasonable)
        XCTAssertTrue(GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_V),
            carbonModifiers: UInt32(controlKey | shiftKey)
        ).isReasonable)
        XCTAssertFalse(GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_V),
            carbonModifiers: UInt32(shiftKey)
        ).isReasonable)
    }
}
