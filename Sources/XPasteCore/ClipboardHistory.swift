import Foundation

public enum ClipboardFilter: String, CaseIterable, Sendable {
    case all
    case text
    case image
    case files

    public var displayName: String {
        switch self {
        case .all: "全部"
        case .text: "文本"
        case .image: "图片"
        case .files: "文件"
        }
    }

    public func includes(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: true
        case .text: item.kind == .text
        case .image: item.kind == .image
        case .files: item.kind == .files
        }
    }
}

public struct ClipboardHistory: Sendable {
    public private(set) var items: [ClipboardItem]

    public init(items: [ClipboardItem] = []) {
        self.items = items.sorted { $0.createdAt > $1.createdAt }
    }

    public mutating func insert(_ item: ClipboardItem, maxItems: Int) -> [ClipboardItem] {
        items.removeAll { $0.id == item.id }
        items.append(item)
        sort()
        return prune(maxItems: maxItems)
    }

    public mutating func promoteDuplicate(hash: String, kind: ClipboardKind, at date: Date, sourceApp: String?) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.contentHash == hash && $0.kind == kind }) else {
            return nil
        }
        items[index].createdAt = date
        items[index].lastUsedAt = date
        items[index].sourceAppBundleIdentifier = sourceApp
        items[index].captureCount += 1
        let item = items[index]
        sort()
        return item
    }

    @discardableResult
    public mutating func setFavorite(id: UUID, value: Bool) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[index].isFavorite = value
        return items[index]
    }

    @discardableResult
    public mutating func markUsed(id: UUID, at date: Date = Date()) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[index].lastUsedAt = date
        return items[index]
    }

    @discardableResult
    public mutating func replace(_ item: ClipboardItem) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        items[index] = item
        sort()
        return item
    }

    public mutating func remove(id: UUID) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    public mutating func clearUnfavorited() -> [ClipboardItem] {
        let removed = items.filter { !$0.isFavorite }
        items.removeAll { !$0.isFavorite }
        return removed
    }

    public mutating func prune(maxItems: Int) -> [ClipboardItem] {
        let limit = max(1, maxItems)
        var removed: [ClipboardItem] = []
        while items.count > limit {
            guard let index = items.lastIndex(where: { !$0.isFavorite }) else { break }
            removed.append(items.remove(at: index))
        }
        return removed
    }

    public func filtered(query: String, favoritesOnly: Bool, filter: ClipboardFilter) -> [ClipboardItem] {
        let terms = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)

        return items.filter { item in
            guard (!favoritesOnly || item.isFavorite), filter.includes(item) else { return false }
            return terms.allSatisfy { item.searchableText.localizedStandardContains($0) }
        }
    }

    private mutating func sort() {
        items.sort {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt > $1.createdAt
        }
    }
}
