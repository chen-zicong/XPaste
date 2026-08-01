import CryptoKit
import Foundation

public enum ClipboardKind: String, Codable, CaseIterable, Sendable {
    case text
    case image
    case files

    public var displayName: String {
        switch self {
        case .text: "文本"
        case .image: "图片"
        case .files: "文件"
        }
    }
}

public struct ClipboardItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: ClipboardKind
    public var text: String?
    public var imageFileName: String?
    public var thumbnailFileName: String?
    public var imageUTI: String?
    public var filePaths: [String]
    public var sourceAppBundleIdentifier: String?
    public var createdAt: Date
    public var lastUsedAt: Date
    public var editedAt: Date?
    public var isFavorite: Bool
    public var contentHash: String
    public var contentBytes: Int
    public var thumbnailBytes: Int
    public var editCount: Int
    public var captureCount: Int

    public init(
        id: UUID = UUID(),
        kind: ClipboardKind,
        text: String? = nil,
        imageFileName: String? = nil,
        thumbnailFileName: String? = nil,
        imageUTI: String? = nil,
        filePaths: [String] = [],
        sourceAppBundleIdentifier: String? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        editedAt: Date? = nil,
        isFavorite: Bool = false,
        contentHash: String,
        contentBytes: Int,
        thumbnailBytes: Int = 0,
        editCount: Int = 0,
        captureCount: Int = 1
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFileName = imageFileName
        self.thumbnailFileName = thumbnailFileName
        self.imageUTI = imageUTI
        self.filePaths = filePaths
        self.sourceAppBundleIdentifier = sourceAppBundleIdentifier
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
        self.editedAt = editedAt
        self.isFavorite = isFavorite
        self.contentHash = contentHash
        self.contentBytes = contentBytes
        self.thumbnailBytes = thumbnailBytes
        self.editCount = editCount
        self.captureCount = max(1, captureCount)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case text
        case imageFileName
        case thumbnailFileName
        case imageUTI
        case filePaths
        case sourceAppBundleIdentifier
        case createdAt
        case lastUsedAt
        case editedAt
        case isFavorite
        case contentHash
        case contentBytes
        case thumbnailBytes
        case editCount
        case captureCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ClipboardKind.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        thumbnailFileName = try container.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        imageUTI = try container.decodeIfPresent(String.self, forKey: .imageUTI)
        filePaths = try container.decodeIfPresent([String].self, forKey: .filePaths) ?? []
        sourceAppBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .sourceAppBundleIdentifier)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt) ?? createdAt
        editedAt = try container.decodeIfPresent(Date.self, forKey: .editedAt)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        contentHash = try container.decode(String.self, forKey: .contentHash)
        contentBytes = try container.decodeIfPresent(Int.self, forKey: .contentBytes) ?? 0
        thumbnailBytes = try container.decodeIfPresent(Int.self, forKey: .thumbnailBytes) ?? 0
        editCount = try container.decodeIfPresent(Int.self, forKey: .editCount) ?? 0
        captureCount = max(1, try container.decodeIfPresent(Int.self, forKey: .captureCount) ?? 1)
    }

    public var storageBytes: Int { contentBytes + thumbnailBytes }

    public var title: String {
        switch kind {
        case .text:
            let first = text?.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? "空文本"
            return first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "空文本" : first
        case .image:
            return "图片"
        case .files:
            if filePaths.count == 1 {
                return URL(fileURLWithPath: filePaths[0]).lastPathComponent
            }
            return "\(filePaths.count) 个文件"
        }
    }

    public var previewText: String {
        switch kind {
        case .text:
            return text?.replacingOccurrences(of: "\n", with: " ") ?? ""
        case .image:
            return ByteCountFormatter.string(fromByteCount: Int64(contentBytes), countStyle: .file)
        case .files:
            return filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: " · ")
        }
    }

    public var searchableText: String {
        [title, previewText, text ?? "", filePaths.joined(separator: " "), sourceAppBundleIdentifier ?? ""]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public enum ContentHasher {
    public static func text(_ text: String) -> String {
        digest(Data(text.utf8))
    }

    public static func data(_ data: Data) -> String {
        digest(data)
    }

    public static func files(_ paths: [String]) -> String {
        digest(Data(paths.joined(separator: "\u{0}").utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct CapturePayload: Sendable {
    public var kind: ClipboardKind
    public var text: String?
    public var imageData: Data?
    public var thumbnailData: Data?
    public var filePaths: [String]
    public var imageUTI: String?
    public var contentHash: String
    public var sourceAppBundleIdentifier: String?
    public var capturedAt: Date

    public init(
        kind: ClipboardKind,
        text: String? = nil,
        imageData: Data? = nil,
        thumbnailData: Data? = nil,
        filePaths: [String] = [],
        imageUTI: String? = nil,
        contentHash: String,
        sourceAppBundleIdentifier: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.kind = kind
        self.text = text
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.filePaths = filePaths
        self.imageUTI = imageUTI
        self.contentHash = contentHash
        self.sourceAppBundleIdentifier = sourceAppBundleIdentifier
        self.capturedAt = capturedAt
    }
}
