import AppKit
import CryptoKit
import CoreText
import ImageIO
import QuartzCore
import UniformTypeIdentifiers
import SwiftUI

struct ReplayArtworkColor: Equatable, Sendable, Codable {
    let red: Double
    let green: Double
    let blue: Double
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

struct ReplayArtwork {
    let colors: [ReplayArtworkColor]
    let phase: Double
    let artists: String
    let cover: CGImage
    let base64: String
}

/// Pixel sampling runs away from the main actor. A saturated histogram cluster
/// preserves a cover's dominant hue instead of averaging complementary hues to gray.
actor ReplayPaletteExtractor {
    static let shared = ReplayPaletteExtractor()

    func colors(from images: [CGImage]) -> [ReplayArtworkColor] {
        images.compactMap(dominantColor)
    }

    private func dominantColor(_ image: CGImage) -> ReplayArtworkColor? {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        var bins: [Int: (weight: Double, red: Double, green: Double, blue: Double)] = [:]
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.5 else { continue }
            let red = Double(pixels[offset]) / 255 / alpha
            let green = Double(pixels[offset + 1]) / 255 / alpha
            let blue = Double(pixels[offset + 2]) / 255 / alpha
            let high = max(red, green, blue), low = min(red, green, blue)
            let delta = high - low
            guard high > 0.12, low < 0.94, delta > 0.08 else { continue }
            var hue: Double
            if high == red { hue = (green - blue) / delta / 6 }
            else if high == green { hue = ((blue - red) / delta + 2) / 6 }
            else { hue = ((red - green) / delta + 4) / 6 }
            if hue < 0 { hue += 1 }
            let key = Int(hue * 18) % 18
            let weight = 0.3 + delta / high
            let old = bins[key] ?? (0, 0, 0, 0)
            bins[key] = (old.weight + weight, old.red + red * weight,
                         old.green + green * weight, old.blue + blue * weight)
        }
        guard let strongest = bins.sorted(by: {
            $0.value.weight == $1.value.weight ? $0.key < $1.key : $0.value.weight > $1.value.weight
        }).first?.value else { return nil }
        return ReplayArtworkColor(red: strongest.red / strongest.weight,
            green: strongest.green / strongest.weight, blue: strongest.blue / strongest.weight)
    }
}

@MainActor
final class ReplayArtworkRepository {
    static let shared = ReplayArtworkRepository()
    struct Key: Hashable {
        let coreID: ObjectIdentifier?
        let period: String
        let artworkIDs: [String]
        let artists: String
    }
    private let cache = CostLimitedLRU<Key, ReplayArtwork>(byteLimit: 48 * 1024 * 1024, countLimit: 12)
    private var flights: [Key: Task<ReplayArtwork?, Never>] = [:]
    private var savedArtworkKeys: [Key: Key] = [:]
    private var savedRecipes: [Key: (colors: [ReplayArtworkColor], phase: Double, artists: String)] = [:]

    func freeze(_ artwork: ReplayArtwork, draft: RetrospectivePlaylistDraft, core: DurvaldCore?) {
        let key = Key(coreID: core.map(ObjectIdentifier.init), period: draft.identity, artworkIDs: [], artists: "")
        let cached = Key(coreID: key.coreID, period: key.period, artworkIDs: ["replay:saved"], artists: artwork.artists)
        savedArtworkKeys[key] = cached
        savedRecipes[key] = (artwork.colors, artwork.phase, artwork.artists)
        cache.insert(artwork, for: cached, cost: artwork.cover.bytesPerRow * artwork.cover.height + artwork.base64.utf8.count)
    }

    static func albumSources(for tracks: [Track], using store: DurvaldCoreStore) -> [Track] {
        tracks.map { track in
            var source = track
            source.artworkId = store.loadedRelease(id: track.releaseId)?.artworkId ?? track.artworkId
            return source
        }
    }

