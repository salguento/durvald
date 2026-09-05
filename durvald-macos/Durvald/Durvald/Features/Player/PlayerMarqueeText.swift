import SwiftUI

/// Keeps the metadata's layout and click target fixed while revealing overflowing text.
struct PlayerMarqueeText: View {
    let text: String
    var underlined = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var textWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0
    @State private var cycleStart = Date.now
    @State private var pausedAt: Date?

    private let copySpacing: CGFloat = 32
    private let pointsPerSecond = 22.0
    private let cyclePause = 1.0

    private var shouldScroll: Bool {
        textWidth - availableWidth > 1 && availableWidth > 0
            && !reduceMotion && scenePhase == .active
    }

    private struct AnimationKey: Equatable {
        let text: String
        let textWidth: CGFloat
        let availableWidth: CGFloat
        let reduceMotion: Bool
        let isActive: Bool
    }

    var body: some View {
        // Reserve the normal single-line height. Only the overlay moves, so
        // long text cannot widen the player or shift its clickable area.
        Text(text)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if reduceMotion {
                    Text(text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .underline(underlined)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !shouldScroll || pausedAt != nil)) { context in
                        HStack(spacing: copySpacing) {
                            movingText
                                .onGeometryChange(for: CGFloat.self) { geometry in
                                    geometry.size.width
                                } action: { textWidth = $0 }

                            if shouldScroll {
                                movingText
                                    .accessibilityHidden(true)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: scrollingOffset(at: context.date))
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { availableWidth = $0 }
            .clipped()
            .mask {
                if shouldScroll {
                    let fadeWidth = min(12, availableWidth / 4)
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: fadeWidth)
                        Rectangle().fill(.black)
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: fadeWidth)
                    }
                } else {
                    Rectangle().fill(.black)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .onHover { isHovered in
                let now = Date.now
                if isHovered {
                    if pausedAt == nil { pausedAt = now }
                } else if let pauseStart = pausedAt {
                    // Exclude the hover duration so scrolling resumes at the same position.
                    cycleStart = cycleStart.addingTimeInterval(now.timeIntervalSince(pauseStart))
                    pausedAt = nil
                }
            }
            .onChange(of: AnimationKey(
                text: text,
                textWidth: textWidth,
                availableWidth: availableWidth,
                reduceMotion: reduceMotion,
                isActive: scenePhase == .active
            ), initial: true) { _, _ in
                cycleStart = .now
                if pausedAt != nil { pausedAt = cycleStart }
            }
    }

    private var movingText: some View {
        Text(text)
            .lineLimit(1)
            .underline(underlined)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func scrollingOffset(at date: Date) -> CGFloat {
        guard shouldScroll else { return 0 }
        let elapsed = max(0, (pausedAt ?? date).timeIntervalSince(cycleStart))
        let cycleWidth = Double(textWidth + copySpacing)
        let scrollingDuration = cycleWidth / pointsPerSecond
        let cycleDuration = cyclePause + scrollingDuration
        let cyclePosition = elapsed.truncatingRemainder(dividingBy: cycleDuration)

        // At the end of each pass, return the first copy to the leading edge
        // and hold it there before starting the next pass.
        guard cyclePosition >= cyclePause else { return 0 }
        let scrollingElapsed = cyclePosition - cyclePause

        // The second copy occupies the first copy's position at the wrap point,
        // making the reset visually seamless without reversing direction.
        return -CGFloat(scrollingElapsed * pointsPerSecond)
    }
}
