import AppKit

/// Reusable table controls without a SwiftUI hosting hierarchy per cell.
final class MusicLibraryNativeControlCell: NSTableCellView {
    enum Kind { case favorite, rating }
    private static let emptyStar = NSImage(systemSymbolName: "star", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize, weight: .regular))
    private static let filledStar = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize, weight: .regular))
    let kind: Kind
    let buttons: [NSButton]
    private var favoriteEdit = PersonalValueEdit(false)
    private var ratingEdit = PersonalValueEdit<UInt8?>(nil)
    private var trackID: Int64?
    private var favorite: Bool { favoriteEdit.value }
    private var rating: UInt8? { ratingEdit.value }
    private var selected = false
    private var onFavoriteChange: (Bool) async -> Bool = { _ in true }
    private var onRatingChange: (UInt8?) async -> Bool = { _ in true }

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
                   onFavoriteChange: @escaping (Bool) async -> Bool,
                   onRatingChange: @escaping (UInt8?) async -> Bool) {
        if trackID != track.id {
            favoriteEdit.reset(track.isFavorite)
            ratingEdit.reset(track.rating)
            trackID = track.id
        } else {
            favoriteEdit.receive(track.isFavorite)
            ratingEdit.receive(track.rating)
        }
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
                ? PersonalValueLabels.favorite(favorite) : PersonalValueLabels.star(button.tag))
            button.setAccessibilityValue(kind == .favorite
                ? PersonalValueLabels.favoriteValue(favorite) : PersonalValueLabels.rating(rating))
            button.toolTip = kind == .favorite
                ? PersonalValueLabels.favorite(favorite) : "Avaliação: \(button.tag) de 5"
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
            let value = PersonalValueLabels.ratingAfterClick(UInt8(sender.tag), current: rating)
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