    static func key(draft: RetrospectivePlaylistDraft, tracks: [Track], core: DurvaldCore?) -> Key {
        var seen = Set<String>()
        let ids = tracks.compactMap(\.artworkId).filter { seen.insert($0).inserted }.prefix(8)
        var artists = Set<String>()
        let names = tracks.map(\.artist).filter { !$0.isEmpty && artists.insert($0).inserted }
        let line = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " e mais" : "")
        return Key(coreID: core.map(ObjectIdentifier.init), period: draft.identity,
                   artworkIDs: Array(ids), artists: line)
    }

    func artwork(draft: RetrospectivePlaylistDraft, tracks: [Track], core: DurvaldCore?) async -> ReplayArtwork? {
        let savedKey = Key(coreID: core.map(ObjectIdentifier.init), period: draft.identity, artworkIDs: [], artists: "")
        if let key = savedArtworkKeys[savedKey], let recipe = savedRecipes[savedKey] {
            if let saved = cache.value(for: key) { return saved }
            let saved = Self.render(draft: draft, colors: recipe.colors, phase: recipe.phase, artists: recipe.artists)
            if let saved { cache.insert(saved, for: key, cost: saved.cover.bytesPerRow * saved.cover.height + saved.base64.utf8.count) }
            return saved
        }
        let key = Self.key(draft: draft, tracks: tracks, core: core)
        if let cached = cache.value(for: key) { return cached }
        if let flight = flights[key] { return await flight.value }
        let task = Task { @MainActor () -> ReplayArtwork? in
            var images: [CGImage] = []
            if let core {
                for id in key.artworkIDs {
                    if let image = try? await ArtworkRepository.shared.image(for: id, pixelSize: 64, using: core),
                       let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        images.append(bitmap)
                    }
                }
            }
            let samples = await ReplayPaletteExtractor.shared.colors(from: images)
            return Self.render(draft: draft, samples: samples, artists: key.artists)
        }
        flights[key] = task
        let result = await task.value
        flights[key] = nil
        if let result {
            cache.insert(result, for: key, cost: result.cover.bytesPerRow * result.cover.height + result.base64.utf8.count)
        }
        return result
    }

    static func render(draft: RetrospectivePlaylistDraft, samples: [ReplayArtworkColor], artists: String) -> ReplayArtwork? {
        let digest = Array(SHA256.hash(data: Data(draft.identity.utf8)))
        let phase = Double(digest[0]) / 255
        let fallbackHue = Double(digest[1]) / 255
        func hsv(_ sample: ReplayArtworkColor) -> (CGFloat, CGFloat, CGFloat) {
            let color = NSColor(srgbRed: sample.red, green: sample.green, blue: sample.blue, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            return (h, s, b)
        }
        let base = samples.first.map(hsv) ?? (CGFloat(fallbackHue), 0.72, 0.74)
        let colors: [ReplayArtworkColor] = (0..<4).map { index in
            let source = samples.isEmpty ? base : hsv(samples[index % samples.count])
            var distance = source.0 - base.0
            if distance > 0.5 { distance -= 1 }
            if distance < -0.5 { distance += 1 }
            let shift = [0.0, 0.065, -0.06, 0.11][index]
            let hue = (base.0 + min(0.18, max(-0.18, distance)) * 0.55 + shift + 1)
                .truncatingRemainder(dividingBy: 1)
            let color = NSColor(calibratedHue: hue, saturation: min(0.86, max(0.42, source.1)),
                                brightness: min(0.92, max(0.55, source.2)), alpha: 1)
                .usingColorSpace(.sRGB)!
            return ReplayArtworkColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
        }
        return render(draft: draft, colors: colors, phase: phase, artists: artists)
    }

    private static func render(draft: RetrospectivePlaylistDraft, colors: [ReplayArtworkColor], phase: Double, artists: String) -> ReplayArtwork? {
        let renderer = ImageRenderer(content: ReplayArtworkComposition(draft: draft, colors: colors,
            phase: phase, artists: artists).frame(width: 1024, height: 1024)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        let recipe = ReplayArtworkRecipe(version: 1, period: draft.period.rawValue,
            start: draft.interval.start, end: draft.interval.end, colors: colors, phase: phase, artists: artists)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let encoded = try? encoder.encode(recipe),
              let description = String(data: encoded, encoding: .utf8) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary:
            [kCGImagePropertyPNGDescription: description]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ReplayArtwork(colors: colors, phase: phase, artists: artists, cover: image, base64: (data as Data).base64EncodedString())
    }
}

/// One responsive artwork template is used by the banner and by the exported
/// square cover. Palette, curves, date seed and typography are shared verbatim.
struct ReplayArtworkComposition: View {
    let draft: RetrospectivePlaylistDraft
    let colors: [ReplayArtworkColor]
    let phase: Double
    let artists: String

    var motion: Double = 0
    var drawsBackground = true

    /// Short editorial labels fit both the square cover and wide banner.
    static func labels(for draft: RetrospectivePlaylistDraft) -> (primary: String, secondary: String?) {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "MMM"
        let month = formatter.string(from: draft.interval.start).replacingOccurrences(of: ".", with: "").uppercased()
        let year = calendar.component(.year, from: draft.interval.start)
        let shortYear = "’" + String(format: "%02d", year % 100)
        switch draft.period {
        case .daily: return (String(calendar.component(.day, from: draft.interval.start)), "\(month) \(shortYear)")
        case .weekly: return (String(calendar.component(.weekOfYear, from: draft.interval.start)), shortYear)
        case .monthly: return (month, shortYear)
        case .yearly: return (shortYear, nil)
        }
    }

    /// Equal layout insets do not produce equal visible margins: SF's large
    /// capitals reserve much more descender space than the Replay heading.
    private static func bottomOpticalOffset(unit: CGFloat, labels: (primary: String, secondary: String?), period: RetrospectivePeriod) -> CGFloat {
        func ink(_ text: String, font: NSFont) -> CGRect {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        }
        let headingSize = unit * 0.105
        let systemHeading = NSFont.systemFont(ofSize: headingSize, weight: .bold)
        let heading = systemHeading.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: headingSize) } ?? systemHeading
        let topWhitespace = heading.ascender - ink("Replay", font: heading).maxY
        let marker = NSFont.systemFont(ofSize: unit * (period == .monthly || period == .yearly ? 0.30 : 0.40), weight: .semibold)
        var inkBottom = ink(labels.primary, font: marker).minY
        if let secondary = labels.secondary {
            inkBottom = min(inkBottom, ink(secondary, font: .systemFont(ofSize: unit * 0.14, weight: .medium)).minY)
        }
        let bottomWhitespace = -marker.descender + inkBottom
        return bottomWhitespace - topWhitespace
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let unit = min(size.width, size.height)
            let wide = size.width > size.height * 1.6
            let labels = Self.labels(for: draft)
            ZStack {
                if drawsBackground {
                    ReplayGradient(period: draft.period, colors: colors, seed: phase, motion: motion)
                }
                LinearGradient(colors: [.black.opacity(0.12), .clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                // A single flow layout reserves separate rows for the brand and
                // period. No absolute offsets or competing footer overlays.
                VStack(alignment: .leading, spacing: unit * 0.06) {
                    VStack(alignment: .leading, spacing: unit * 0.018) {
                        Text("Replay")
                            .font(.system(size: unit * (wide ? 0.16 : 0.105), weight: .bold, design: .rounded))
                        Text(draft.period.title.uppercased())
                            .font(.system(size: unit * (wide ? 0.06 : 0.034), weight: .semibold))
                            .tracking(unit * 0.008)
                            // Align the visible glyph edge with the rounded R,
                            // whose side bearing is wider than the scope label.
                            .padding(.leading, unit * (wide ? 0.006 : 0.004))
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: unit * 0.035) {
                        if wide { Spacer(minLength: 0) }
                        Text(labels.primary)
                            .font(.system(size: unit * (draft.period == .monthly || draft.period == .yearly ? (wide ? 0.38 : 0.30) : (wide ? 0.44 : 0.40)), weight: .semibold))
                            .tracking(-unit * 0.012)
                        if let secondary = labels.secondary {
                            Text(secondary)
                                .font(.system(size: unit * 0.14, weight: .medium))
                        }
                    }
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: wide ? 0 : Self.bottomOpticalOffset(unit: unit, labels: labels, period: draft.period))
                }
                .foregroundStyle(.white.opacity(0.96))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(unit * 0.085)
            }
            .clipped()
        }
        .accessibilityHidden(true)
    }
}


