import AppKit
import CoreImage

/// Only scalar pixels cross back to the UI; Core Image work and its reusable
/// context are isolated on this worker, including concurrent header requests.
actor ArtworkColorRepository {
    static let shared = ArtworkColorRepository()

    struct Request: Hashable, Sendable {
        let coreID: ObjectIdentifier
        let artworkID: String
        let pixelSize: Int
    }

    struct Sample: Equatable, Sendable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        @MainActor var color: NSColor {
            NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                    blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    private struct CachedSample { let sample: Sample? }
    private let cache: CostLimitedLRU<Request, CachedSample>
    private let calculator: (@Sendable (CGImage) -> Sample?)?
    private lazy var context = CIContext(options: [.workingColorSpace: NSNull()])

    init(cacheCountLimit: Int = 256, calculator: (@Sendable (CGImage) -> Sample?)? = nil) {
        cache = CostLimitedLRU(byteLimit: 256 * 4, countLimit: cacheCountLimit)
        self.calculator = calculator
    }

    func lowerRegionColor(for request: Request, image: CGImage) throws -> Sample? {
        try Task.checkCancellation()
        if let cached = cache.value(for: request) { return cached.sample }
        let sample: Sample? = autoreleasepool {
            if let calculator { return calculator(image) }
            return calculate(image)
        }
        try Task.checkCancellation()
        cache.insert(CachedSample(sample: sample), for: request, cost: 4)
        return sample
    }

    private func calculate(_ image: CGImage) -> Sample? {
        let input = CIImage(cgImage: image)
        let extent = CGRect(x: input.extent.minX, y: input.extent.minY,
                            width: input.extent.width, height: input.extent.height * 0.35)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: extent)
        ]), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return Sample(red: pixel[0], green: pixel[1], blue: pixel[2])
    }
}
