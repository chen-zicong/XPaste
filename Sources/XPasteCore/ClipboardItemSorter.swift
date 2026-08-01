import Foundation

public enum ClipboardItemSortOrder: Sendable {
    case captureTime
    case recentUse
}

public enum ClipboardItemSorter {
    public static func sorted(
        _ items: [ClipboardItem],
        by order: ClipboardItemSortOrder
    ) -> [ClipboardItem] {
        items.sorted { lhs, rhs in
            let lhsPrimary = order == .recentUse ? lhs.lastUsedAt : lhs.createdAt
            let rhsPrimary = order == .recentUse ? rhs.lastUsedAt : rhs.createdAt
            if lhsPrimary != rhsPrimary { return lhsPrimary > rhsPrimary }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
