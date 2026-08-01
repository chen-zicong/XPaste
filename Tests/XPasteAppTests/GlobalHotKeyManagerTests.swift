import Carbon.HIToolbox
import XCTest
@testable import XPaste

@MainActor
final class GlobalHotKeyManagerTests: XCTestCase {
    func testFailedReplacementRestoresPreviouslyRegisteredPair() {
        let oldHistory = GlobalShortcut.defaultHistory
        let oldFavorites = GlobalShortcut.defaultFavorites
        let newHistory = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_H),
            carbonModifiers: UInt32(cmdKey | optionKey)
        )
        let unavailable = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_J),
            carbonModifiers: UInt32(cmdKey | optionKey)
        )
        var registrationCount = 0
        let manager = GlobalHotKeyManager(
            installSystemHandler: false,
            registration: { shortcut, action in
                registrationCount += 1
                guard shortcut != unavailable else { return nil }
                return OpaquePointer(bitPattern: Int(action.rawValue) + registrationCount * 10)
            },
            unregistration: { _ in }
        )

        XCTAssertTrue(manager.register(history: oldHistory, favorites: oldFavorites).isEmpty)
        let conflicts = manager.register(history: newHistory, favorites: unavailable)

        XCTAssertEqual(conflicts, [.favorites])
        XCTAssertEqual(manager.registeredShortcut(for: .history), oldHistory)
        XCTAssertEqual(manager.registeredShortcut(for: .favorites), oldFavorites)
    }

    func testDuplicateReplacementDoesNotDisturbWorkingPair() {
        var registrationCount = 0
        let manager = GlobalHotKeyManager(
            installSystemHandler: false,
            registration: { _, action in
                registrationCount += 1
                return OpaquePointer(bitPattern: Int(action.rawValue) + registrationCount * 10)
            },
            unregistration: { _ in }
        )
        XCTAssertTrue(manager.register(
            history: .defaultHistory,
            favorites: .defaultFavorites
        ).isEmpty)
        let registrationCountBeforeDuplicate = registrationCount

        let conflicts = manager.register(history: .commandShiftV, favorites: .commandShiftV)

        XCTAssertEqual(conflicts, [.history, .favorites])
        XCTAssertEqual(registrationCount, registrationCountBeforeDuplicate)
        XCTAssertEqual(manager.registeredShortcut(for: .history), .defaultHistory)
        XCTAssertEqual(manager.registeredShortcut(for: .favorites), .defaultFavorites)
    }
}