/// The PNG remains a portable poster; this small embedded recipe restores native
/// motion after saving/relaunching, including snapshots without smart rules.
struct ReplayArtworkRecipe: Codable, Sendable {
    let version: Int
    let period: String
    let start: Date
    let end: Date
    let colors: [ReplayArtworkColor]
    let phase: Double
    let artists: String

    var draft: RetrospectivePlaylistDraft {
        RetrospectivePlaylistDraft(period: RetrospectivePeriod(rawValue: period)!, interval: DateInterval(start: start, end: end))
    }

    static func read(base64: String) -> Self? {
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any],
              let text = png[kCGImagePropertyPNGDescription as String] as? String,
              text.utf8.count < 16_384,
              let recipe = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              recipe.version == 1, RetrospectivePeriod(rawValue: recipe.period) != nil,
              recipe.end > recipe.start, recipe.colors.count == 4, recipe.phase.isFinite,
              recipe.colors.allSatisfy({ [$0.red, $0.green, $0.blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }) else { return nil }
        return recipe
    }
}

struct AnimatedReplayArtwork: View {
    let draft: RetrospectivePlaylistDraft
    let colors: [ReplayArtworkColor]
    let phase: Double
    let artists: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    @State private var frames: [CGImage] = []

    var body: some View {
        GeometryReader { geometry in
            let key = ReplayMotionRepository.key(draft: draft, colors: colors, phase: phase, size: geometry.size)
            ZStack {
                if !frames.isEmpty && !reduceMotion {
                    ReplayFrameSurface(frames: frames, playing: visible && scenePhase == .active,
                        cornerRadius: geometry.size.width > geometry.size.height * 1.6 ? 20 : min(12, geometry.size.width * 0.045))
                }
                ReplayArtworkComposition(draft: draft, colors: colors, phase: phase, artists: artists,
                    drawsBackground: frames.isEmpty || reduceMotion)
            }
            .task(id: reduceMotion ? nil : key) {
                guard !reduceMotion else { frames = []; return }
                let result = await ReplayMotionRepository.shared.frames(key: key, draft: draft,
                    colors: colors, phase: phase, size: geometry.size)
                guard !Task.isCancelled else { return }
                frames = result
            }
        }
        .onAppear { visible = true }.onDisappear { visible = false }
    }

