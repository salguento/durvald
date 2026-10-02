import AppKit

/// Reusable table controls without a SwiftUI hosting hierarchy per cell.
final class MusicLibraryNativeControlCell: NSTableCellView {
    enum Kind { case favorite, rating }
    private static let emptyStar = NSImage(systemSymbolName: "star", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize, weight: .regular))
    private static let filledStar = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize, weight: .regular))
    let kind: Kind
    let buttons: [NSButton]
    private var favorite = false
    private var rating: UInt8?
    private var selected = false
    private var onFavoriteChange: (Bool) -> Void = { _ in }
    private var onRatingChange: (UInt8?) -> Void = { _ in }

    init(identifier: NSUserInterfaceItemIdentifier, kind: Kind) {
        self.kind = kind
        buttons = (0..<(kind == .favorite ? 1 : 5)).map { _ in NSButton() }
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
                   onFavoriteChange: @escaping (Bool) -> Void,
                   onRatingChange: @escaping (UInt8?) -> Void) {
        favorite = track.isFavorite
        rating = track.rating
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
            let filled = kind == .favorite ? favorite : button.tag <= Int(rating ?? 0)
            button.image = filled ? Self.filledStar : Self.emptyStar
            button.contentTintColor = filled ? accent : .secondaryLabelColor
            button.setAccessibilityLabel(kind == .favorite
                ? (favorite ? "Desfavoritar faixa" : "Favoritar faixa") : "\(button.tag) de 5")
            button.setAccessibilityValue(kind == .favorite
                ? (favorite ? "Favorita" : "Não favorita") : (rating.map { "\($0) de 5" } ?? "Sem avaliação"))
            button.toolTip = kind == .favorite
                ? (favorite ? "Desfavoritar faixa" : "Favoritar faixa") : "Avaliação: \(button.tag) de 5"
        }
        updateHoverVisibility()
    }

    @objc private func activate(_ sender: NSButton) {
        if kind == .favorite {
            favorite.toggle()
            refreshButtons()
            onFavoriteChange(favorite)
        } else {
            let value = UInt8(sender.tag)
            rating = rating == value ? nil : value
            refreshButtons()
            onRatingChange(rating)
        }
    }
}

protocol MusicLibraryRowHoverProviding: AnyObject {
    var isHovered: Bool { get }
}
