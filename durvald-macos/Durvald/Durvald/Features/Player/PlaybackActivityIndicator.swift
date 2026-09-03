import AppKit
import QuartzCore
import SwiftUI

/// Animate only the indicator's layers, without a repeating SwiftUI symbol effect
/// participating in the album's view updates and playback observations.
struct PlaybackActivityIndicator: NSViewRepresentable {
    let isAnimating: Bool
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> PlaybackActivityView {
        PlaybackActivityView(frame: .zero)
    }

    func updateNSView(_ view: PlaybackActivityView, context: Context) {
        let accent = Color.accentColor.resolve(in: environment)
        view.configure(
            color: NSColor(srgbRed: CGFloat(accent.red), green: CGFloat(accent.green),
                           blue: CGFloat(accent.blue), alpha: CGFloat(accent.opacity)),
            isAnimating: isAnimating
        )
    }

    static func dismantleNSView(_ view: PlaybackActivityView, coordinator: ()) {
        view.stopAnimating()
    }
}

final class PlaybackActivityView: NSView {
    private let bars = (0..<3).map { _ in CALayer() }
    private let restingScales: [CGFloat] = [0.45, 0.8, 0.6]
    private var shouldAnimate = false
    private let animationKey = "playback.level"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for (index, bar) in bars.enumerated() {
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.cornerRadius = 1.25
            bar.transform = CATransform3DMakeScale(1, restingScales[index], 1)
            layer?.addSublayer(bar)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
            bar.position = CGPoint(x: bounds.midX + CGFloat(index - 1) * 5, y: 0)
        }
        CATransaction.commit()
    }

    func configure(color: NSColor, isAnimating: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars { bar.backgroundColor = color.cgColor }
        CATransaction.commit()
        shouldAnimate = isAnimating
        updateAnimations()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimations()
    }

    func stopAnimating() {
        shouldAnimate = false
        updateAnimations()
    }

    private func updateAnimations() {
        for (index, bar) in bars.enumerated() {
            guard shouldAnimate, window != nil else {
                bar.removeAnimation(forKey: animationKey)
                continue
            }
            // Model publications must not restart an animation already running.
            guard bar.animation(forKey: animationKey) == nil else { continue }
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = [0.2, 0.35, 0.25][index]
            animation.toValue = [0.85, 1.0, 0.9][index]
            animation.duration = [0.42, 0.57, 0.49][index]
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(animation, forKey: animationKey)
        }
    }
}
