import AppKit
import SwiftUI
import XCTest
@testable import Durvald

@MainActor
final class ReplayArtworkTests: XCTestCase {
    private var draft: RetrospectivePlaylistDraft {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16))!
        return RetrospectivePlaylistDraft(period: .monthly, interval: calendar.dateInterval(of: .month, for: date)!)
    }
    private let samples = [ReplayArtworkColor(red: 0.78, green: 0.32, blue: 0.08),
                           ReplayArtworkColor(red: 0.91, green: 0.54, blue: 0.12),
                           ReplayArtworkColor(red: 0.7, green: 0.1, blue: 0.24)]

    func testSavedPNGRestoresAnimationRecipeAndRejectsOrdinaryArtwork() throws {
        let artwork = try XCTUnwrap(ReplayArtworkRepository.render(draft: draft, samples: samples, artists: "Artista"))
        let recipe = try XCTUnwrap(ReplayArtworkRecipe.read(base64: artwork.base64))
        XCTAssertEqual(recipe.draft, draft)
        XCTAssertEqual(recipe.colors, artwork.colors)
        XCTAssertEqual(recipe.phase, artwork.phase)
        XCTAssertEqual(recipe.artists, artwork.artists)
        let plain = try XCTUnwrap(NSBitmapImageRep(cgImage: artwork.cover).representation(using: .png, properties: [:]))
        XCTAssertNil(ReplayArtworkRecipe.read(base64: plain.base64EncodedString()))
        XCTAssertNil(ReplayArtworkRecipe.read(base64: "invalid"))
    }

    func testAllScopeLayoutsAndSeamlessMotion() throws {
        let date = Date(timeIntervalSinceReferenceDate: 10 * 1000 + 7)
        XCTAssertEqual(AnimatedReplayArtwork.motion(at: date), AnimatedReplayArtwork.motion(at: date.addingTimeInterval(10)), accuracy: 0.000001)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let september = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        for period in RetrospectivePeriod.allCases {
            let component: Calendar.Component = period == .daily ? .day : period == .weekly ? .weekOfYear : period == .monthly ? .month : .year
            let draft = RetrospectivePlaylistDraft(period: period, interval: calendar.dateInterval(of: component, for: september)!)
            let artwork = try XCTUnwrap(ReplayArtworkRepository.render(draft: draft, samples: samples, artists: "Men I Trust, Oklou, Wendy Carlos"))
            var frames: [Data] = []
            for motion in [0.0, Double.pi, Double.pi * 2] {
                let renderer = ImageRenderer(content: ReplayArtworkComposition(draft: draft, colors: artwork.colors,
                    phase: artwork.phase, artists: artwork.artists, motion: motion).frame(width: 1200, height: 280))
                let image = try XCTUnwrap(renderer.cgImage)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                frames.append(png)
                if motion == 0 {
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = "Motion \(period.rawValue) banner"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            XCTAssertNotEqual(frames[0], frames[1], "Every scope must animate")
            // Compare pixels rather than encoded metadata; tiny floating point
            // differences at 2π may produce subpixel rasterization differences.
            let first = try XCTUnwrap(NSBitmapImageRep(data: frames[0]))
            let last = try XCTUnwrap(NSBitmapImageRep(data: frames[2]))
            for x in stride(from: 0, to: 1200, by: 80) {
                for y in stride(from: 0, to: 280, by: 40) {
                    let a = try XCTUnwrap(first.colorAt(x: x, y: y))
                    let b = try XCTUnwrap(last.colorAt(x: x, y: y))
                    XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.01)
                    XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.01)
                    XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.01)
                }
            }
        }
    }

    func testCompactPeriodLabelsAndDistinctScopePalettes() throws {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        let monthly = RetrospectivePlaylistDraft(period: .monthly, interval: Calendar.current.dateInterval(of: .month, for: date)!)
        let weekly = RetrospectivePlaylistDraft(period: .weekly, interval: Calendar.current.dateInterval(of: .weekOfYear, for: date)!)
        XCTAssertEqual(ReplayArtworkComposition.labels(for: monthly).primary, "SET")
        XCTAssertEqual(ReplayArtworkComposition.labels(for: monthly).secondary, "’26")
        XCTAssertEqual(ReplayArtworkComposition.labels(for: weekly).primary, "39")
        XCTAssertEqual(ReplayArtworkComposition.labels(for: weekly).secondary, "’26")
        let yearly = RetrospectivePlaylistDraft(period: .yearly, interval: monthly.interval)
        XCTAssertEqual(ReplayArtworkComposition.labels(for: yearly).primary, "’26")
        let palettes = RetrospectivePeriod.allCases.map { ReplayGradient.palette(samples, period: $0) }
        for i in palettes.indices {
            for j in palettes.indices where i != j { XCTAssertNotEqual(palettes[i], palettes[j]) }
        }
        for period in RetrospectivePeriod.allCases {
            let draft = RetrospectivePlaylistDraft(period: period, interval: weekly.interval)
            var frames: [Data] = []
            for artists in ["", "Men I Trust, Oklou, Wendy Carlos"] {
                let artwork = try XCTUnwrap(ReplayArtworkRepository.render(draft: draft, samples: samples, artists: artists))
                let renderer = ImageRenderer(content: ReplayArtworkComposition(draft: draft, colors: artwork.colors,
                    phase: artwork.phase, artists: artists).frame(width: 200, height: 200))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                frames.append(png)
                if artists.isEmpty {
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = "Compact \(period.rawValue) cover"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            XCTAssertEqual(frames[0], frames[1], "Artist names must not appear in artwork")
        }
    }

    func testMotionBakesOnceAndNativePlaybackReusesTextures() async throws {
        let repository = ReplayMotionRepository()
        let size = CGSize(width: 1200, height: 280)
        let key = ReplayMotionRepository.key(draft: draft, colors: samples, phase: 0.4, size: size)
        // Production palettes always have four entries.
        let colors = samples + [samples[0]]
        let first = await repository.frames(key: key, draft: draft, colors: colors, phase: 0.4, size: size)
        let second = await repository.frames(key: key, draft: draft, colors: colors, phase: 0.4, size: size)
        XCTAssertEqual(first.count, ReplayMotionRepository.frameCount(period: draft.period, size: size))
        XCTAssertTrue(first[0] === second[0], "Navigation must reuse the baked frames")
        XCTAssertEqual(first[0].width, Int(ReplayMotionRepository.rasterSize(for: size, period: draft.period).width))
        let view = ReplayFrameView(frame: CGRect(origin: .zero, size: size))
        view.configure(frames: first, playing: true)
        let layers = try XCTUnwrap(view.layer?.sublayers)
        XCTAssertEqual(layers.count, first.count)
        let beginnings = layers.dropFirst().compactMap { $0.animation(forKey: "replay.loop")?.beginTime }
        XCTAssertEqual(Set(beginnings).count, 1, "Every texture must share the same timeline origin")
        view.configure(frames: second, playing: false)
        XCTAssertTrue(view.layer?.sublayers?.first === layers.first)
        XCTAssertEqual(view.layer?.speed, 0)
        view.configure(frames: second, playing: true)
        XCTAssertEqual(view.layer?.speed, 1)
        for frame in first.indices {
            let opacity = ReplayFrameView.opacitySamples(frame: frame, count: first.count)
            XCTAssertEqual(opacity.first, opacity.last, "Every texture must close its opacity loop")
        }
    }

    func testMonthlyBannerSamplesFollowRibbonInsteadOfDissolvingBetweenDistantPositions() throws {
        let size = CGSize(width: 1200, height: 280)
        let count = ReplayMotionRepository.frameCount(period: .monthly, size: size)
        XCTAssertEqual(ReplayMotionRepository.frameCount(period: .monthly, size: CGSize(width: 200, height: 200)), 12)
        XCTAssertEqual(ReplayMotionRepository.frameCount(period: .weekly, size: size), 12)
        let raster = ReplayMotionRepository.rasterSize(for: size, period: .monthly)
        XCTAssertLessThan(Int(raster.width * raster.height) * 4 * count, 32 * 1024 * 1024)
        let colors = samples + [samples[0]]
        func render(_ motion: Double) throws -> CGImage {
            let renderer = ImageRenderer(content: ReplayGradient(period: .monthly, colors: colors, seed: 0, motion: motion)
                .frame(width: raster.width, height: raster.height))
            return try XCTUnwrap(renderer.cgImage)
        }
        func interpolationError(count: Int) throws -> Double {
            let step = 2 * Double.pi / Double(count)
            let first = try render(0), second = try render(step)
            let exact = NSBitmapImageRep(cgImage: try render(step / 2))
            let context = try XCTUnwrap(CGContext(data: nil, width: first.width, height: first.height,
                bitsPerComponent: 8, bytesPerRow: first.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let bounds = CGRect(x: 0, y: 0, width: first.width, height: first.height)
            context.draw(first, in: bounds)
            context.setAlpha(0.5)
            context.draw(second, in: bounds)
            let blended = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            var error = 0.0, samples = 0.0
            for y in stride(from: 0, to: first.height, by: 3) {
                for x in stride(from: 0, to: first.width, by: 3) {
                    let a = try XCTUnwrap(exact.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let b = try XCTUnwrap(blended.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    error += abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
                    samples += 3
                }
            }
            return error / samples
        }
        let coarse = try interpolationError(count: 12)
        let smooth = try interpolationError(count: count)
        XCTAssertLessThan(smooth, coarse * 0.2, "The crossfade must closely follow the actual intermediate ribbon")
        XCTAssertLessThan(smooth, 0.006)
    }

    func testCoverVisibleTopAndBottomMarginsMatch() throws {
        for period in RetrospectivePeriod.allCases {
            let draft = RetrospectivePlaylistDraft(period: period, interval: self.draft.interval)
            let renderer = ImageRenderer(content: ReplayArtworkComposition(draft: draft, colors: samples,
                phase: 0, artists: "", drawsBackground: false).frame(width: 400, height: 400))
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            var rows: [Int] = []
            for y in 0..<400 {
                if (0..<400).contains(where: { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                    return color.alphaComponent > 0.75 && min(color.redComponent, color.greenComponent, color.blueComponent) > 0.8
                }) { rows.append(y) }
            }
            let top = try XCTUnwrap(rows.first)
            let bottom = 399 - (try XCTUnwrap(rows.last))
            XCTAssertEqual(Double(top), Double(bottom), accuracy: 3, "Visible margins should match for \(period)")
        }
    }

    func testDominantColorsComeFromCoverPixelsAndTransparentPixelsAreIgnored() async throws {
        func image(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return try XCTUnwrap(context.makeImage())
        }
        let images = try [image(red: 1, green: 0, blue: 0, alpha: 1), image(red: 0, green: 0, blue: 1, alpha: 1), image(red: 1, green: 0, blue: 0, alpha: 0)]
        let colors = await ReplayPaletteExtractor.shared.colors(from: images)
        XCTAssertEqual(colors.count, 2)
        XCTAssertGreaterThan(colors[0].red, 0.95)
        XCTAssertLessThan(colors[0].blue, 0.05)
        XCTAssertGreaterThan(colors[1].blue, 0.95)
    }

    func testSharedTemplateExportsSquareCoverAndWideBannerWithSamePalette() throws {
        let artwork = try XCTUnwrap(ReplayArtworkRepository.render(draft: draft, samples: samples, artists: "Marina Sena, Elba Ramalho, Cazuza e mais"))
        XCTAssertEqual(artwork.cover.width, 1024)
        XCTAssertEqual(artwork.cover.height, 1024)
        let data = try XCTUnwrap(Data(base64Encoded: artwork.base64))
        XCTAssertNotNil(NSImage(data: data))
        let coverAttachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        coverAttachment.name = "Replay cover"
        coverAttachment.lifetime = .keepAlways
        add(coverAttachment)
        let banner = ImageRenderer(content: ReplayArtworkComposition(draft: draft, colors: artwork.colors,
            phase: artwork.phase, artists: artwork.artists).frame(width: 1200, height: 340).environment(\.colorScheme, .dark))
        let image = try XCTUnwrap(banner.cgImage)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let bannerAttachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        bannerAttachment.name = "Replay banner"
        bannerAttachment.lifetime = .keepAlways
        add(bannerAttachment)
        let recipe = try XCTUnwrap(ReplayArtworkRecipe.read(base64: artwork.base64))
        XCTAssertEqual(recipe.draft, draft, "Artwork metadata describes only presentation, never save policy")
    }

    func testArtworkIsDeterministicAndVariesByPeriod() throws {
        let first = try XCTUnwrap(ReplayArtworkRepository.render(draft: draft, samples: samples, artists: "Artista"))
        let repeated = try XCTUnwrap(ReplayArtworkRepository.render(draft: draft, samples: samples, artists: "Artista"))
        XCTAssertEqual(first.colors, repeated.colors)
        XCTAssertEqual(first.phase, repeated.phase)
        XCTAssertEqual(first.base64, repeated.base64)
        let daily = RetrospectivePlaylistDraft(period: .daily, interval: draft.interval)
        let different = try XCTUnwrap(ReplayArtworkRepository.render(draft: daily, samples: samples, artists: "Artista"))
        XCTAssertNotEqual(first.phase, different.phase)
        XCTAssertNotEqual(first.base64, different.base64)
    }

    func testMissingCoversStillProduceAnExportableFallbackAndSourcesAreDeduplicated() throws {
        let artwork = try XCTUnwrap(ReplayArtworkRepository.render(draft: draft, samples: [], artists: ""))
        XCTAssertEqual(artwork.colors.count, 4)
        XCTAssertNotNil(Data(base64Encoded: artwork.base64))
        var first = Fixtures.track
        first.artworkId = "album-a"
        var second = first
        second.id = 2
        let key = ReplayArtworkRepository.key(draft: draft, tracks: [first, second], core: nil)
        XCTAssertEqual(key.artworkIDs, ["album-a"])
    }

    func testSavedArtworkStaysIdenticalWhenLivePlaylistTracksChange() async throws {
        let repository = ReplayArtworkRepository()
        let original = try XCTUnwrap(ReplayArtworkRepository.render(draft: draft, samples: samples, artists: "Artista"))
        repository.freeze(original, draft: draft, core: nil)
        let reloaded = await repository.artwork(draft: draft, tracks: [], core: nil)
        XCTAssertEqual(reloaded?.base64, original.base64)
        XCTAssertEqual(reloaded?.colors, original.colors)
    }

    func testAlbumCoverIsPreferredOverIndividualTrackCover() {
        var album = Fixtures.release
        album.artworkId = "album-cover"
        var track = Fixtures.track
        track.artworkId = "track-cover"
        let store = DurvaldCoreStore(tracks: [track], releases: [album])
        let sources = ReplayArtworkRepository.albumSources(for: [track], using: store)
        XCTAssertEqual(sources.first?.artworkId, "album-cover")
    }
}
