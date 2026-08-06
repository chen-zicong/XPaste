import Foundation

enum ImagePastePolicy {
    static let finderBundleIdentifier = "com.apple.finder"

    static func shouldPublishAsFile(targetBundleIdentifier: String?) -> Bool {
        targetBundleIdentifier == finderBundleIdentifier
    }
}

actor FinderImageExporter {
    private let exportDirectory: URL
    private let fileManager: FileManager
    private let retentionInterval: TimeInterval

    init(
        baseURL: URL,
        fileManager: FileManager = .default,
        retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.exportDirectory = baseURL.appendingPathComponent("Finder Image Exports", isDirectory: true)
        self.fileManager = fileManager
        self.retentionInterval = retentionInterval
    }

    func export(sourceURL: URL, capturedAt: Date, now: Date = Date()) throws -> URL {
        try fileManager.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        removeExpiredExports(now: now)

        let destination = availableDestination(capturedAt: capturedAt)
        do {
            // A hard link avoids duplicating image bytes while still giving Finder
            // a stable, human-readable file name to copy into the destination folder.
            try fileManager.linkItem(at: sourceURL, to: destination)
        } catch {
            try fileManager.copyItem(at: sourceURL, to: destination)
        }
        return destination
    }

    private func availableDestination(capturedAt: Date) -> URL {
        let baseName = "XPaste 图片 \(Self.timestamp(capturedAt))"
        let pathExtension = "png"
        var candidate = exportDirectory
            .appendingPathComponent(baseName, isDirectory: false)
            .appendingPathExtension(pathExtension)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = exportDirectory
                .appendingPathComponent("\(baseName) \(suffix)", isDirectory: false)
                .appendingPathExtension(pathExtension)
            suffix += 1
        }
        return candidate
    }

    private func removeExpiredExports(now: Date) {
        guard let URLs = try? fileManager.contentsOfDirectory(
            at: exportDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now.addingTimeInterval(-retentionInterval)
        for URL in URLs {
            guard let modifiedAt = try? URL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate,
                  modifiedAt < cutoff else { continue }
            try? fileManager.removeItem(at: URL)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }
}