    static let cycleDuration: Double = 10
    static func motion(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration * 2 * .pi
    }
}

/// Bake only the soft background, never typography. Periodic samples are blended
/// by Core Animation; no SwiftUI timeline, Canvas or blur runs per frame.
@MainActor
final class ReplayMotionRepository {
    static let shared = ReplayMotionRepository()
    private let cache = CostLimitedLRU<String, [CGImage]>(byteLimit: 32 * 1024 * 1024, countLimit: 8)
    private var flights: [String: Task<[CGImage], Never>] = [:]
    static let frameCount = 12

    static func frameCount(period: RetrospectivePeriod, size: CGSize) -> Int {
        // Monthly curtains travel across the long axis. Twelve samples suffice
        // on square covers but crossfade between distant ribbons on banners.
        period == .monthly && aspectBucket(for: size) > 1.6 ? 96 : frameCount
    }

    private static func aspectBucket(for size: CGSize) -> CGFloat {
        (max(0.5, min(6, size.width / max(1, size.height))) * 4).rounded() / 4
    }

    static func rasterSize(for size: CGSize, period: RetrospectivePeriod? = nil) -> CGSize {
        // Bucket resize changes so dragging a window edge does not bake a
        // different animation for every pixel of width.
        let aspect = aspectBucket(for: size)
        let width: CGFloat = period == .monthly && aspect > 1.6 ? 480 : 640
        return aspect > 1.6 ? CGSize(width: width, height: (width / aspect).rounded()) : CGSize(width: (256 * aspect).rounded(), height: 256)
    }

    static func key(draft: RetrospectivePlaylistDraft, colors: [ReplayArtworkColor], phase: Double, size: CGSize) -> String {
        let raster = rasterSize(for: size, period: draft.period)
        let components = colors.flatMap { [$0.red, $0.green, $0.blue] }.map(String.init(describing:)).joined(separator: ",")
        return "\(draft.identity):\(phase):\(raster.width)x\(raster.height):\(components)"
    }

    func frames(key: String, draft: RetrospectivePlaylistDraft, colors: [ReplayArtworkColor], phase: Double, size: CGSize) async -> [CGImage] {
        if let cached = cache.value(for: key) { return cached }
        if let flight = flights[key] { return await flight.value }
        let raster = Self.rasterSize(for: size, period: draft.period)
        let count = Self.frameCount(period: draft.period, size: size)
        let task = Task { @MainActor in
            var result: [CGImage] = []
            for index in 0..<count {
                let renderer = ImageRenderer(content: ReplayGradient(period: draft.period, colors: colors,
                    seed: phase, motion: Double(index) / Double(count) * 2 * .pi)
                    .frame(width: raster.width, height: raster.height))
                renderer.scale = 1
                guard let image = renderer.cgImage else { return [CGImage]() }
                result.append(image)
                await Task.yield()
            }
            return result
        }
        flights[key] = task
        let result = await task.value
        flights[key] = nil
        if !result.isEmpty { cache.insert(result, for: key, cost: result.reduce(0) { $0 + $1.bytesPerRow * $1.height }) }
        return result
    }
}

