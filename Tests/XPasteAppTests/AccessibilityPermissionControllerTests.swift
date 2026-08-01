import XCTest
@testable import XPaste

@MainActor
final class AccessibilityPermissionControllerTests: XCTestCase {
    func testEitherAccessibilityTrustSignalIsAccepted() {
        XCTAssertFalse(
            AccessibilityPermissionSnapshot(
                isProcessTrusted: false,
                canPostEvents: false
            ).isAuthorized
        )
        XCTAssertTrue(
            AccessibilityPermissionSnapshot(
                isProcessTrusted: true,
                canPostEvents: false
            ).isAuthorized
        )
        XCTAssertTrue(
            AccessibilityPermissionSnapshot(
                isProcessTrusted: false,
                canPostEvents: true
            ).isAuthorized
        )
    }

    func testRefreshAndRequestUseLivePermissionState() {
        var processTrusted = false
        var canPostEvents = false
        var requestCount = 0
        let controller = AccessibilityPermissionController(
            processTrusted: { processTrusted },
            preflightPostEventAccess: { canPostEvents },
            requestPostEventAccess: {
                requestCount += 1
                processTrusted = true
                return true
            }
        )

        XCTAssertFalse(controller.isAuthorized)
        XCTAssertTrue(controller.requestAuthorization())
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(controller.isAuthorized)

        processTrusted = false
        canPostEvents = true
        XCTAssertTrue(controller.refresh())
        XCTAssertTrue(controller.snapshot.canPostEvents)
    }
}
