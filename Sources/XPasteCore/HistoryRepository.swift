import Foundation
import UniformTypeIdentifiers

public enum HistoryRepositoryError: LocalizedError {
    case unsupportedSchema(Int)
    case invalidImagePayload
    case invalidDatabaseRecord(String)
    case fileReferenceUnavailable
    case fileAuthorizationRequired

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "历史数据版本 \(version) 暂不受支持"
        case .invalidImagePayload:
            "图片数据不完整"
        case .invalidDatabaseRecord(let identifier):
            "历史数据库中存在无法读取的记录：\(identifier)"
        case .fileReferenceUnavailable:
            "原文件已移动、删除或当前磁盘未连接"
        case .fileAuthorizationRequired:
            "旧文件记录缺少可恢复的访问授权，请重新复制该文件"
        }
    }
}

public struct RepositoryState: Sendable {
    public var items: [ClipboardItem]
    /// Kept for source compatibility. This is the actual allocated size of the
    /// SQLite database, WAL and shared-memory files combined.
    public var metadataBytes: Int
    public var databaseBytes: Int
    public var walBytes: Int
    public var sharedMemoryBytes: Int
    public var assetBytes: Int
    public var archiveBytes: Int

    public init(items: [ClipboardItem], metadataBytes: Int) {
        self.items = items
        self.metadataBytes = metadataBytes
        self.databaseBytes = metadataBytes
        self.walBytes = 0
        self.sharedMemoryBytes = 0
        self.assetBytes = items
            .filter { $0.kind == .image }
            .reduce(0) { $0 + $1.storageBytes }
        self.archiveBytes = 0
    }

    public init(
        items: [ClipboardItem],
        databaseBytes: Int,
        walBytes: Int,
        sharedMemoryBytes: Int,
        assetBytes: Int,
        archiveBytes: Int = 0
    ) {
        self.items = items
        self.databaseBytes = databaseBytes
        self.walBytes = walBytes
        self.sharedMemoryBytes = sharedMemoryBytes
        self.assetBytes = assetBytes
        self.archiveBytes = archiveBytes
        self.metadataBytes = databaseBytes + walBytes + sharedMemoryBytes
    }

    public var storageStats: StorageStats {
        StorageStats(
            items: items,
            databaseBytes: databaseBytes,
            walBytes: walBytes,
            sharedMemoryBytes: sharedMemoryBytes,
            assetBytes: assetBytes,
            archiveBytes: archiveBytes
        )
    }
}

