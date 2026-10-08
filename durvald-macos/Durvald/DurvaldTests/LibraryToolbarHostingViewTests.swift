import AppKit
import SwiftUI
import XCTest
@testable import Durvald

@MainActor
final class LibraryToolbarHostingViewTests: XCTestCase {
    func testRepeatedFrameBoundsAndLayoutDoNotForceAnotherSubtreePass() {
        let canvas = CountingToolbarCanvas(rootView: Text("Biblioteca"))
        let host = LibraryToolbarHostingView(hostingView: canvas)
        host.setFrameSize(NSSize(width: 600, height: 36))
        let initialPasses = canvas.forcedFrames.count

        for _ in 0..<100 {
            host.setFrameSize(host.frame.size)
            host.setBoundsSize(host.bounds.size)
            host.layout()
        }

        XCTAssertEqual(canvas.forcedFrames.count, initialPasses)
        XCTAssertEqual(canvas.frame, host.bounds)
    }

    func testCompactExpandedAndBoundsChangesSynchronizeBeforeReturning() {
        let canvas = CountingToolbarCanvas(rootView: Text("Biblioteca"))
        let host = LibraryToolbarHostingView(hostingView: canvas)
        host.setFrameSize(NSSize(width: 600, height: 36))
        canvas.forcedFrames.removeAll()

        for width: CGFloat in [320, 600, 320] {
            host.setFrameSize(NSSize(width: width, height: 36))
            XCTAssertEqual(canvas.frame, host.bounds)
            XCTAssertEqual(canvas.forcedFrames.last, host.bounds)
            host.layout()
        }
        XCTAssertEqual(canvas.forcedFrames.count, 3)

        host.setBoundsSize(NSSize(width: 280, height: 36))
        XCTAssertEqual(canvas.frame, host.bounds)
        XCTAssertEqual(canvas.forcedFrames.count, 4)
        host.setBoundsOrigin(NSPoint(x: 4, y: 2))
        host.layout()
        XCTAssertEqual(canvas.frame, host.bounds)
        XCTAssertEqual(canvas.forcedFrames.last, host.bounds)
        XCTAssertEqual(canvas.forcedFrames.count, 5)
    }

    func testDirtyContentStillReceivesNormalLayoutAtUnchangedSize() {
        let canvas = CountingToolbarCanvas(rootView: Text("Antes"))
        let host = LibraryToolbarHostingView(hostingView: canvas)
        host.setFrameSize(NSSize(width: 600, height: 36))
        let previousLayouts = canvas.layoutPasses
        canvas.rootView = Text("Conteúdo atualizado")
        canvas.needsLayout = true
        host.needsLayout = true

        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(canvas.layoutPasses, previousLayouts)
        XCTAssertFalse(canvas.needsLayout)
        XCTAssertEqual(canvas.frame, host.bounds)
    }

    func testResizeSequenceForcesOnlyOnePassPerChangedCanvas() {
        let canvas = CountingToolbarCanvas(rootView: Text("Biblioteca"))
        let host = LibraryToolbarHostingView(hostingView: canvas)
        host.setFrameSize(NSSize(width: 600, height: 36))
        canvas.forcedFrames.removeAll()

        for width in stride(from: 598, through: 400, by: -2) {
            host.setFrameSize(NSSize(width: width, height: 36))
            host.setBoundsSize(host.bounds.size)
            host.layout()
            host.layout()
            XCTAssertEqual(canvas.frame, host.bounds)
        }

        XCTAssertEqual(canvas.forcedFrames.count, 100)
        XCTAssertEqual(canvas.forcedFrames.last?.width, 400)
        XCTAssertEqual(canvas.forcedFrames.last?.height, 36)
    }
}

@MainActor
private final class CountingToolbarCanvas: NSHostingView<Text> {
    var forcedFrames: [NSRect] = []
    var layoutPasses = 0

    override func layoutSubtreeIfNeeded() {
        forcedFrames.append(frame)
        super.layoutSubtreeIfNeeded()
    }

    override func layout() {
        layoutPasses += 1
        super.layout()
    }
}
