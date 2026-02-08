import UIKit

enum ImageUploadEncoder {
    enum EncodingError: Error, LocalizedError {
        case cannotEncode
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .cannotEncode: return "No pude codificar la imagen"
            case .tooLarge: return "La imagen es demasiado grande"
            }
        }
    }

    /// Encodes an image as JPEG, resizing/compressing to fit within maxBytes.
    static func encodeJPEG(
        _ image: UIImage,
        maxBytes: Int = 4_800_000,
        maxDimension: CGFloat = 2048
    ) throws -> Data {
        // Normalize orientation + size first.
        var current = normalize(image, maxDimension: maxDimension)

        let qualities: [CGFloat] = [0.85, 0.75, 0.65, 0.55, 0.45, 0.35]

        for _ in 0..<6 {
            for q in qualities {
                if let data = current.jpegData(compressionQuality: q) {
                    if data.count <= maxBytes { return data }
                }
            }

            // Still too big -> downscale and try again.
            let newSize = CGSize(width: current.size.width * 0.8, height: current.size.height * 0.8)
            guard newSize.width >= 320, newSize.height >= 320 else { break }
            current = resize(current, to: newSize)
        }

        // Last attempt at very low quality.
        if let data = current.jpegData(compressionQuality: 0.25), data.count <= maxBytes {
            return data
        }

        throw EncodingError.tooLarge
    }

    private static func normalize(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let fixed = fixOrientation(image)

        let w = fixed.size.width
        let h = fixed.size.height
        let maxSide = max(w, h)
        guard maxSide > maxDimension else { return fixed }

        let scale = maxDimension / maxSide
        return resize(fixed, to: CGSize(width: w * scale, height: h * scale))
    }

    private static func fixOrientation(_ image: UIImage) -> UIImage {
        // Render into a new context; this also strips most metadata.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
