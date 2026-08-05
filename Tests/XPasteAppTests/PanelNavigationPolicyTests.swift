import XCTest
@testable import XPaste

final class PanelNavigationPolicyTests: XCTestCase {
    func testHorizontalPageNavigationAndTextInputPriority() {
        XCTAssertEqual(destination(page: .history, direction: .right), .favorites)
        XCTAssertEqual(destination(page: .favorites, direction: .left), .history)
        XCTAssertEqual(destination(page: .history, direction: .left), .history)
        XCTAssertEqual(destination(page: .favorites, direction: .right), .favorites)

        XCTAssertNil(destination(page: .statistics, direction: .left))
        XCTAssertNil(destination(page: .history, direction: .right, searchIsEmpty: false))
        XCTAssertNil(destination(page: .history, direction: .right, isEditingBody: true))
        XCTAssertNil(destination(page: .history, direction: .right, hasMarkedText: true))
        XCTAssertNil(destination(page: .history, direction: .right, hasDisallowedModifiers: true))
    }

    func testVerticalSelectionOnlyHandlesPlainArrowsOutsideBodyEditingAndIME() {
        XCTAssertTrue(PanelNavigationPolicy.allowsVerticalSelection(
            isListPage: true,
            hasDisallowedModifiers: false,
            isEditingBody: false,
            hasMarkedText: false
        ))
        XCTAssertFalse(PanelNavigationPolicy.allowsVerticalSelection(
            isListPage: false,
            hasDisallowedModifiers: false,
            isEditingBody: false,
            hasMarkedText: false
        ))
        XCTAssertFalse(PanelNavigationPolicy.allowsVerticalSelection(
            isListPage: true,
            hasDisallowedModifiers: true,
            isEditingBody: false,
            hasMarkedText: false
        ))
        XCTAssertFalse(PanelNavigationPolicy.allowsVerticalSelection(
            isListPage: true,
            hasDisallowedModifiers: false,
            isEditingBody: true,
            hasMarkedText: false
        ))
        XCTAssertFalse(PanelNavigationPolicy.allowsVerticalSelection(
            isListPage: true,
            hasDisallowedModifiers: false,
            isEditingBody: false,
            hasMarkedText: true
        ))
    }

    func testSpaceTogglesDetailsWithoutBreakingSearchOrTextEditing() {
        XCTAssertTrue(allowsDetailToggle())
        XCTAssertTrue(allowsDetailToggle(isTextInputActive: true, searchIsEmpty: true))

        XCTAssertFalse(allowsDetailToggle(isListPage: false))
        XCTAssertFalse(allowsDetailToggle(hasSelection: false))
        XCTAssertFalse(allowsDetailToggle(hasDisallowedModifiers: true))
        XCTAssertFalse(allowsDetailToggle(isEditingBody: true))
        XCTAssertFalse(allowsDetailToggle(isTextInputActive: true, searchIsEmpty: false))
        XCTAssertFalse(allowsDetailToggle(hasMarkedText: true))
    }

    private func destination(
        page: PanelPage,
        direction: PanelHorizontalDirection,
        hasDisallowedModifiers: Bool = false,
        isEditingBody: Bool = false,
        searchIsEmpty: Bool = true,
        hasMarkedText: Bool = false
    ) -> PanelPage? {
        PanelNavigationPolicy.destination(
            currentPage: page,
            direction: direction,
            hasDisallowedModifiers: hasDisallowedModifiers,
            isEditingBody: isEditingBody,
            searchIsEmpty: searchIsEmpty,
            hasMarkedText: hasMarkedText
        )
    }


    private func allowsDetailToggle(
        isListPage: Bool = true,
        hasSelection: Bool = true,
        hasDisallowedModifiers: Bool = false,
        isEditingBody: Bool = false,
        isTextInputActive: Bool = false,
        searchIsEmpty: Bool = true,
        hasMarkedText: Bool = false
    ) -> Bool {
        PanelNavigationPolicy.allowsDetailToggle(
            isListPage: isListPage,
            hasSelection: hasSelection,
            hasDisallowedModifiers: hasDisallowedModifiers,
            isEditingBody: isEditingBody,
            isTextInputActive: isTextInputActive,
            searchIsEmpty: searchIsEmpty,
            hasMarkedText: hasMarkedText
        )
    }
}
