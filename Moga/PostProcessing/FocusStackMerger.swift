import Foundation
import CoreImage
import Accelerate

// Merges a stack of images captured at different focus distances into one sharp image.
// Algorithm: per-pixel Laplacian variance map → weighted blend (sharpest region wins).

final class FocusStackMerger {

    func merge(_ images: [CGImage]) async -> CGImage? {
        guard images.count > 1 else { return images.first }

        return await Task.detached(priority: .userInitiated) {
            let width  = images[0].width
            let height = images[0].height

            // Convert each image to a float RGBA pixel buffer
            guard let buffers = Self.toFloatBuffers(images, width: width, height: height) else {
                return images.first
            }

            // Compute per-pixel sharpness maps (Laplacian magnitude)
            let sharpnessMaps = buffers.map { Self.laplacianMap($0, width: width, height: height) }

            // Blend: for each pixel, take the value from the image with highest sharpness
            let blended = Self.weightedBlend(buffers: buffers, maps: sharpnessMaps,
                                             width: width, height: height)

            return Self.toCGImage(blended, width: width, height: height)
        }.value
    }

    // MARK: - Private

    private nonisolated static func toFloatBuffers(_ images: [CGImage], width: Int, height: Int) -> [[Float]]? {
        let pixelCount = width * height * 4
        var result: [[Float]] = []

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        for image in images {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            result.append(pixels.map { Float($0) / 255.0 })
        }

        _ = pixelCount
        return result
    }

    private nonisolated static func laplacianMap(_ buffer: [Float], width: Int, height: Int) -> [Float] {
        // Extract luminance channel (Y = 0.299R + 0.587G + 0.114B)
        var luma = [Float](repeating: 0, count: width * height)
        for i in 0..<width * height {
            let r = buffer[i * 4]
            let g = buffer[i * 4 + 1]
            let b = buffer[i * 4 + 2]
            luma[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }

        // Apply discrete Laplacian kernel [0,-1,0,-1,4,-1,0,-1,0]
        var sharpness = [Float](repeating: 0, count: width * height)
        for y in 1..<height - 1 {
            for x in 1..<width - 1 {
                let idx = y * width + x
                let lap = 4 * luma[idx]
                    - luma[idx - 1]
                    - luma[idx + 1]
                    - luma[idx - width]
                    - luma[idx + width]
                sharpness[idx] = abs(lap)
            }
        }
        return sharpness
    }

    private nonisolated static func weightedBlend(buffers: [[Float]], maps: [[Float]],
                                      width: Int, height: Int) -> [Float] {
        let pixelCount = width * height
        var result = [Float](repeating: 0, count: pixelCount * 4)

        for i in 0..<pixelCount {
            // Find which image is sharpest at this pixel
            var bestSharpness: Float = -1
            var bestImage = 0
            for j in 0..<maps.count {
                if maps[j][i] > bestSharpness {
                    bestSharpness = maps[j][i]
                    bestImage = j
                }
            }
            result[i * 4]     = buffers[bestImage][i * 4]
            result[i * 4 + 1] = buffers[bestImage][i * 4 + 1]
            result[i * 4 + 2] = buffers[bestImage][i * 4 + 2]
            result[i * 4 + 3] = buffers[bestImage][i * 4 + 3]
        }
        return result
    }

    private nonisolated static func toCGImage(_ buffer: [Float], width: Int, height: Int) -> CGImage? {
        let pixels = buffer.map { UInt8(min(max($0 * 255, 0), 255)) }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace,
                       bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
