import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct AssistantPreparedImagePayload: Codable, Sendable {
    public let data: Data
    public let mimeType: String
    public let width: Int
    public let height: Int
}

public enum AssistantImagePreparationError: LocalizedError {
    case invalidImage
    case imageTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            "Не удалось подготовить изображение."
        case .imageTooLarge:
            "Изображение слишком большое для отправки."
        }
    }
}

public enum AssistantImagePreparer {
    private static let maximumPixelSize = 1_800
    private static let maximumBytes = 4 * 1_024 * 1_024

    public static func prepare(data: Data) async throws -> AssistantPreparedImagePayload {
        let task = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try prepareSynchronously(data: data) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private static func prepareSynchronously(data: Data) throws -> AssistantPreparedImagePayload {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else {
            throw AssistantImagePreparationError.invalidImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw AssistantImagePreparationError.invalidImage
        }

        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AssistantImagePreparationError.invalidImage
        }

        let preparedData = output as Data
        guard preparedData.count <= maximumBytes else {
            throw AssistantImagePreparationError.imageTooLarge
        }
        return AssistantPreparedImagePayload(
            data: preparedData,
            mimeType: UTType.jpeg.preferredMIMEType ?? "image/jpeg",
            width: image.width,
            height: image.height
        )
    }
}