public actor HistoryRepository {
    public nonisolated let baseURL: URL
    public nonisolated let assetsURL: URL

    private let legacyIndexURL: URL
    private let databaseURL: URL
    private let fileManager: FileManager
    private var database: SQLiteDatabase?
    private var history = ClipboardHistory()
    private var assetAllocations: [String: Int] = [:]
    private var hasLoaded = false

    private struct Archive: Codable {
        var schemaVersion: Int
        var items: [ClipboardItem]
    }

    private struct AssetReference: Hashable {
        var original: String?
        var thumbnail: String?

        var paths: [String] {
            [original, thumbnail].compactMap { $0 }
        }
    }

    private struct StoredAsset {
        var relativePath: String
        var wasCreated: Bool
    }

    private static let schemaVersion = 3

    public init(baseURL: URL, fileManager: FileManager = .default) {
        self.baseURL = baseURL
        self.assetsURL = baseURL.appendingPathComponent("Assets", isDirectory: true)
        self.legacyIndexURL = baseURL.appendingPathComponent("history.json")
        self.databaseURL = baseURL.appendingPathComponent("history.sqlite")
        self.fileManager = fileManager
    }

    public nonisolated func assetURL(fileName: String) -> URL {
        let root = assetsURL.standardizedFileURL
        let candidate = root.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        let prefix = root.path + "/"
        guard candidate.path.hasPrefix(prefix) else {
            // Never allow migrated/corrupt metadata to resolve outside Assets.
            return root.appendingPathComponent("Invalid/\(ContentHasher.text(fileName))", isDirectory: false)
        }
        return candidate
    }

    public func load() throws -> RepositoryState {
        if hasLoaded { return state() }

        try prepareDirectories()
        let database = try openDatabase()
        try prepareSchema(in: database)
        try migrateLegacyJSONIfNeeded(into: database)

        history = ClipboardHistory(items: try readAllItems(from: database))
        try reconcileAssets()
        hasLoaded = true
        return state()
    }

    public func search(
        query: String,
        favoritesOnly: Bool,
        filter: ClipboardFilter,
        sortOrder: ClipboardItemSortOrder = .captureTime,
        limit: Int = 5_000
    ) throws -> [ClipboardItem] {
        try ensureLoaded()
        let database = try requireDatabase()
        let terms = query
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else {
            return history.filtered(query: "", favoritesOnly: favoritesOnly, filter: filter)
        }

        var predicates: [String] = []
        var bindings: [SQLiteValue] = []
        if terms.allSatisfy({ $0.count >= 3 }) {
            let FTSQuery = terms
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: " AND ")
            predicates.append("item_search MATCH ?")
            bindings.append(.text(FTSQuery))
        } else {
            for term in terms {
                predicates.append("item_search.content LIKE ? ESCAPE '\\'")
                bindings.append(.text(likePattern(for: term)))
            }
        }
        if favoritesOnly { predicates.append("items.is_favorite = 1") }
        if filter != .all {
            predicates.append("items.kind = ?")
            bindings.append(.text(filter.rawValue))
        }
        bindings.append(.integer(Int64(max(1, limit))))

        let orderColumn = sortOrder == .recentUse ? "items.last_used_at" : "items.created_at"
        let IDs = try database.query(
            """
            SELECT items.id
            FROM item_search
            JOIN items ON items.id = item_search.id
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY \(orderColumn) DESC, items.created_at DESC, items.id ASC
            LIMIT ?
            """,
            bindings: bindings
        ) { statement in
            SQLiteDatabase.text(statement, column: 0).flatMap(UUID.init(uuidString:))
        }.compactMap { $0 }

        let byID = Dictionary(uniqueKeysWithValues: history.items.map { ($0.id, $0) })
        return IDs.compactMap { byID[$0] }
    }

    public func record(_ payload: CapturePayload, maxItems: Int) throws -> RepositoryState {
        try ensureLoaded()
        let database = try requireDatabase()

        if let duplicateID = try findDuplicateID(
            hash: payload.contentHash,
            kind: payload.kind,
            in: database
        ) {
            var repairedOriginal: StoredAsset?
            var repairedThumbnail: StoredAsset?
            var stalePaths: [String] = []
            let duplicate = try item(id: duplicateID, in: database)

            if payload.kind == .image, let duplicate {
                do {
                    if !assetExists(duplicate.imageFileName) {
                        guard let imageData = payload.imageData else {
                            throw HistoryRepositoryError.invalidImagePayload
                        }
                        repairedOriginal = try storeAsset(
                            imageData,
                            directory: "Originals",
                            preferredExtension: preferredExtension(
                                for: payload.imageUTI ?? duplicate.imageUTI,
                                data: imageData
                            )
                        )
                        stalePaths.append(contentsOf: [duplicate.imageFileName].compactMap { $0 })
                    }

                    if !assetExists(duplicate.thumbnailFileName),
                       let thumbnailData = payload.thumbnailData {
                        repairedThumbnail = try storeAsset(
                            thumbnailData,
                            directory: "Thumbnails",
                            preferredExtension: detectedExtension(for: thumbnailData) ?? "jpg"
                        )
                        stalePaths.append(contentsOf: [duplicate.thumbnailFileName].compactMap { $0 })
                    }
                } catch {
                    removeCreatedAssets(
                        [repairedOriginal, repairedThumbnail].compactMap { $0 },
                        in: database
                    )
                    throw error
                }
            }

            do {
                let removed = try database.transaction {
                    if payload.kind == .image, let duplicate {
                        let originalPath = repairedOriginal?.relativePath ?? duplicate.imageFileName
                        let thumbnailPath = repairedThumbnail?.relativePath ?? duplicate.thumbnailFileName
                        try database.execute(
                            """
                            UPDATE items
                            SET created_at = ?, last_used_at = ?, source_app_bundle_identifier = ?,
                                capture_count = capture_count + 1, image_file_name = ?,
                                thumbnail_file_name = ?, image_uti = ?, content_bytes = ?,
                                thumbnail_bytes = ?
                            WHERE id = ?
                            """,
                            bindings: [
                                .real(payload.capturedAt.timeIntervalSince1970),
                                .real(payload.capturedAt.timeIntervalSince1970),
                                optionalText(payload.sourceAppBundleIdentifier),
                                optionalText(originalPath),
                                optionalText(thumbnailPath),
                                optionalText(payload.imageUTI ?? duplicate.imageUTI),
                                .integer(Int64(repairedOriginal == nil
                                    ? duplicate.contentBytes
                                    : payload.imageData?.count ?? duplicate.contentBytes)),
                                .integer(Int64(repairedThumbnail == nil
                                    ? duplicate.thumbnailBytes
                                    : payload.thumbnailData?.count ?? duplicate.thumbnailBytes)),
                                .text(duplicateID.uuidString)
                            ]
                        )
                    } else if payload.kind == .files {
                        let encodedBookmarks = try encodeBookmarks(payload.fileBookmarks)
                        try database.execute(
                            """
                            UPDATE items
                            SET created_at = ?, last_used_at = ?, source_app_bundle_identifier = ?,
                                capture_count = capture_count + 1, file_paths = ?, file_bookmarks = ?
                            WHERE id = ?
                            """,
                            bindings: [
                                .real(payload.capturedAt.timeIntervalSince1970),
                                .real(payload.capturedAt.timeIntervalSince1970),
                                optionalText(payload.sourceAppBundleIdentifier),
                                .text(encodePaths(payload.filePaths)),
                                .blob(encodedBookmarks),
                                .text(duplicateID.uuidString)
                            ]
                        )
                    } else {
                        try database.execute(
                            """
                            UPDATE items
                            SET created_at = ?, last_used_at = ?, source_app_bundle_identifier = ?,
                                capture_count = capture_count + 1
                            WHERE id = ?
                            """,
                            bindings: [
                                .real(payload.capturedAt.timeIntervalSince1970),
                                .real(payload.capturedAt.timeIntervalSince1970),
                                optionalText(payload.sourceAppBundleIdentifier),
                                .text(duplicateID.uuidString)
                            ]
                        )
                    }
                    return try prune(maxItems: maxItems, in: database)
                }
                removeAssetsIfUnreferenced(
                    stalePaths + removed.flatMap(\.paths),
                    in: database
                )
            } catch {
                removeCreatedAssets(
                    [repairedOriginal, repairedThumbnail].compactMap { $0 },
                    in: database
                )
                throw error
            }
            try refreshHistory(from: database)
            return state()
        }

        let id = UUID()
        var original: StoredAsset?
        var thumbnail: StoredAsset?
        var item: ClipboardItem

        if payload.kind == .image {
            guard let imageData = payload.imageData else {
                throw HistoryRepositoryError.invalidImagePayload
            }

            do {
                original = try storeAsset(
                    imageData,
                    directory: "Originals",
                    preferredExtension: preferredExtension(for: payload.imageUTI, data: imageData)
                )
                if let thumbnailData = payload.thumbnailData {
                    thumbnail = try storeAsset(
                        thumbnailData,
                        directory: "Thumbnails",
                        preferredExtension: detectedExtension(for: thumbnailData) ?? "jpg"
                    )
                }
            } catch {
                removeCreatedAssets([original, thumbnail].compactMap { $0 }, in: database)
                throw error
            }

            item = ClipboardItem(
                id: id,
                kind: .image,
                imageFileName: original?.relativePath,
                thumbnailFileName: thumbnail?.relativePath,
                imageUTI: payload.imageUTI,
                sourceAppBundleIdentifier: payload.sourceAppBundleIdentifier,
                createdAt: payload.capturedAt,
                contentHash: payload.contentHash,
                contentBytes: imageData.count,
                thumbnailBytes: payload.thumbnailData?.count ?? 0,
                captureCount: 1
            )
        } else if payload.kind == .text {
            item = ClipboardItem(
                id: id,
                kind: .text,
                text: payload.text,
                sourceAppBundleIdentifier: payload.sourceAppBundleIdentifier,
                createdAt: payload.capturedAt,
                contentHash: payload.contentHash,
                contentBytes: payload.text?.utf8.count ?? 0,
                captureCount: 1
            )
        } else {
            item = ClipboardItem(
                id: id,
                kind: .files,
                filePaths: payload.filePaths,
                fileBookmarks: payload.fileBookmarks,
                sourceAppBundleIdentifier: payload.sourceAppBundleIdentifier,
                createdAt: payload.capturedAt,
                contentHash: payload.contentHash,
                contentBytes: payload.filePaths.reduce(0) { $0 + $1.utf8.count },
                captureCount: 1
            )
        }

        do {
            let removed = try database.transaction {
                try insert(item, into: database)
                return try prune(maxItems: maxItems, in: database)
            }
            removeAssetsIfUnreferenced(removed.flatMap(\.paths), in: database)
        } catch {
            removeCreatedAssets([original, thumbnail].compactMap { $0 }, in: database)
            throw error
        }

        try refreshHistory(from: database)
        return state()
    }

    public func setFavorite(id: UUID, value: Bool) throws -> RepositoryState {
        try ensureLoaded()
        let database = try requireDatabase()
        try database.execute(
            "UPDATE items SET is_favorite = ? WHERE id = ?",
            bindings: [.integer(value ? 1 : 0), .text(id.uuidString)]
        )
        try refreshHistory(from: database)
        return state()
    }

    public func markUsed(id: UUID, at date: Date = Date()) throws -> RepositoryState {
        try ensureLoaded()
        let database = try requireDatabase()
        try database.execute(
            "UPDATE items SET last_used_at = ? WHERE id = ?",
            bindings: [.real(date.timeIntervalSince1970), .text(id.uuidString)]
        )
        _ = history.markUsed(id: id, at: date)
        return state()
    }

    /// Resolves persistent file bookmarks immediately before publishing them
    /// back to the system pasteboard. Legacy path-only records are migrated on
    /// first use when macOS still permits XPaste to create a scoped bookmark.
    public func resolveFileURLs(id: UUID) throws -> [URL] {
        try ensureLoaded()
        let database = try requireDatabase()
        guard let current = try item(id: id, in: database), current.kind == .files else {
            throw HistoryRepositoryError.fileReferenceUnavailable
        }

        var resolvedURLs: [URL] = []
        var bookmarks = current.fileBookmarks
        if bookmarks.count < current.filePaths.count {
            bookmarks.append(contentsOf: repeatElement(nil, count: current.filePaths.count - bookmarks.count))
        } else if bookmarks.count > current.filePaths.count {
            bookmarks = Array(bookmarks.prefix(current.filePaths.count))
        }
        var didChange = bookmarks != current.fileBookmarks

        for index in current.filePaths.indices {
            let originalURL = URL(fileURLWithPath: current.filePaths[index]).standardizedFileURL
            var resolvedURL: URL
            var bookmarkIsStale = false

            if let bookmark = bookmarks[index] {
                do {
                    resolvedURL = try URL(
                        resolvingBookmarkData: bookmark,
                        options: [.withSecurityScope],
                        relativeTo: nil,
                        bookmarkDataIsStale: &bookmarkIsStale
                    ).standardizedFileURL
                } catch {
                    bookmarks[index] = nil
                    didChange = true
                    resolvedURL = originalURL
                }
            } else {
                resolvedURL = originalURL
            }

            guard fileManager.fileExists(atPath: resolvedURL.path),
                  fileManager.isReadableFile(atPath: resolvedURL.path) else {
                throw HistoryRepositoryError.fileReferenceUnavailable
            }

            if bookmarks[index] == nil || bookmarkIsStale {
                do {
                    bookmarks[index] = try makeFileBookmark(for: resolvedURL)
                    didChange = true
                } catch {
                    throw HistoryRepositoryError.fileAuthorizationRequired
                }
            }
            resolvedURLs.append(resolvedURL)
        }

        if didChange {
            let paths = resolvedURLs.map(\.path)
            try database.execute(
                """
                UPDATE items
                SET file_paths = ?, file_bookmarks = ?, content_hash = ?, content_bytes = ?
                WHERE id = ? AND kind = ?
                """,
                bindings: [
                    .text(encodePaths(paths)),
                    .blob(try encodeBookmarks(bookmarks)),
                    .text(ContentHasher.files(paths)),
                    .integer(Int64(paths.reduce(0) { $0 + $1.utf8.count })),
                    .text(id.uuidString),
                    .text(ClipboardKind.files.rawValue)
                ]
            )
            try refreshHistory(from: database)
        }
        return resolvedURLs
    }

    public func updateText(id: UUID, text: String) throws -> RepositoryState {
        try ensureLoaded()
        let database = try requireDatabase()
        guard let current = try item(id: id, in: database), current.kind == .text else {
            return state()
        }
        let now = Date()
        let hash = ContentHasher.text(text)
        var retiredReferences: [AssetReference] = []

        try database.transaction {
            let duplicates = try duplicateItems(
                hash: hash,
                kind: .text,
                excluding: id,
                in: database
            )
            retiredReferences = duplicates.map {
                AssetReference(original: $0.imageFileName, thumbnail: $0.thumbnailFileName)
            }
            let favorite = current.isFavorite || duplicates.contains(where: \.isFavorite)
            let captureCount = duplicates.reduce(current.captureCount) {
                $0 + max(1, $1.captureCount)
            }
            let editCount = duplicates.reduce(current.editCount) { $0 + $1.editCount } + 1
            let createdAt = duplicates.reduce(current.createdAt) { max($0, $1.createdAt) }
            let lastUsedAt = duplicates.reduce(current.lastUsedAt) { max($0, $1.lastUsedAt) }

            for duplicate in duplicates {
                try database.execute(
                    "DELETE FROM items WHERE id = ?",
                    bindings: [.text(duplicate.id.uuidString)]
                )
            }
            try database.execute(
                """
                UPDATE items
                SET text = ?, content_hash = ?, content_bytes = ?, edited_at = ?,
                    edit_count = ?, capture_count = ?, is_favorite = ?, created_at = ?,
                    last_used_at = ?
                WHERE id = ? AND kind = ?
                """,
                bindings: [
                    .text(text),
                    .text(hash),
                    .integer(Int64(text.utf8.count)),
                    .real(now.timeIntervalSince1970),
                    .integer(Int64(editCount)),
                    .integer(Int64(captureCount)),
                    .integer(favorite ? 1 : 0),
                    .real(createdAt.timeIntervalSince1970),
                    .real(lastUsedAt.timeIntervalSince1970),
                    .text(id.uuidString),
                    .text(ClipboardKind.text.rawValue)
                ]
            )
        }
        removeAssetsIfUnreferenced(retiredReferences.flatMap(\.paths), in: database)
        try refreshHistory(from: database)
        return state()
    }

    public func updateImage(
        id: UUID,
        imageData: Data,
        thumbnailData: Data,
        contentHash: String
    ) throws -> RepositoryState {
        try ensureLoaded()
        let database = try requireDatabase()
        guard let current = try item(id: id, in: database), current.kind == .image else {
            return state()
        }

        let original: StoredAsset
        let thumbnail: StoredAsset
        do {
            original = try storeAsset(
                imageData,
                directory: "Originals",
                preferredExtension: preferredExtension(for: current.imageUTI, data: imageData)
            )
            do {
                thumbnail = try storeAsset(
                    thumbnailData,
                    directory: "Thumbnails",
                    preferredExtension: detectedExtension(for: thumbnailData) ?? "jpg"
                )
            } catch {
                removeCreatedAssets([original], in: database)
                throw error
            }
        }

        var retiredReferences: [AssetReference] = []
        do {
            try database.transaction {
                let duplicates = try duplicateItems(
                    hash: contentHash,
                    kind: .image,
                    excluding: id,
                    in: database
                )
                retiredReferences = [
                    AssetReference(
                        original: current.imageFileName,
                        thumbnail: current.thumbnailFileName
                    )
                ] + duplicates.map {
                    AssetReference(original: $0.imageFileName, thumbnail: $0.thumbnailFileName)
                }
                let favorite = current.isFavorite || duplicates.contains(where: \.isFavorite)
                let captureCount = duplicates.reduce(current.captureCount) {
                    $0 + max(1, $1.captureCount)
                }
                let editCount = duplicates.reduce(current.editCount) { $0 + $1.editCount } + 1
                let createdAt = duplicates.reduce(current.createdAt) { max($0, $1.createdAt) }
                let lastUsedAt = duplicates.reduce(current.lastUsedAt) { max($0, $1.lastUsedAt) }

                for duplicate in duplicates {
                    try database.execute(
                        "DELETE FROM items WHERE id = ?",
                        bindings: [.text(duplicate.id.uuidString)]
                    )
                }
                try database.execute(
                """
                UPDATE items
                SET image_file_name = ?, thumbnail_file_name = ?, content_hash = ?,
                    content_bytes = ?, thumbnail_bytes = ?, edited_at = ?, edit_count = ?,
                    capture_count = ?, is_favorite = ?, created_at = ?, last_used_at = ?
                WHERE id = ? AND kind = ?
                """,
                bindings: [
                    .text(original.relativePath),
                    .text(thumbnail.relativePath),
                    .text(contentHash),
                    .integer(Int64(imageData.count)),
                    .integer(Int64(thumbnailData.count)),
                    .real(Date().timeIntervalSince1970),
                    .integer(Int64(editCount)),
                    .integer(Int64(captureCount)),
                    .integer(favorite ? 1 : 0),
                    .real(createdAt.timeIntervalSince1970),
                    .real(lastUsedAt.timeIntervalSince1970),
                    .text(id.uuidString),
                    .text(ClipboardKind.image.rawValue)
                ]
                )
            }
        } catch {
            removeCreatedAssets([original, thumbnail], in: database)
            throw error
        }

        removeAssetsIfUnreferenced(retiredReferences.flatMap(\.paths), in: database)
        try refreshHistory(from: database)
        return state()
    }

    public func delete(id: UUID) throws -> RepositoryState {
        try ensureLoaded()
        let database = try requireDatabase()
        let reference = try assetReference(id: id, in: database)
        try database.execute("DELETE FROM items WHERE id = ?", bindings: [.text(id.uuidString)])
        removeAssetsIfUnreferenced(reference?.paths ?? [], in: database)
        try refreshHistory(from: database)
        return state()
    }

    public func clearUnfavorited() throws -> RepositoryState {
        try ensureLoaded()
        let database = try requireDatabase()
        let references = try assetReferences(
            whereClause: "is_favorite = 0",
            bindings: [],
            in: database
        )
        try database.execute("DELETE FROM items WHERE is_favorite = 0")
        removeAssetsIfUnreferenced(references.flatMap(\.paths), in: database)
        try refreshHistory(from: database)
        return state()
    }

    public func enforceLimit(_ maxItems: Int) throws -> RepositoryState {
        try ensureLoaded()
        let database = try requireDatabase()
        let removed = try database.transaction {
            try prune(maxItems: maxItems, in: database)
        }
        removeAssetsIfUnreferenced(removed.flatMap(\.paths), in: database)
        try refreshHistory(from: database)
        return state()
    }

    private func ensureLoaded() throws {
        if !hasLoaded { _ = try load() }
    }

    private func makeFileBookmark(for URL: URL) throws -> Data {
        try URL.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: [.fileResourceIdentifierKey],
            relativeTo: nil
        )
    }

    private func encodePaths(_ paths: [String]) -> String {
        let data = (try? JSONEncoder().encode(paths)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func encodeBookmarks(_ bookmarks: [Data?]) throws -> Data {
        try JSONEncoder().encode(bookmarks)
    }

    private func decodeBookmarks(_ data: Data?) -> [Data?] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([Data?].self, from: data)) ?? []
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
    }

    private func openDatabase() throws -> SQLiteDatabase {
        if let database { return database }
        let opened = try SQLiteDatabase(url: databaseURL)
        database = opened
        return opened
    }

    private func requireDatabase() throws -> SQLiteDatabase {
        if let database { return database }
        return try openDatabase()
    }

    private func prepareSchema(in database: SQLiteDatabase) throws {
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA wal_autocheckpoint = 500")
        try database.execute("PRAGMA journal_size_limit = 8388608")
        try database.execute("PRAGMA cache_size = -4096")

        let version = try database.scalarInt("PRAGMA user_version")
        guard version <= Self.schemaVersion else {
            throw HistoryRepositoryError.unsupportedSchema(version)
        }

        if version == 0 {
            try database.execute("PRAGMA auto_vacuum = INCREMENTAL")
            try database.transaction {
                try database.execute(
                    """
                    CREATE TABLE IF NOT EXISTS items (
                        id TEXT PRIMARY KEY NOT NULL,
                        kind TEXT NOT NULL,
                        text TEXT,
                        image_file_name TEXT,
                        thumbnail_file_name TEXT,
                        image_uti TEXT,
                        file_paths TEXT NOT NULL DEFAULT '[]',
                        source_app_bundle_identifier TEXT,
                        created_at REAL NOT NULL,
                        last_used_at REAL NOT NULL,
                        edited_at REAL,
                        is_favorite INTEGER NOT NULL DEFAULT 0,
                        content_hash TEXT NOT NULL,
                        content_bytes INTEGER NOT NULL DEFAULT 0,
                        thumbnail_bytes INTEGER NOT NULL DEFAULT 0,
                        edit_count INTEGER NOT NULL DEFAULT 0,
                        capture_count INTEGER NOT NULL DEFAULT 1,
                        file_bookmarks BLOB NOT NULL DEFAULT X'5B5D'
                    )
                    """
                )
                try database.execute(
                    "CREATE INDEX IF NOT EXISTS idx_items_recent ON items(created_at DESC, id ASC)"
                )
                try database.execute(
                    "CREATE INDEX IF NOT EXISTS idx_items_hash ON items(kind, content_hash, created_at DESC)"
                )
                try database.execute(
                    "CREATE INDEX IF NOT EXISTS idx_items_favorites ON items(is_favorite, created_at DESC)"
                )
                try database.execute(
                    "PRAGMA user_version = \(Self.schemaVersion)"
                )
            }
        }

        if version < 2 {
            try database.transaction {
                try database.execute(
                    "CREATE VIRTUAL TABLE IF NOT EXISTS item_search USING fts5(id UNINDEXED, content, tokenize='trigram')"
                )
                try database.execute(
                    """
                    CREATE TRIGGER IF NOT EXISTS items_search_insert AFTER INSERT ON items BEGIN
                        INSERT INTO item_search(id, content)
                        VALUES (new.id, COALESCE(new.text, '') || ' ' || new.file_paths || ' ' || COALESCE(new.source_app_bundle_identifier, ''));
                    END
                    """
                )
                try database.execute(
                    """
                    CREATE TRIGGER IF NOT EXISTS items_search_update
                    AFTER UPDATE OF text, file_paths, source_app_bundle_identifier, kind ON items BEGIN
                        DELETE FROM item_search WHERE id = old.id;
                        INSERT INTO item_search(id, content)
                        VALUES (new.id, COALESCE(new.text, '') || ' ' || new.file_paths || ' ' || COALESCE(new.source_app_bundle_identifier, ''));
                    END
                    """
                )
                try database.execute(
                    """
                    CREATE TRIGGER IF NOT EXISTS items_search_delete AFTER DELETE ON items BEGIN
                        DELETE FROM item_search WHERE id = old.id;
                    END
                    """
                )
                try database.execute("DELETE FROM item_search")
                try database.execute(
                    """
                    INSERT INTO item_search(id, content)
                    SELECT id, COALESCE(text, '') || ' ' || file_paths || ' ' || COALESCE(source_app_bundle_identifier, '')
                    FROM items
                    """
                )
                try database.execute("PRAGMA user_version = \(Self.schemaVersion)")
            }
        }
        if version > 0, version < 3 {
            try database.transaction {
                try database.execute(
                    "ALTER TABLE items ADD COLUMN file_bookmarks BLOB NOT NULL DEFAULT X'5B5D'"
                )
                try database.execute("PRAGMA user_version = \(Self.schemaVersion)")
            }
        }
        try database.execute(
            "CREATE INDEX IF NOT EXISTS idx_items_last_used ON items(last_used_at DESC, created_at DESC, id ASC)"
        )
    }

    private func migrateLegacyJSONIfNeeded(into database: SQLiteDatabase) throws {
        guard try database.scalarInt("SELECT COUNT(*) FROM items") == 0,
              fileManager.fileExists(atPath: legacyIndexURL.path) else {
            return
        }

        let archive: Archive
        do {
            let data = try Data(contentsOf: legacyIndexURL, options: .mappedIfSafe)
            archive = try decodeLegacyArchive(data)
            guard archive.schemaVersion <= 1 else {
                throw HistoryRepositoryError.unsupportedSchema(archive.schemaVersion)
            }
        } catch let error as HistoryRepositoryError {
            throw error
        } catch {
            try preserveCorruptLegacyIndex()
            return
        }

        try database.transaction {
            for item in archive.items {
                try insert(item, into: database)
            }
        }
        preserveMigratedLegacyIndex()
    }

    private func decodeLegacyArchive(_ data: Data) throws -> Archive {
        let ISO8601Decoder = JSONDecoder()
        ISO8601Decoder.dateDecodingStrategy = .iso8601
        if let archive = try? ISO8601Decoder.decode(Archive.self, from: data) {
            return archive
        }
        return try JSONDecoder().decode(Archive.self, from: data)
    }

    private func insert(_ item: ClipboardItem, into database: SQLiteDatabase) throws {
        let paths = encodePaths(item.filePaths)
        let bookmarks = try encodeBookmarks(item.fileBookmarks)
        try database.execute(
            """
            INSERT OR REPLACE INTO items (
                id, kind, text, image_file_name, thumbnail_file_name, image_uti, file_paths,
                source_app_bundle_identifier, created_at, last_used_at, edited_at, is_favorite,
                content_hash, content_bytes, thumbnail_bytes, edit_count, capture_count, file_bookmarks
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(item.id.uuidString),
                .text(item.kind.rawValue),
                optionalText(item.text),
                optionalText(validatedAssetPath(item.imageFileName)),
                optionalText(validatedAssetPath(item.thumbnailFileName)),
                optionalText(item.imageUTI),
                .text(paths),
                optionalText(item.sourceAppBundleIdentifier),
                .real(item.createdAt.timeIntervalSince1970),
                .real(item.lastUsedAt.timeIntervalSince1970),
                optionalDate(item.editedAt),
                .integer(item.isFavorite ? 1 : 0),
                .text(item.contentHash),
                .integer(Int64(item.contentBytes)),
                .integer(Int64(item.thumbnailBytes)),
                .integer(Int64(item.editCount)),
                .integer(Int64(max(1, item.captureCount))),
                .blob(bookmarks)
            ]
        )
    }

    private func readAllItems(from database: SQLiteDatabase) throws -> [ClipboardItem] {
        try database.query(
            """
            SELECT id, kind, text, image_file_name, thumbnail_file_name, image_uti, file_paths,
                   source_app_bundle_identifier, created_at, last_used_at, edited_at, is_favorite,
                   content_hash, content_bytes, thumbnail_bytes, edit_count, capture_count, file_bookmarks
            FROM items
            ORDER BY created_at DESC, id ASC
            """
        ) { statement in
            guard let rawID = SQLiteDatabase.text(statement, column: 0),
                  let id = UUID(uuidString: rawID),
                  let rawKind = SQLiteDatabase.text(statement, column: 1),
                  let kind = ClipboardKind(rawValue: rawKind),
                  let hash = SQLiteDatabase.text(statement, column: 12) else {
                throw HistoryRepositoryError.invalidDatabaseRecord(
                    SQLiteDatabase.text(statement, column: 0) ?? "unknown"
                )
            }

            let pathsString = SQLiteDatabase.text(statement, column: 6) ?? "[]"
            let paths = (try? JSONDecoder().decode([String].self, from: Data(pathsString.utf8))) ?? []
            let editedTimestamp: Date? = if SQLiteDatabase.text(statement, column: 10) == nil {
                nil
            } else {
                Date(timeIntervalSince1970: SQLiteDatabase.double(statement, column: 10))
            }

            return ClipboardItem(
                id: id,
                kind: kind,
                text: SQLiteDatabase.text(statement, column: 2),
                imageFileName: validatedAssetPath(SQLiteDatabase.text(statement, column: 3)),
                thumbnailFileName: validatedAssetPath(SQLiteDatabase.text(statement, column: 4)),
                imageUTI: SQLiteDatabase.text(statement, column: 5),
                filePaths: paths,
                fileBookmarks: decodeBookmarks(SQLiteDatabase.data(statement, column: 17)),
                sourceAppBundleIdentifier: SQLiteDatabase.text(statement, column: 7),
                createdAt: Date(timeIntervalSince1970: SQLiteDatabase.double(statement, column: 8)),
                lastUsedAt: Date(timeIntervalSince1970: SQLiteDatabase.double(statement, column: 9)),
                editedAt: editedTimestamp,
                isFavorite: SQLiteDatabase.int(statement, column: 11) != 0,
                contentHash: hash,
                contentBytes: SQLiteDatabase.int(statement, column: 13),
                thumbnailBytes: SQLiteDatabase.int(statement, column: 14),
                editCount: SQLiteDatabase.int(statement, column: 15),
                captureCount: SQLiteDatabase.int(statement, column: 16)
            )
        }
    }

    private func refreshHistory(from database: SQLiteDatabase) throws {
        history = ClipboardHistory(items: try readAllItems(from: database))
    }

    private func findDuplicateID(
        hash: String,
        kind: ClipboardKind,
        in database: SQLiteDatabase
    ) throws -> UUID? {
        try database.query(
            """
            SELECT id FROM items
            WHERE kind = ? AND content_hash = ?
            ORDER BY created_at DESC LIMIT 1
            """,
            bindings: [.text(kind.rawValue), .text(hash)]
        ) { statement in
            SQLiteDatabase.text(statement, column: 0).flatMap(UUID.init(uuidString:))
        }.first ?? nil
    }

    private func duplicateItems(
        hash: String,
        kind: ClipboardKind,
        excluding id: UUID,
        in database: SQLiteDatabase
    ) throws -> [ClipboardItem] {
        let IDs = try database.query(
            """
            SELECT id FROM items
            WHERE kind = ? AND content_hash = ? AND id <> ?
            ORDER BY created_at DESC, id ASC
            """,
            bindings: [.text(kind.rawValue), .text(hash), .text(id.uuidString)]
        ) { statement in
            SQLiteDatabase.text(statement, column: 0).flatMap(UUID.init(uuidString:))
        }.compactMap { $0 }

        var duplicates: [ClipboardItem] = []
        duplicates.reserveCapacity(IDs.count)
        for duplicateID in IDs {
            if let duplicate = try item(id: duplicateID, in: database) {
                duplicates.append(duplicate)
            }
        }
        return duplicates
    }

    private func item(id: UUID, in database: SQLiteDatabase) throws -> ClipboardItem? {
        try database.query(
            """
            SELECT id, kind, text, image_file_name, thumbnail_file_name, image_uti, file_paths,
                   source_app_bundle_identifier, created_at, last_used_at, edited_at, is_favorite,
                   content_hash, content_bytes, thumbnail_bytes, edit_count, capture_count, file_bookmarks
            FROM items WHERE id = ? LIMIT 1
            """,
            bindings: [.text(id.uuidString)]
        ) { statement in
            guard let rawID = SQLiteDatabase.text(statement, column: 0),
                  let decodedID = UUID(uuidString: rawID),
                  let rawKind = SQLiteDatabase.text(statement, column: 1),
                  let kind = ClipboardKind(rawValue: rawKind),
                  let hash = SQLiteDatabase.text(statement, column: 12) else {
                throw HistoryRepositoryError.invalidDatabaseRecord(id.uuidString)
            }
            let pathJSON = SQLiteDatabase.text(statement, column: 6) ?? "[]"
            let paths = (try? JSONDecoder().decode([String].self, from: Data(pathJSON.utf8))) ?? []
            let editedAt: Date? = sqliteColumnIsNull(statement, column: 10)
                ? nil
                : Date(timeIntervalSince1970: SQLiteDatabase.double(statement, column: 10))
            return ClipboardItem(
                id: decodedID,
                kind: kind,
                text: SQLiteDatabase.text(statement, column: 2),
                imageFileName: validatedAssetPath(SQLiteDatabase.text(statement, column: 3)),
                thumbnailFileName: validatedAssetPath(SQLiteDatabase.text(statement, column: 4)),
                imageUTI: SQLiteDatabase.text(statement, column: 5),
                filePaths: paths,
                fileBookmarks: decodeBookmarks(SQLiteDatabase.data(statement, column: 17)),
                sourceAppBundleIdentifier: SQLiteDatabase.text(statement, column: 7),
                createdAt: Date(timeIntervalSince1970: SQLiteDatabase.double(statement, column: 8)),
                lastUsedAt: Date(timeIntervalSince1970: SQLiteDatabase.double(statement, column: 9)),
                editedAt: editedAt,
                isFavorite: SQLiteDatabase.int(statement, column: 11) != 0,
                contentHash: hash,
                contentBytes: SQLiteDatabase.int(statement, column: 13),
                thumbnailBytes: SQLiteDatabase.int(statement, column: 14),
                editCount: SQLiteDatabase.int(statement, column: 15),
                captureCount: SQLiteDatabase.int(statement, column: 16)
            )
        }.first
    }

    private func prune(maxItems: Int, in database: SQLiteDatabase) throws -> [AssetReference] {
        let limit = max(1, maxItems)
        let total = try database.scalarInt("SELECT COUNT(*) FROM items")
        let excess = max(0, total - limit)
        guard excess > 0 else { return [] }

        let rows = try database.query(
            """
            SELECT id, image_file_name, thumbnail_file_name
            FROM items
            WHERE is_favorite = 0
            ORDER BY created_at ASC, id DESC
            LIMIT ?
            """,
            bindings: [.integer(Int64(excess))]
        ) { statement in
            (
                SQLiteDatabase.text(statement, column: 0) ?? "",
                AssetReference(
                    original: SQLiteDatabase.text(statement, column: 1),
                    thumbnail: SQLiteDatabase.text(statement, column: 2)
                )
            )
        }

        for (id, _) in rows where !id.isEmpty {
            try database.execute("DELETE FROM items WHERE id = ?", bindings: [.text(id)])
        }
        return rows.map(\.1)
    }

    private func assetReference(id: UUID, in database: SQLiteDatabase) throws -> AssetReference? {
        try database.query(
            "SELECT image_file_name, thumbnail_file_name FROM items WHERE id = ? LIMIT 1",
            bindings: [.text(id.uuidString)]
        ) { statement in
            AssetReference(
                original: SQLiteDatabase.text(statement, column: 0),
                thumbnail: SQLiteDatabase.text(statement, column: 1)
            )
        }.first
    }

    private func assetReferences(
        whereClause: String,
        bindings: [SQLiteValue],
        in database: SQLiteDatabase
    ) throws -> [AssetReference] {
        try database.query(
            "SELECT image_file_name, thumbnail_file_name FROM items WHERE \(whereClause)",
            bindings: bindings
        ) { statement in
            AssetReference(
                original: SQLiteDatabase.text(statement, column: 0),
                thumbnail: SQLiteDatabase.text(statement, column: 1)
            )
        }
    }

    private func storeAsset(
        _ data: Data,
        directory: String,
        preferredExtension: String
    ) throws -> StoredAsset {
        let hash = ContentHasher.data(data)
        let safeExtension = sanitizedExtension(preferredExtension)
        let relativePath = "\(directory)/\(hash.prefix(2))/\(hash).\(safeExtension)"
        let destination = assetURL(fileName: relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let wasCreated: Bool
        if fileManager.fileExists(atPath: destination.path) {
            wasCreated = false
        } else {
            try data.write(to: destination, options: .atomic)
            wasCreated = true
        }
        assetAllocations[relativePath] = allocatedSize(of: destination)
        return StoredAsset(relativePath: relativePath, wasCreated: wasCreated)
    }

    private func assetExists(_ relativePath: String?) -> Bool {
        guard let relativePath = validatedAssetPath(relativePath) else { return false }
        return fileManager.fileExists(atPath: assetURL(fileName: relativePath).path)
    }

    private func removeCreatedAssets(_ assets: [StoredAsset], in database: SQLiteDatabase) {
        removeAssetsIfUnreferenced(
            assets.filter(\.wasCreated).map(\.relativePath),
            in: database
        )
    }

    private func removeAssetsIfUnreferenced(_ paths: [String], in database: SQLiteDatabase) {
        for path in Set(paths) {
            let references = (try? database.scalarInt(
                """
                SELECT COUNT(*) FROM items
                WHERE image_file_name = ? OR thumbnail_file_name = ?
                """,
                bindings: [.text(path), .text(path)]
            )) ?? 1
            guard references == 0 else { continue }

            let url = assetURL(fileName: path)
            try? fileManager.removeItem(at: url)
            if fileManager.fileExists(atPath: url.path) {
                assetAllocations[path] = allocatedSize(of: url)
            } else {
                assetAllocations.removeValue(forKey: path)
            }
        }
    }

    private func reconcileAssets() throws {
        let database = try requireDatabase()
        let referenced = Set(
            try assetReferences(whereClause: "1 = 1", bindings: [], in: database)
                .flatMap(\.paths)
        )
        assetAllocations.removeAll(keepingCapacity: true)

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: assetsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let relativePath = relativeAssetPath(for: url)
            if !referenced.contains(relativePath) {
                try? fileManager.removeItem(at: url)
            }
            if fileManager.fileExists(atPath: url.path) {
                assetAllocations[relativePath] = values?.totalFileAllocatedSize
                    ?? values?.fileAllocatedSize
                    ?? values?.fileSize
                    ?? 0
            }
        }
    }

    private func state() -> RepositoryState {
        let databaseBytes = allocatedSize(of: databaseURL)
        let walBytes = allocatedSize(of: URL(fileURLWithPath: databaseURL.path + "-wal"))
        let sharedMemoryBytes = allocatedSize(of: URL(fileURLWithPath: databaseURL.path + "-shm"))
        return RepositoryState(
            items: history.items,
            databaseBytes: databaseBytes,
            walBytes: walBytes,
            sharedMemoryBytes: sharedMemoryBytes,
            assetBytes: assetAllocations.values.reduce(0, +),
            archiveBytes: archivedIndexBytes()
        )
    }

    private func archivedIndexBytes() -> Int {
        let URLs = (try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        )) ?? []
        return URLs
            .filter {
                ($0.lastPathComponent.hasPrefix("history-migrated-") ||
                 $0.lastPathComponent.hasPrefix("history-corrupt-")) &&
                $0.pathExtension == "json"
            }
            .reduce(0) { $0 + allocatedSize(of: $1) }
    }

    private func allocatedSize(of url: URL) -> Int {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }
        if let values = try? url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]) {
            return values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
        }
        return (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private func relativeAssetPath(for url: URL) -> String {
        let prefix = assetsURL.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }

    private func preferredExtension(for UTI: String?, data: Data) -> String {
        if let UTI, let value = UTType(UTI)?.preferredFilenameExtension {
            return value
        }
        return detectedExtension(for: data) ?? "png"
    }

    private func detectedExtension(for data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) ||
            bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if bytes.count >= 12,
           String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" {
            return "heic"
        }
        return nil
    }

    private func sanitizedExtension(_ value: String) -> String {
        let filtered = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return filtered.isEmpty ? "bin" : String(filtered.prefix(10))
    }

    private func likePattern(for term: String) -> String {
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private func validatedAssetPath(_ value: String?) -> String? {
        guard let value, !value.isEmpty, !value.hasPrefix("/") else { return nil }
        let root = assetsURL.standardizedFileURL
        let candidate = root.appendingPathComponent(value).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return value
    }

    private func preserveCorruptLegacyIndex() throws {
        guard fileManager.fileExists(atPath: legacyIndexURL.path) else { return }
        let destination = baseURL.appendingPathComponent("history-corrupt-\(timestamp()).json")
        try fileManager.moveItem(at: legacyIndexURL, to: destination)
    }

    private func preserveMigratedLegacyIndex() {
        guard fileManager.fileExists(atPath: legacyIndexURL.path) else { return }
        let destination = baseURL.appendingPathComponent("history-migrated-\(timestamp()).json")
        try? fileManager.moveItem(at: legacyIndexURL, to: destination)
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func optionalText(_ value: String?) -> SQLiteValue {
        value.map(SQLiteValue.text) ?? .null
    }

    private func optionalDate(_ value: Date?) -> SQLiteValue {
        value.map { .real($0.timeIntervalSince1970) } ?? .null
    }
}

private func sqliteColumnIsNull(_ statement: OpaquePointer, column: Int32) -> Bool {
    SQLiteDatabase.text(statement, column: column) == nil
}
