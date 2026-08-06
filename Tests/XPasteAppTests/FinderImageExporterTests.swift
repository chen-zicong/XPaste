import Foundation
import XCTest
@testable import XPaste

final class FinderImageExporterTests: XCTestCase {
    func testOnlyFinderUsesAFileRepresentationForImages() {
        XCTAssertTrue(
            ImagePastePolicy.shouldPublishAsFile(
                targetBundleIdentifier: "com.apple.finder"
            )
        )
        XCTAssertFalse(
            ImagePastePolicy.shouldPublishAsFile(
                targetBundleIdentifier: "com.tencent.xinWeChat"
            )
        )
        XCTAssertFalse(
            ImagePastePolicy.shouldPublishAsFile(targetBundleIdentifier: nil)
        )
    }

    func testExportCreatesReadableUniquePNGFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("XPaste-FinderExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try bytes.write(to: source)

        let exporter = FinderImageExporter(baseURL: root)
        let capturedAt = Date(timeIntervalSince1970: 1_735_689_600)
        let first = try await exporter.export(sourceURL: source, capturedAt: capturedAt)
        let second = try await exporter.export(sourceURL: source, capturedAt: capturedAt)

        XCTAssertEqual(first.pathExtension, "png")
        XCTAssertTrue(first.lastPathComponent.hasPrefix("XPaste 图片 "))
        XCTAssertEqual(second.deletingPathExtension().lastPathComponent, "\(first.deletingPathExtension().lastPathComponent) 2")
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(try Data(contentsOf: second), bytes)
    }
}
