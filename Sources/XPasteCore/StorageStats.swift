import Foundation

public struct StorageStats: Equatable, Sendable {
    public var totalItems: Int
    public var favoriteItems: Int
    public var textItems: Int
    public var imageItems: Int
    public var fileItems: Int
    public var textBytes: Int
    public var imageBytes: Int
    public var fileReferenceBytes: Int
    public var metadataBytes: Int
    public var databaseBytes: Int
    public var walBytes: Int
    public var sharedMemoryBytes: Int
    public var assetBytes: Int
    public var archiveBytes: Int

    public init(items: [ClipboardItem], metadataBytes: Int = 0) {
        totalItems = items.count
        favoriteItems = items.count(where: \ClipboardItem.isFavorite)
        textItems = items.count { $0.kind == .text }
        imageItems = items.count { $0.kind == .image }
        fileItems = items.count { $0.kind == .files }
        textBytes = items.filter { $0.kind == .text }.reduce(0) { $0 + $1.storageBytes }
        imageBytes = items.filter { $0.kind == .image }.reduce(0) { $0 + $1.storageBytes }
        fileReferenceBytes = items.filter { $0.kind == .files }.reduce(0) { $0 + $1.storageBytes }
        self.metadataBytes = metadataBytes
        // Preserve the old initializer's totalBytes behavior. RepositoryState's
        // detailed initializer below supplies true allocated sizes.
        databaseBytes = metadataBytes + textBytes + fileReferenceBytes
        walBytes = 0
        sharedMemoryBytes = 0
        assetBytes = imageBytes
        archiveBytes = 0
    }

    public init(
        items: [ClipboardItem],
        databaseBytes: Int,
        walBytes: Int,
        sharedMemoryBytes: Int,
        assetBytes: Int,
        archiveBytes: Int = 0
    ) {
        self.init(items: items, metadataBytes: databaseBytes + walBytes + sharedMemoryBytes)
        self.databaseBytes = databaseBytes
        self.walBytes = walBytes
        self.sharedMemoryBytes = sharedMemoryBytes
        self.assetBytes = assetBytes
        self.archiveBytes = archiveBytes
    }

    /// Actual allocated on-disk bytes. Text and file references live inside
    /// SQLite, so they are intentionally not added a second time here.
    public var totalBytes: Int { databaseBytes + walBytes + sharedMemoryBytes + assetBytes + archiveBytes }

    public var databaseSidecarBytes: Int { walBytes + sharedMemoryBytes }

    public func fraction(for kind: ClipboardKind) -> Double {
        let contentTotal = max(1, textBytes + imageBytes + fileReferenceBytes)
        let value: Int
        switch kind {
        case .text: value = textBytes
        case .image: value = imageBytes
        case .files: value = fileReferenceBytes
        }
        return Double(value) / Double(contentTotal)
    }
}

private extension Sequence {
    func count(where predicate: (Element) throws -> Bool) rethrows -> Int {
        try reduce(into: 0) { result, element in
            if try predicate(element) { result += 1 }
        }
    }
}
