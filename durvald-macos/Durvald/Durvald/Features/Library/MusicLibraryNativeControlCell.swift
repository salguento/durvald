import AppKit

/// Reusable table controls without a SwiftUI hosting hierarchy per cell.
final class MusicLibraryNativeControlCell: NSTableCellView {
    enum Kind { case favorite, rating }
    private static let emptyStar = NSImage(systemSymbolName: "star", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize, weight: .regular))
    private static let filledStar = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize, weight: .regular))
    private static let halfStar = NSImage(systemSymbolName: "star.leadinghalf.filled", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize, weight: .regular))
    let kind: Kind
    let buttons: [NSButton]
    private var favoriteEdit = PersonalValueEdit(false)
    private var ratingEdit = PersonalValueEdit<UInt8?>(nil)
    private var trackID: Int64?
    private var favorite: Bool { favoriteEdit.value }
    private var rating: UInt8? { ratingEdit.value }
    private var selected = false
    private var granularity: RatingGranularity = .halfStars
    private var ratingRevision: UInt64 = 0
    private var editable = true
    private var onFavoriteChange: (Bool) async -> Bool = { _ in true }
    private var onRatingChange: (UInt8?) async -> Bool = { _ in true }

    init(identifier: NSUserInterfaceItemIdentifier, kind: Kind) {
        self.kind = kind
        buttons = (0..<(kind == .favorite ? 1 : 5)).map { _ in kind == .favorite ? NSButton() : RatingStarButton() }
        super.init(frame: .zero)
        self.identifier = identifier
        for (index, button) in buttons.enumerated() {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.controlSize = .small
            button.tag = index + 1
            button.target = self
            button.action = #selector(activate(_:))
            addSubview(button)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(track: Track, selected: Bool,
                   granularity: RatingGranularity = .halfStars, editable: Bool = true, ratingRevision: UInt64 = 0,
                   onFavoriteChange: @escaping (Bool) async -> Bool,
                   onRatingChange: @escaping (UInt8?) async -> Bool) {
        if trackID != track.id || self.ratingRevision != ratingRevision {
            favoriteEdit.reset(track.isFavorite)
            ratingEdit.reset(track.ratingHalfSteps)
            trackID = track.id
        } else {
            favoriteEdit.receive(track.isFavorite)
            ratingEdit.receive(track.ratingHalfSteps)
        }
        self.granularity = granularity
        self.editable = editable
        self.ratingRevision = ratingRevision
        self.selected = selected
        self.onFavoriteChange = onFavoriteChange
        self.onRatingChange = onRatingChange
        setAccessibilityIdentifier("track.\(track.id).\(kind == .favorite ? "favorite" : "rating")")
        for button in buttons {
            button.setAccessibilityIdentifier("track.\(track.id).\(kind == .favorite ? "favorite" : "rating.\(button.tag)")")
        }
        refreshButtons()
    }

    override func layout() {
        super.layout()
        let size: CGFloat = kind == .favorite ? 24 : 18
        let gap: CGFloat = kind == .favorite ? 0 : 2
        let width = size * CGFloat(buttons.count) + gap * CGFloat(buttons.count - 1)
        let start = (bounds.width - width) / 2
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: start + CGFloat(index) * (size + gap),
                                  y: (bounds.height - size) / 2, width: size, height: size)
        }
    }

    func updateHoverVisibility() {
        // Row hover is supplied by the table; populated controls stay visible.
        let populated = kind == .favorite ? favorite : (rating ?? 0) > 0
        let hovered = enclosingRowIsHovered
        for button in buttons { button.isHidden = !populated && !hovered }
    }

    var enclosingRowIsHovered: Bool {
        (superview as? MusicLibraryRowHoverProviding)?.isHovered ?? false
    }

    private func refreshButtons() {
        let accent: NSColor = selected ? MusicLibrarySelectionStyle.accentForeground : .controlAccentColor
        for button in buttons {
            let filled = kind == .favorite ? favorite : button.tag * 2 - 1 <= Int(rating ?? 0)
            if kind == .favorite { button.image = filled ? Self.filledStar : Self.emptyStar }
            else {
                switch RatingValues.symbol(star: button.tag, rating: rating) {
                case "star.fill": button.image = Self.filledStar
                case "star.leadinghalf.filled": button.image = Self.halfStar
                default: button.image = Self.emptyStar
                }
            }
            if let star = button as? RatingStarButton {
                star.allowsHalfStars = granularity == .halfStars
            }
            button.isEnabled = kind == .favorite || editable
            button.contentTintColor = filled ? accent : .secondaryLabelColor
            button.setAccessibilityLabel(kind == .favorite
                ? PersonalValueLabels.favorite(favorite) : PersonalValueLabels.star(button.tag))
            button.setAccessibilityValue(kind == .favorite
                ? PersonalValueLabels.favoriteValue(favorite) : PersonalValueLabels.rating(rating))
            button.toolTip = kind == .favorite ? PersonalValueLabels.favorite(favorite)
                : "Avaliação: \(button.tag) de 5" + (granularity == .halfStars
                    ? ". Clique na metade esquerda para meia estrela. No teclado, use as setas esquerda e direita." : "")
        }
        updateHoverVisibility()
    }

    @objc private func activate(_ sender: NSButton) {
        if kind == .favorite {
            let value = !favorite
            let ticket = favoriteEdit.begin(value)
            refreshButtons()
            let commit = onFavoriteChange
            Task { @MainActor [weak self] in
                let succeeded = await commit(value)
                self?.favoriteEdit.finish(ticket, succeeded: succeeded)
                self?.refreshButtons()
            }
        } else {
            guard editable else { return }
            let requested = (sender as? RatingStarButton)?.requestedRating ?? UInt8(sender.tag * 2)
            let value = PersonalValueLabels.ratingAfterClick(requested, current: rating)
            let ticket = ratingEdit.begin(value)
            refreshButtons()
            let commit = onRatingChange
            Task { @MainActor [weak self] in
                let succeeded = await commit(value)
                self?.ratingEdit.finish(ticket, succeeded: succeeded)
                self?.refreshButtons()
            }
        }
    }
}

protocol MusicLibraryRowHoverProviding: AnyObject {
    var isHovered: Bool { get }
}

/// NSButton owns tracking and keyboard activation; only the half-star hit is custom.
final class RatingStarButton: NSButton {
    var allowsHalfStars = true
    private var halfHit = false
    var requestedRating: UInt8 { UInt8(tag * 2 - (allowsHalfStars && halfHit ? 1 : 0)) }

    override func mouseDown(with event: NSEvent) {
        halfHit = convert(event.locationInWindow, from: nil).x < bounds.midX
        super.mouseDown(with: event)
        halfHit = false
    }

    override func keyDown(with event: NSEvent) {
        if allowsHalfStars, event.keyCode == 123 || event.keyCode == 124 {
            halfHit = event.keyCode == 123
            performClick(nil)
            halfHit = false
        } else { super.keyDown(with: event) }
    }
}
