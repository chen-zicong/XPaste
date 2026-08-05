enum PanelHorizontalDirection {
    case left
    case right
}

enum PanelNavigationPolicy {
    static func destination(
        currentPage: PanelPage,
        direction: PanelHorizontalDirection,
        hasDisallowedModifiers: Bool,
        isEditingBody: Bool,
        searchIsEmpty: Bool,
        hasMarkedText: Bool
    ) -> PanelPage? {
        guard currentPage == .history || currentPage == .favorites,
              !hasDisallowedModifiers,
              !isEditingBody,
              searchIsEmpty,
              !hasMarkedText else { return nil }

        switch direction {
        case .left: return PanelPage.history
        case .right: return PanelPage.favorites
        }
    }

    static func allowsVerticalSelection(
        isListPage: Bool,
        hasDisallowedModifiers: Bool,
        isEditingBody: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        isListPage && !hasDisallowedModifiers && !isEditingBody && !hasMarkedText
    }

    static func allowsDetailToggle(
        isListPage: Bool,
        hasSelection: Bool,
        hasDisallowedModifiers: Bool,
        isEditingBody: Bool,
        isTextInputActive: Bool,
        searchIsEmpty: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        isListPage
            && hasSelection
            && !hasDisallowedModifiers
            && !isEditingBody
            && !hasMarkedText
            && (!isTextInputActive || searchIsEmpty)
    }
}