struct ReplayFrameSurface: NSViewRepresentable {
    let frames: [CGImage]
    let playing: Bool
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> ReplayFrameView { ReplayFrameView() }
    func updateNSView(_ view: ReplayFrameView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.configure(frames: frames, playing: playing)
    }
}

final class ReplayFrameView: NSView {
    private var images: [CGImage] = []
    private var paused = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func opacitySamples(frame: Int, count: Int) -> [NSNumber] {
        // Keep the outgoing texture opaque beneath its incoming neighbour.
        // The final texture fades over the first, closing the loop without a dip.
        (0...count).map { step in
            NSNumber(value: frame == 0 || step == frame || (frame < count - 1 && step == frame + 1) ? 1.0 : 0.0)
        }
    }

    func configure(frames: [CGImage], playing: Bool) {
        guard let layer else { return }
        if images.count != frames.count || images.first !== frames.first {
            images = frames
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            let start = layer.convertTime(CACurrentMediaTime(), from: nil)
            for (index, image) in frames.enumerated() {
                let texture = CALayer()
                texture.frame = bounds
                texture.contents = image
                texture.contentsGravity = .resize
                texture.opacity = index == 0 ? 1 : 0
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = Self.opacitySamples(frame: index, count: frames.count)
                fade.keyTimes = (0...frames.count).map { NSNumber(value: Double($0) / Double(frames.count)) }
                fade.duration = AnimatedReplayArtwork.cycleDuration
                fade.repeatCount = .infinity
                fade.calculationMode = .linear
                fade.beginTime = start
                layer.addSublayer(texture)
                if index > 0 { texture.add(fade, forKey: "replay.loop") }
            }
        }
        if !playing && !paused {
            layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            paused = true
        } else if playing && paused {
            let offset = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - offset
            paused = false
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.forEach { $0.frame = bounds }
        CATransaction.commit()
    }
}

/// Each scope has its own silhouette. All moving coordinates are periodic, so
/// the 10-second cycle has matching position and velocity at the seam.
struct ReplayGradient: View {
    let period: RetrospectivePeriod
    let colors: [ReplayArtworkColor]
    let seed: Double
    let motion: Double

    static func palette(_ colors: [ReplayArtworkColor], period: RetrospectivePeriod) -> [ReplayArtworkColor] {
        let shift: Double
        switch period {
        case .daily: shift = -0.035
        case .weekly: shift = 0.08
        case .monthly: shift = -0.13
        case .yearly: shift = 0.46
        }
        let anchor = NSColor(srgbRed: colors[0].red, green: colors[0].green, blue: colors[0].blue, alpha: 1)
        var anchorHue: CGFloat = 0
        anchor.getHue(&anchorHue, saturation: nil, brightness: nil, alpha: nil)
        return colors.enumerated().map { index, sample in
            let source = NSColor(srgbRed: sample.red, green: sample.green, blue: sample.blue, alpha: 1)
            var h: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            source.getHue(&h, saturation: &saturation, brightness: &brightness, alpha: nil)
            var distance = h - anchorHue
            if distance > 0.5 { distance -= 1 }
            if distance < -0.5 { distance += 1 }
            let accents = [0.0, 0.035, -0.045, 0.11]
            let hue = (anchorHue + shift + min(0.06, max(-0.06, distance)) * 0.3 + accents[index % 4] + 1)
                .truncatingRemainder(dividingBy: 1)
            let values = period == .yearly ? [0.38, 0.72, 0.52, 0.98] : [0.56, 0.92, 0.68, 1.0]
            let color = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            let vivid = NSColor(calibratedHue: hue, saturation: index == 3 ? 0.64 : min(0.92, max(0.74, saturation * 1.15)),
                brightness: values[index % 4], alpha: 1).usingColorSpace(.sRGB) ?? color
            return ReplayArtworkColor(red: vivid.redComponent, green: vivid.greenComponent, blue: vivid.blueComponent)
        }
    }

