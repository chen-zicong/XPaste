import Foundation
import XCTest
@testable import XPasteCore

final class HistoryRepositoryTests: XCTestCase {
    func testFileBookmarksPersistAcrossRepositoryReload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("persisted.pdf")
        try Data("pdf".utf8).write(to: fileURL)
        let bookmark = try fileURL.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: [.fileResourceIdentifierKey],
            relativeTo: nil
        )

        var repository: HistoryRepository? = HistoryRepository(baseURL: directory.appendingPathComponent("History"))
        _ = try await repository?.load()
        let state = try await repository?.record(
            CapturePayload(
                kind: .files,
                filePaths: [fileURL.path],
                fileBookmarks: [bookmark],
                contentHash: ContentHasher.files([fileURL.path])
            ),
            maxItems: 10
        )
        let itemID = try XCTUnwrap(state?.items.first?.id)
        repository = nil

        let reloaded = HistoryRepository(baseURL: directory.appendingPathComponent("History"))
        let reloadedState = try await reloaded.load()
        let item = try XCTUnwrap(reloadedState.items.first { $0.id == itemID })
        XCTAssertEqual(item.fileBookmarks, [bookmark])
        XCTAssertTrue(item.hasRestorableFileBookmarks)
        let resolved = try await reloaded.resolveFileURLs(id: itemID)
        XCTAssertEqual(resolved, [fileURL.standardizedFileURL])
    }

    func testLegacyPathOnlyFileRecordUpgradesBookmarkOnFirstResolve() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("legacy.txt")
        try Data("legacy".utf8).write(to: fileURL)
        let repository = HistoryRepository(baseURL: directory.appendingPathComponent("History"))
        _ = try await repository.load()
        let state = try await repository.record(
            CapturePayload(
                kind: .files,
                filePaths: [fileURL.path],
                contentHash: ContentHasher.files([fileURL.path])
            ),
            maxItems: 10
        )
        let itemID = try XCTUnwrap(state.items.first?.id)
        XCTAssertFalse(try XCTUnwrap(state.items.first).hasRestorableFileBookmarks)

        let resolved = try await repository.resolveFileURLs(id: itemID)
        XCTAssertEqual(resolved, [fileURL.standardizedFileURL])
        let upgradedState = try await repository.load()
        let upgraded = try XCTUnwrap(upgradedState.items.first { $0.id == itemID })
        XCTAssertTrue(upgraded.hasRestorableFileBookmarks)
        XCTAssertNotNil(upgraded.fileBookmarks.first ?? nil)
    }

    func testFileResolutionReportsEachFailureAndKeepsValidFilesPasteable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let validURL = directory.appendingPathComponent("available.txt")
        try Data("available".utf8).write(to: validURL)
        let missingURL = directory.appendingPathComponent("deleted.txt")
        let detachedURL = URL(fileURLWithPath: "/Volumes/XPaste-Detached-\(UUID().uuidString)/archive.zip")
        let paths = [validURL.path, missingURL.path, detachedURL.path]
        let bookmark = try validURL.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: [.fileResourceIdentifierKey],
            relativeTo: nil
        )
        let repository = HistoryRepository(baseURL: directory.appendingPathComponent("History"))
        _ = try await repository.load()
        let state = try await repository.record(
            CapturePayload(
                kind: .files,
                filePaths: paths,
                fileBookmarks: [bookmark, nil, nil],
                contentHash: ContentHasher.files(paths)
            ),
            maxItems: 10
        )
        let itemID = try XCTUnwrap(state.items.first?.id)

        let report = try await repository.resolveFileReferences(id: itemID)
        XCTAssertEqual(report.availableURLs, [validURL.standardizedFileURL])
        XCTAssertEqual(report.unavailableCount, 2)
        XCTAssertEqual(report.entries.map(\.availability), [.available, .missing, .volumeUnavailable])
    }

    func testReplacingMissingFileReferenceUpdatesPathBookmarkAndResolution() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let missingURL = directory.appendingPathComponent("old-name.pdf")
        let replacementURL = directory.appendingPathComponent("new-name.pdf")
        try Data("replacement".utf8).write(to: replacementURL)
        let repository = HistoryRepository(baseURL: directory.appendingPathComponent("History"))
        _ = try await repository.load()
        let state = try await repository.record(
            CapturePayload(
                kind: .files,
                filePaths: [missingURL.path],
                contentHash: ContentHasher.files([missingURL.path])
            ),
            maxItems: 10
        )
        let itemID = try XCTUnwrap(state.items.first?.id)

        let updatedState = try await repository.replaceFileReference(
            id: itemID,
            index: 0,
            with: replacementURL
        )
        let updated = try XCTUnwrap(updatedState.items.first { $0.id == itemID })
        XCTAssertEqual(updated.filePaths, [replacementURL.path])
        XCTAssertTrue(updated.hasRestorableFileBookmarks)

        let report = try await repository.resolveFileReferences(id: itemID)
        XCTAssertEqual(report.availableURLs, [replacementURL.standardizedFileURL])
        XCTAssertEqual(report.entries.map(\.availability), [.available])
    }

    func testVersionTwoDatabaseMigratesFileBookmarkColumnWithoutLosingRecords() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let itemID = UUID()
        var legacyDatabase: SQLiteDatabase? = try SQLiteDatabase(
            url: directory.appendingPathComponent("history.sqlite")
        )
        try legacyDatabase?.execute(
            """
            CREATE TABLE items (
                id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, text TEXT,
                image_file_name TEXT, thumbnail_file_name TEXT, image_uti TEXT,
                file_paths TEXT NOT NULL DEFAULT '[]', source_app_bundle_identifier TEXT,
                created_at REAL NOT NULL, last_used_at REAL NOT NULL, edited_at REAL,
                is_favorite INTEGER NOT NULL DEFAULT 0, content_hash TEXT NOT NULL,
                content_bytes INTEGER NOT NULL DEFAULT 0, thumbnail_bytes INTEGER NOT NULL DEFAULT 0,
                edit_count INTEGER NOT NULL DEFAULT 0, capture_count INTEGER NOT NULL DEFAULT 1
            )
            """
        )
        try legacyDatabase?.execute(
            """
            INSERT INTO items (
                id, kind, file_paths, created_at, last_used_at, content_hash, content_bytes
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(itemID.uuidString),
                .text(ClipboardKind.files.rawValue),
                .text("[\"/tmp/legacy.pdf\"]"),
                .real(100),
                .real(100),
                .text(ContentHasher.files(["/tmp/legacy.pdf"])),
                .integer(15)
            ]
        )
        try legacyDatabase?.execute("PRAGMA user_version = 2")
        legacyDatabase = nil

        let repository = HistoryRepository(baseURL: directory)
        let state = try await repository.load()
        let migrated = try XCTUnwrap(state.items.first { $0.id == itemID })
        XCTAssertEqual(migrated.filePaths, ["/tmp/legacy.pdf"])
        XCTAssertEqual(migrated.fileBookmarks, [])

        let migratedDatabase = try SQLiteDatabase(url: directory.appendingPathComponent("history.sqlite"))
        XCTAssertEqual(try migratedDatabase.scalarInt("PRAGMA user_version"), 3)
        XCTAssertEqual(
            try migratedDatabase.scalarInt(
                "SELECT COUNT(*) FROM pragma_table_info('items') WHERE name = 'file_bookmarks'"
            ),
            1
        )
    }

    func testLastUsedTimePersistsWithoutChangingCaptureTime() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capturedAt = Date(timeIntervalSince1970: 100)
        let pastedAt = Date(timeIntervalSince1970: 300)

        var repository: HistoryRepository? = HistoryRepository(baseURL: directory)
        _ = try await repository?.load()
        var state = try await repository?.record(
            CapturePayload(
                kind: .text,
                text: "old searchable",
                contentHash: ContentHasher.text("old searchable"),
                capturedAt: capturedAt
            ),
            maxItems: 10
        )
        let itemID = try XCTUnwrap(state?.items.first?.id)
        _ = try await repository?.record(
            CapturePayload(
                kind: .text,
                text: "new searchable",
                contentHash: ContentHasher.text("new searchable"),
                capturedAt: Date(timeIntervalSince1970: 200)
            ),
            maxItems: 10
        )
        state = try await repository?.markUsed(id: itemID, at: pastedAt)
        let used = try XCTUnwrap(state?.items.first { $0.id == itemID })
        XCTAssertEqual(used.createdAt, capturedAt)
        XCTAssertEqual(used.lastUsedAt, pastedAt)

        repository = nil
        let reloaded = HistoryRepository(baseURL: directory)
        state = try await reloaded.load()
        let reloadedUsed = try XCTUnwrap(state?.items.first { $0.id == itemID })
        XCTAssertEqual(reloadedUsed.createdAt, capturedAt)
        XCTAssertEqual(reloadedUsed.lastUsedAt, pastedAt)
        let recentlyUsed = ClipboardItemSorter.sorted(try XCTUnwrap(state?.items), by: .recentUse)
        XCTAssertEqual(recentlyUsed.first?.id, itemID)
        let searchResults = try await reloaded.search(
            query: "searchable",
            favoritesOnly: false,
            filter: .all,
            sortOrder: .recentUse,
            limit: 1
        )
        XCTAssertEqual(searchResults.first?.id, itemID)
    }

    func testDuplicateIsPromotedAndFavoriteSurvivesLimit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(baseURL: directory)

        _ = try await repository.load()
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        let promotedDate = Date(timeIntervalSince1970: 300)
        let firstHash = ContentHasher.text("first")

        var state = try await repository.record(
            CapturePayload(kind: .text, text: "first", contentHash: firstHash, capturedAt: firstDate),
            maxItems: 10
        )
        let firstID = try XCTUnwrap(state.items.first?.id)
        state = try await repository.setFavorite(id: firstID, value: true)
        XCTAssertTrue(try XCTUnwrap(state.items.first { $0.id == firstID }).isFavorite)

        _ = try await repository.record(
            CapturePayload(
                kind: .text,
                text: "second",
                contentHash: ContentHasher.text("second"),
                capturedAt: secondDate
            ),
            maxItems: 10
        )
        state = try await repository.record(
            CapturePayload(kind: .text, text: "first", contentHash: firstHash, capturedAt: promotedDate),
            maxItems: 10
        )

        XCTAssertEqual(state.items.count, 2)
        XCTAssertEqual(state.items.first?.id, firstID)
        XCTAssertEqual(state.items.first?.captureCount, 2)
        XCTAssertEqual(state.items.first?.createdAt, promotedDate)
        XCTAssertTrue(state.items.first?.isFavorite == true)

        state = try await repository.enforceLimit(1)
        XCTAssertEqual(state.items.map(\.id), [firstID])

        state = try await repository.record(
            CapturePayload(
                kind: .text,
                text: "temporary",
                contentHash: ContentHasher.text("temporary"),
                capturedAt: Date(timeIntervalSince1970: 400)
            ),
            maxItems: 1
        )
        XCTAssertEqual(state.items.map(\.id), [firstID], "收藏达到上限时，新非收藏项应被淘汰")
    }

    func testImageAssetsAreContentAddressedAndRemovedWithItem() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(baseURL: directory)
        _ = try await repository.load()

        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 7, count: 8_192))
        let thumbnail = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 3, count: 1_024))
        var state = try await repository.record(
            CapturePayload(
                kind: .image,
                imageData: image,
                thumbnailData: thumbnail,
                imageUTI: "public.png",
                contentHash: ContentHasher.data(image)
            ),
            maxItems: 100
        )

        let item = try XCTUnwrap(state.items.first)
        let originalName = try XCTUnwrap(item.imageFileName)
        let thumbnailName = try XCTUnwrap(item.thumbnailFileName)
        XCTAssertTrue(originalName.hasPrefix("Originals/"))
        XCTAssertTrue(thumbnailName.hasPrefix("Thumbnails/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.assetURL(fileName: originalName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.assetURL(fileName: thumbnailName).path))
        XCTAssertGreaterThan(state.databaseBytes, 0)
        XCTAssertGreaterThan(state.assetBytes, 0)
        XCTAssertEqual(
            state.storageStats.totalBytes,
            state.databaseBytes + state.walBytes + state.sharedMemoryBytes + state.assetBytes
        )

        let originalURL = repository.assetURL(fileName: originalName)
        let thumbnailURL = repository.assetURL(fileName: thumbnailName)
        state = try await repository.delete(id: item.id)
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
        XCTAssertEqual(state.assetBytes, 0)
    }

    func testImageUpdateAtomicallySwitchesAssetsAndRemovesOldFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(baseURL: directory)
        _ = try await repository.load()

        let original = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 1, count: 1_000))
        let originalThumb = Data([0xFF, 0xD8, 0xFF] + Array(repeating: 2, count: 100))
        var state = try await repository.record(
            CapturePayload(
                kind: .image,
                imageData: original,
                thumbnailData: originalThumb,
                imageUTI: "public.png",
                contentHash: ContentHasher.data(original)
            ),
            maxItems: 10
        )
        let old = try XCTUnwrap(state.items.first)
        let oldOriginalURL = repository.assetURL(fileName: try XCTUnwrap(old.imageFileName))
        let oldThumbnailURL = repository.assetURL(fileName: try XCTUnwrap(old.thumbnailFileName))

        let updated = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 9, count: 2_000))
        let updatedThumb = Data([0xFF, 0xD8, 0xFF] + Array(repeating: 8, count: 200))
        state = try await repository.updateImage(
            id: old.id,
            imageData: updated,
            thumbnailData: updatedThumb,
            contentHash: ContentHasher.data(updated)
        )

        let item = try XCTUnwrap(state.items.first)
        XCTAssertEqual(item.editCount, 1)
        XCTAssertEqual(item.contentBytes, updated.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldOriginalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldThumbnailURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repository.assetURL(fileName: try XCTUnwrap(item.imageFileName)).path
        ))
    }

    func testUpdateTextMergesExistingContentAndPreservesCountsAndFavorite() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(baseURL: directory)
        _ = try await repository.load()

        var state = try await repository.record(
            CapturePayload(kind: .text, text: "destination", contentHash: ContentHasher.text("destination")),
            maxItems: 10
        )
        let destinationID = try XCTUnwrap(state.items.first?.id)
        _ = try await repository.record(
            CapturePayload(kind: .text, text: "destination", contentHash: ContentHasher.text("destination")),
            maxItems: 10
        )
        _ = try await repository.setFavorite(id: destinationID, value: true)

        state = try await repository.record(
            CapturePayload(kind: .text, text: "source", contentHash: ContentHasher.text("source")),
            maxItems: 10
        )
        let sourceID = try XCTUnwrap(state.items.first { $0.text == "source" }?.id)
        _ = try await repository.record(
            CapturePayload(kind: .text, text: "source", contentHash: ContentHasher.text("source")),
            maxItems: 10
        )

        state = try await repository.updateText(id: sourceID, text: "destination")
        XCTAssertEqual(state.items.count, 1)
        XCTAssertEqual(state.items.first?.id, sourceID)
        XCTAssertEqual(state.items.first?.text, "destination")
        XCTAssertEqual(state.items.first?.captureCount, 4)
        XCTAssertEqual(state.items.first?.editCount, 1)
        XCTAssertTrue(state.items.first?.isFavorite == true)
        let searchResults = try await repository.search(
            query: "destination",
            favoritesOnly: true,
            filter: .text
        )
        XCTAssertEqual(searchResults.map(\.id), [sourceID])
    }

    func testUpdateImageMergesExistingContentWithoutDeletingSharedAssets() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(baseURL: directory)
        _ = try await repository.load()

        let destinationImage = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 4, count: 1_200))
        let destinationThumbnail = Data([0xFF, 0xD8, 0xFF] + Array(repeating: 5, count: 160))
        var state = try await repository.record(
            CapturePayload(
                kind: .image,
                imageData: destinationImage,
                thumbnailData: destinationThumbnail,
                imageUTI: "public.png",
                contentHash: ContentHasher.data(destinationImage)
            ),
            maxItems: 10
        )
        let destination = try XCTUnwrap(state.items.first)
        _ = try await repository.record(
            CapturePayload(
                kind: .image,
                imageData: destinationImage,
                thumbnailData: destinationThumbnail,
                imageUTI: "public.png",
                contentHash: ContentHasher.data(destinationImage)
            ),
            maxItems: 10
        )
        _ = try await repository.setFavorite(id: destination.id, value: true)
        let sharedOriginalURL = repository.assetURL(fileName: try XCTUnwrap(destination.imageFileName))
        let sharedThumbnailURL = repository.assetURL(fileName: try XCTUnwrap(destination.thumbnailFileName))

        let sourceImage = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 7, count: 900))
        let sourceThumbnail = Data([0xFF, 0xD8, 0xFF] + Array(repeating: 8, count: 120))
        state = try await repository.record(
            CapturePayload(
                kind: .image,
                imageData: sourceImage,
                thumbnailData: sourceThumbnail,
                imageUTI: "public.png",
                contentHash: ContentHasher.data(sourceImage)
            ),
            maxItems: 10
        )
        let source = try XCTUnwrap(state.items.first { $0.contentHash == ContentHasher.data(sourceImage) })
        let retiredOriginalURL = repository.assetURL(fileName: try XCTUnwrap(source.imageFileName))
        let retiredThumbnailURL = repository.assetURL(fileName: try XCTUnwrap(source.thumbnailFileName))

        state = try await repository.updateImage(
            id: source.id,
            imageData: destinationImage,
            thumbnailData: destinationThumbnail,
            contentHash: ContentHasher.data(destinationImage)
        )
        XCTAssertEqual(state.items.count, 1)
        XCTAssertEqual(state.items.first?.id, source.id)
        XCTAssertEqual(state.items.first?.captureCount, 3)
        XCTAssertEqual(state.items.first?.editCount, 1)
        XCTAssertTrue(state.items.first?.isFavorite == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedOriginalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedThumbnailURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retiredOriginalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retiredThumbnailURL.path))
    }

    func testDuplicateImageCaptureRepairsMissingOriginalAndThumbnail() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(baseURL: directory)
        _ = try await repository.load()

        let image = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 2, count: 1_500))
        let thumbnail = Data([0xFF, 0xD8, 0xFF] + Array(repeating: 3, count: 180))
        let payload = CapturePayload(
            kind: .image,
            imageData: image,
            thumbnailData: thumbnail,
            imageUTI: "public.png",
            contentHash: ContentHasher.data(image)
        )
        var state = try await repository.record(payload, maxItems: 10)
        let item = try XCTUnwrap(state.items.first)
        let originalURL = repository.assetURL(fileName: try XCTUnwrap(item.imageFileName))
        let thumbnailURL = repository.assetURL(fileName: try XCTUnwrap(item.thumbnailFileName))
        try FileManager.default.removeItem(at: originalURL)
        try FileManager.default.removeItem(at: thumbnailURL)

        state = try await repository.record(payload, maxItems: 10)
        XCTAssertEqual(state.items.count, 1)
        XCTAssertEqual(state.items.first?.id, item.id)
        XCTAssertEqual(state.items.first?.captureCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
    }

    func testLegacyJSONIsMigratedOnce() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let legacyItem = ClipboardItem(
            kind: .text,
            text: "legacy",
            createdAt: Date(timeIntervalSince1970: 1_000),
            contentHash: ContentHasher.text("legacy"),
            contentBytes: 6
        )
        let archive = LegacyArchive(schemaVersion: 1, items: [legacyItem])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(archive).write(to: directory.appendingPathComponent("history.json"), options: .atomic)

        let repository = HistoryRepository(baseURL: directory)
        let state = try await repository.load()
        XCTAssertEqual(state.items.map(\.text), ["legacy"])
        XCTAssertEqual(state.items.first?.captureCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("history-migrated-") && $0.hasSuffix(".json") })
    }

    func testMigratedAssetPathCannotEscapeAssetsDirectory() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = root.appendingPathComponent("sentinel.txt")
        try Data("keep".utf8).write(to: sentinel)

        let malicious = ClipboardItem(
            kind: .image,
            imageFileName: "../../sentinel.txt",
            thumbnailFileName: "../../../sentinel.txt",
            contentHash: "malicious",
            contentBytes: 4
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(LegacyArchive(schemaVersion: 1, items: [malicious]))
            .write(to: directory.appendingPathComponent("history.json"), options: .atomic)

        let repository = HistoryRepository(baseURL: directory)
        var state = try await repository.load()
        XCTAssertNil(state.items.first?.imageFileName)
        XCTAssertNil(state.items.first?.thumbnailFileName)
        state = try await repository.delete(id: try XCTUnwrap(state.items.first?.id))
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
    }

    func testSQLiteSearchFindsChineseSubstringAndUpdatedText() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(baseURL: directory)
        _ = try await repository.load()
        var state = try await repository.record(
            CapturePayload(
                kind: .text,
                text: "高性能剪贴板工具 SwiftUI",
                contentHash: ContentHasher.text("高性能剪贴板工具 SwiftUI")
            ),
            maxItems: 100
        )
        let id = try XCTUnwrap(state.items.first?.id)

        let ChineseResults = try await repository.search(query: "剪贴", favoritesOnly: false, filter: .text)
        let SwiftResults = try await repository.search(query: "SwiftUI", favoritesOnly: false, filter: .all)
        XCTAssertEqual(ChineseResults.map(\.id), [id])
        XCTAssertEqual(SwiftResults.map(\.id), [id])

        state = try await repository.updateText(id: id, text: "已经修改为 SQLite 搜索")
        XCTAssertEqual(state.items.first?.text, "已经修改为 SQLite 搜索")
        let oldResults = try await repository.search(query: "SwiftUI", favoritesOnly: false, filter: .all)
        let updatedResults = try await repository.search(query: "SQLite", favoritesOnly: false, filter: .all)
        XCTAssertTrue(oldResults.isEmpty)
        XCTAssertEqual(updatedResults.map(\.id), [id])
    }

    func testFTSSearchAcrossFiveThousandLongItemsIsFast() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let padding = String(repeating: "clipboard performance sample ", count: 40)
        let items = (0..<5_000).map { index in
            let text = "\(padding) unique\(index)"
            return ClipboardItem(
                kind: .text,
                text: text,
                contentHash: ContentHasher.text(text),
                contentBytes: text.utf8.count
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(LegacyArchive(schemaVersion: 1, items: items))
            .write(to: directory.appendingPathComponent("history.json"), options: .atomic)

        let repository = HistoryRepository(baseURL: directory)
        _ = try await repository.load()
        let start = ContinuousClock.now
        let results = try await repository.search(query: "unique4999", favoritesOnly: false, filter: .text)
        let elapsed = start.duration(to: .now)
        XCTAssertEqual(results.first?.text?.hasSuffix("unique4999"), true)
        XCTAssertLessThan(elapsed, .milliseconds(50))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("XPasteCoreTests-\(UUID().uuidString)", isDirectory: true)
    }
}

private struct LegacyArchive: Encodable {
    var schemaVersion: Int
    var items: [ClipboardItem]
}
