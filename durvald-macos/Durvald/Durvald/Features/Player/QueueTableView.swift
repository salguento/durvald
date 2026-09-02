import AppKit
import SwiftUI

struct QueueTableRow: Equatable {
    let trackID: Int64
    let position: UInt64
    let title: String
    let artist: String
    let artworkID: String?
    let isCurrent: Bool
    let isPaused: Bool
}

/// Native macOS table used for queue actions and row reordering.
struct QueueTableView: NSViewRepresentable {
    let rows: [QueueTableRow]
    let core: DurvaldCore?
    let isWindowActive: Bool
    let onMove: (UInt64, UInt64) -> Void
    let onPlay: (UInt64) -> Void
    let onTogglePlayback: () -> Void
    let onRemove: (UInt64) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        let column = NSTableColumn(identifier: Coordinator.columnIdentifier)
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.autoresizingMask = [.width]
        tableView.headerView = nil
        tableView.rowHeight = 46
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.registerForDraggedTypes([Coordinator.queuePasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        context.coordinator.tableView = tableView
        context.coordinator.rows = rows
        context.coordinator.isWindowActive = isWindowActive
        tableView.reloadData()

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        // The clip view is a separate drawing surface; keep the inspector's
        // native glass visible in the viewport, including empty/overscroll areas.
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.knobStyle = .default
        scrollView.documentView = tableView
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        let requiresReload = context.coordinator.rows != rows
            || context.coordinator.isWindowActive != isWindowActive

        guard requiresReload else { return }
        context.coordinator.rows = rows
        context.coordinator.isWindowActive = isWindowActive
        context.coordinator.tableView?.reloadData()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate,
        NSMenuDelegate {
        static let columnIdentifier = NSUserInterfaceItemIdentifier("queue.column")
        static let cellIdentifier = NSUserInterfaceItemIdentifier("queue.cell")
        static let queuePasteboardType = NSPasteboard.PasteboardType(
            "xyz.salguento.durvald.queue-row"
        )

        var parent: QueueTableView
        var rows: [QueueTableRow] = []
        var isWindowActive = true
        weak var tableView: NSTableView?

        init(parent: QueueTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let value = rows[row]

            let cell: QueueTableCellView
            if let reused = tableView.makeView(
                withIdentifier: Self.cellIdentifier,
                owner: nil
            ) as? QueueTableCellView {
                cell = reused
            } else {
                cell = QueueTableCellView(identifier: Self.cellIdentifier)
                cell.playButton.target = self
                cell.playButton.action = #selector(playQueueItem(_:))
            }

            cell.titleLabel.stringValue = value.title
            cell.artistLabel.stringValue = value.artist
            cell.artistLabel.isHidden = value.artist.isEmpty
            cell.loadArtwork(value.artworkID, using: parent.core)

            cell.titleLabel.textColor = value.isCurrent
                ? (isWindowActive ? .controlAccentColor : .secondaryLabelColor)
                : .labelColor

            let symbolName: String
            let actionLabel: String

            if value.isCurrent {
                symbolName = value.isPaused ? "play.fill" : "pause.fill"
                actionLabel = value.isPaused ? "Reproduzir" : "Pausar"
            } else {
                symbolName = "play.fill"
                actionLabel = "Reproduzir item da fila"
            }

            cell.playButton.tag = row
            cell.playButton.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: actionLabel
            )
            cell.playButton.isEnabled = true
            cell.playButton.setAccessibilityLabel(actionLabel)
            cell.playButton.setAccessibilityIdentifier(
                value.isCurrent
                    ? "queue.current.togglePlayback"
                    : "queue.item.\(value.position).play"
            )
            cell.playButton.setAccessibilityHelp(actionLabel)
            cell.configureHover()
            cell.toolTip = "\(value.title), \(value.artist)"
            return cell
        }

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> NSPasteboardWriting? {
            guard rows.indices.contains(row), rows[row].position > 0 else { return nil }

            let item = NSPasteboardItem()
            item.setString(String(row), forType: Self.queuePasteboardType)
            return item
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard sourceRow(from: info) != nil else { return [] }
            tableView.setDropRow(max(row, 1), dropOperation: .above)
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row proposedRow: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let sourceRow = sourceRow(from: info),
                  rows.indices.contains(sourceRow),
                  !rows.isEmpty
            else { return false }

            let boundedInsertion = min(max(proposedRow, 1), rows.count)
            let destinationRow = min(
                boundedInsertion > sourceRow
                    ? boundedInsertion - 1
                    : boundedInsertion,
                rows.count - 1
            )

            guard destinationRow != sourceRow,
                  rows[destinationRow].position > 0
            else { return false }

            let from = rows[sourceRow].position
            let to = rows[destinationRow].position
            let movedRow = rows.remove(at: sourceRow)
            rows.insert(movedRow, at: destinationRow)

            tableView.beginUpdates()
            tableView.moveRow(at: sourceRow, to: destinationRow)
            tableView.endUpdates()

            parent.onMove(from, to)
            return true
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView,
                  rows.indices.contains(tableView.clickedRow),
                  rows[tableView.clickedRow].position > 0
            else { return }

            let item = NSMenuItem(
                title: "Remover da fila",
                action: #selector(removeQueueItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = tableView.clickedRow
            menu.addItem(item)
        }

        @objc private func playQueueItem(_ sender: NSButton) {
            guard rows.indices.contains(sender.tag) else { return }
            let row = rows[sender.tag]

            if row.isCurrent {
                parent.onTogglePlayback()
            } else {
                parent.onPlay(row.position)
            }
        }

        @objc private func removeQueueItem(_ sender: NSMenuItem) {
            guard let row = sender.representedObject as? Int,
                  rows.indices.contains(row)
            else { return }
            parent.onRemove(rows[row].position)
        }

        private func sourceRow(from info: NSDraggingInfo) -> Int? {
            guard info.draggingSource as? NSTableView === tableView,
                  let rawValue = info.draggingPasteboard.string(
                      forType: Self.queuePasteboardType
                  )
            else { return nil }
            return Int(rawValue)
        }
    }
}

private final class QueueTableCellView: NSTableCellView {
    private static let placeholderImage = NSImage(
        systemSymbolName: "music.note",
        accessibilityDescription: nil
    )

    let artworkImageView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let artistLabel = NSTextField(labelWithString: "")
    let playButton = NSButton(
        image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Reproduzir")!,
        target: nil,
        action: nil
    )

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        artworkImageView.imageScaling = .scaleProportionallyUpOrDown
        artworkImageView.image = Self.placeholderImage
        artworkImageView.wantsLayer = true
        artworkImageView.layer?.cornerRadius = 4
        artworkImageView.layer?.masksToBounds = true
        artworkImageView.setAccessibilityHidden(true)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = titleLabel

        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        artistLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, artistLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.distribution = .fill
        textStack.spacing = 1

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.isBordered = false
        playButton.imagePosition = .imageOnly
        playButton.contentTintColor = .white
        playButton.wantsLayer = true
        playButton.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(0.18)
            .cgColor
        playButton.layer?.cornerRadius = 4
        playButton.layer?.masksToBounds = true
        playButton.setAccessibilityLabel("Reproduzir item da fila")

        addSubview(artworkImageView)
        addSubview(textStack)
        addSubview(playButton)

        NSLayoutConstraint.activate([
            artworkImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            artworkImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            artworkImageView.widthAnchor.constraint(equalToConstant: 36),
            artworkImageView.heightAnchor.constraint(equalToConstant: 36),
            textStack.leadingAnchor.constraint(equalTo: artworkImageView.trailingAnchor, constant: 8),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.centerXAnchor.constraint(equalTo: artworkImageView.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: artworkImageView.centerYAnchor),
            playButton.widthAnchor.constraint(equalTo: artworkImageView.widthAnchor),
            playButton.heightAnchor.constraint(equalTo: artworkImageView.heightAnchor),
        ])
    }

    private var isPointerInside = false
    private var isRowSelected = false
    private var hoverTrackingArea: NSTrackingArea?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            isRowSelected = backgroundStyle == .emphasized
            updateHoverAppearance()
        }
    }

    func configureHover() {
        isPointerInside = false
        updateHoverAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let newTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeInKeyWindow,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        hoverTrackingArea = newTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateHoverAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateHoverAppearance()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isPointerInside = false
        isRowSelected = false
        updateHoverAppearance()
    }

    private func updateHoverAppearance() {
        let showsControl = isPointerInside || isRowSelected
        playButton.isHidden = !showsControl
        artworkImageView.alphaValue = 1
    }

    func loadArtwork(_ artworkID: String?, using core: DurvaldCore?) {
        artworkTask?.cancel()
        representedArtworkID = artworkID
        artworkImageView.image = Self.placeholderImage

        guard let artworkID, let core else { return }

        if let cached = ArtworkRepository.shared.cachedImage(for: artworkID) {
            artworkImageView.image = cached
            return
        }

        artworkTask = Task { @MainActor [weak self] in
            let image = try? await ArtworkRepository.shared.image(
                for: artworkID,
                using: core
            )

            guard !Task.isCancelled,
                  self?.representedArtworkID == artworkID
            else { return }

            self?.artworkImageView.image = image ?? Self.placeholderImage
        }
    }

    private var representedArtworkID: String?
    private var artworkTask: Task<Void, Never>?

    deinit {
        artworkTask?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