    var body: some View {
        let colors = Self.palette(colors, period: period)
        Canvas { context, size in
            let w = size.width, h = size.height
            let bounds = Path(CGRect(origin: .zero, size: size))
            let level = RetrospectivePeriod.allCases.firstIndex(of: period) ?? 0
            let angle = motion + seed * 2 * .pi
            context.fill(bounds, with: .linearGradient(Gradient(colors: [colors[0].color, colors[1].color, colors[2].color]),
                startPoint: CGPoint(x: w * (0.15 + sin(angle) * 0.2), y: 0), endPoint: CGPoint(x: w * (0.85 + cos(angle) * 0.2), y: h)))
            // Daily: quiet broad color fields. Higher scopes add depth and layers.
            for i in 0..<(level + 3) {
                let a = angle + Double(i) * 2.1
                let center = CGPoint(x: w * (0.5 + cos(a) * 0.46), y: h * (0.5 + sin(a) * 0.42))
                context.fill(bounds, with: .radialGradient(Gradient(colors: [colors[i % 4].color.opacity(0.85), .clear]),
                    center: center, startRadius: 0, endRadius: max(w, h) * 0.62))
            }
            if period == .yearly {
                context.fill(bounds, with: .color(.black.opacity(0.22)))
            }
            if period != .daily {
                let count = period == .weekly ? 1 : (period == .monthly ? 2 : 3)
                for i in 0..<count {
                    let offset = Double(i)
                    var ribbon = Path()
                    if period == .yearly {
                        // Closed, tilted luminous orbits give the annual edition
                        // a distinct silhouette rather than extra weekly waves.
                        let orbit = Path(ellipseIn: CGRect(x: -0.18 + offset * 0.09,
                            y: 0.18 + offset * 0.13 + sin(angle + offset) * 0.10,
                            width: 1.36 - offset * 0.14, height: 0.62 - offset * 0.08))
                        let tilt = -0.16 + cos(angle) * 0.13
                        let transform = CGAffineTransform(translationX: -0.5, y: -0.5)
                            .concatenating(CGAffineTransform(rotationAngle: tilt))
                            .concatenating(CGAffineTransform(translationX: 0.5, y: 0.5))
                            .concatenating(CGAffineTransform(scaleX: w, y: h))
                        ribbon = orbit.applying(transform)
                    } else if period == .monthly {
                        // Interlacing aurora curtains rather than a horizontal wave.
                        ribbon.move(to: CGPoint(x: w * (-0.1 + offset * 0.55), y: -h * 0.2))
                        ribbon.addCurve(to: CGPoint(x: w * (0.6 + offset * 0.45), y: h * 1.2),
                            control1: CGPoint(x: w * (0.85 + sin(angle + offset) * 0.23), y: h * 0.15),
                            control2: CGPoint(x: w * (0.05 + cos(angle + offset) * 0.23), y: h * 0.8))
                    } else {
                        ribbon.move(to: CGPoint(x: -w * 0.15, y: h * (0.68 + offset * 0.16)))
                        ribbon.addCurve(to: CGPoint(x: w * 1.15, y: h * (0.32 + offset * 0.14)),
                            control1: CGPoint(x: w * 0.25, y: h * (0.05 + sin(angle + offset) * 0.24)),
                            control2: CGPoint(x: w * 0.65, y: h * (0.95 + cos(angle + offset) * 0.24)))
                    }
                    context.drawLayer { glow in
                        glow.addFilter(.blur(radius: h * (period == .monthly ? 0.065 : 0.04)))
                        glow.stroke(ribbon, with: .color(colors[(i + 3) % 4].color.opacity(0.9)),
                            style: StrokeStyle(lineWidth: h * 0.22, lineCap: .round))
                        glow.stroke(ribbon, with: .color(.white.opacity(period == .yearly ? 0.36 : 0.16)),
                            style: StrokeStyle(lineWidth: h * 0.045, lineCap: .round))
                    }
                    if period == .yearly {
                        context.drawLayer { silk in
                            silk.addFilter(.blur(radius: h * 0.008))
                            silk.stroke(ribbon, with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.5), colors[1].color.opacity(0.3), .clear]), startPoint: .zero, endPoint: CGPoint(x: w, y: h)),
                                style: StrokeStyle(lineWidth: h * 0.007, lineCap: .round))
                        }
                    }
                }
            }
        }
    }
}
