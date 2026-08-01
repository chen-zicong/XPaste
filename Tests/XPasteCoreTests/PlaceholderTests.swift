import XCTest
@testable import XPasteCore

final class PlaceholderTests: XCTestCase {
    func testCoreModuleLoads() {
        XCTAssertEqual(ClipboardKind.allCases.count, 3)
    }
}
