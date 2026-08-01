import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XPasteCore

struct ProcessedImage: @unchecked Sendable {
    var pngData: Data
    var thumbnailData: Data
    var pixelWidth: Int
    var pixelHeight: Int
}

enum ImageProcessingError: LocalizedError {
    case unreadable
    case tooManyPixels
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取这张图片"
        case .tooManyPixels: "图片像素尺寸过大，已跳过以保护内存"
        case .encodingFailed: "图片编码失败"
        }
    }
}

enum ImageEditOperation: String, CaseIterable, Identifiable {
    case rotateLeft
    case rotateRight
    case flipHorizontal
    case cropSquare

    var id: String { rawValue }
}

enum ImageProcessor {
    static func process(_ sourceData: Data) async throws -> ProcessedImage {
        try await Task.detached(priority: .utility) {
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithData(sourceData as CFData, [
                    kCGImageSourceShouldCache: false
                ] as CFDictionary) else {
                    throw ImageProcessingError.unreadable
                }

                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
                let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
                guard width > 0, height > 0 else { throw ImageProcessingError.unreadable }
                let pixelCount = width.multipliedReportingOverflow(by: height)
                guard !pixelCount.overflow, pixelCount.partialValue <= 80_000_000 else {
                    throw ImageProcessingError.tooManyPixels
                }

                let pngData: Data
                if CGImageSourceGetType(source) as String? == UTType.png.identifier {
                    // Preserve PNG bytes to avoid decoding a full-size screenshot
                    // merely to encode it back to the same format.
                    pngData = sourceData
                } else {
                    guard let image = CGImageSourceCreateImageAtIndex(source, 0, [
                        kCGImageSourceShouldCache: false,
                        kCGImageSourceShouldCacheImmediately: false
                    ] as CFDictionary) else {
                        throw ImageProcessingError.unreadable
                    }
                    pngData = try encode(image: image, type: .png, quality: 1)
                }

                let thumbnailOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 420
                ]
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                    throw ImageProcessingError.unreadable
                }
                let thumbnailData = try encode(image: thumbnail, type: .jpeg, quality: 0.78)
                return ProcessedImage(
                    pngData: pngData,
                    thumbnailData: thumbnailData,
                    pixelWidth: width,
                    pixelHeight: height
                )
            }
        }.value
    }

    static func edit(_ sourceData: Data, operations: [ImageEditOperation]) async throws -> ProcessedImage {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ImageProcessingError.unreadable
                }
                var image = CIImage(cgImage: cgImage)
                for operation in operations {
                    image = apply(operation, to: image)
                }
                let extent = image.extent.integral
                image = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
                let context = CIContext(options: [.cacheIntermediates: false])
                guard let output = context.createCGImage(image, from: image.extent) else {
                    throw ImageProcessingError.encodingFailed
                }
                let png = try encode(image: output, type: .png, quality: 1)
                return try awaitResult(png)
            }
        }.value
    }

    private static func awaitResult(_ png: Data) throws -> ProcessedImage {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 420,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else {
            throw ImageProcessingError.encodingFailed
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return ProcessedImage(
            pngData: png,
            thumbnailData: try encode(image: thumbnail, type: .jpeg, quality: 0.78),
            pixelWidth: width,
            pixelHeight: height
        )
    }

    private static func apply(_ operation: ImageEditOperation, to image: CIImage) -> CIImage {
        let extent = image.extent
        switch operation {
        case .rotateLeft:
            return image.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
        case .rotateRight:
            return image.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
        case .flipHorizontal:
            return image.transformed(by: CGAffineTransform(translationX: extent.width, y: 0).scaledBy(x: -1, y: 1))
        case .cropSquare:
            let side = min(extent.width, extent.height)
            let rect = CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side)
            return image.cropped(to: rect)
        }
    }

    private static func encode(image: CGImage, type: UTType, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImageProcessingError.encodingFailed
        }
        let options = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw ImageProcessingError.encodingFailed }
        return data as Data
    }
}
