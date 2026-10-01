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
    let topContentInset: CGFloat
    let onDropTracks: ([Int64], UInt64) -> Void
    let onMove: (UInt64, UInt64) -> Void
    let onPlay: (UInt64) -> Void
    let onTogglePlayback: () -> Void
    let onRemove: (UInt64) -> Void
    let onInfo: (Int64) -> Void
    let onClear: () -> Void
    let configureMenu: (TrackMenuController, Int64) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = QueueDropTableView()
        let column = NSTableColumn(identifier: Coordinator.columnIdentifier)
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.autoresizingMask = [.width]
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.rowHeight = 46
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.playDoubleClickedRow(_:))
        tableView.registerForDraggedTypes([Coordinator.queuePasteboardType, LibraryTrackDrag.pasteboardType])
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
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: topContentInset,
            left: 0,
            bottom: 0,
            right: 0
        )
        scrollView.documentView = tableView
        scrollView.borderType = .noBorder
        scrollView.contentView.scroll(
            to: NSPoint(x: 0, y: -topContentInset)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        scrollView.contentInsets.top = topContentInset

        let requiresReload = context.coordinator.rows != rows
            || context.coordinator.isWindowActive != isWindowActive

        guard requiresReload else { return }
        context.coordinator.rows = rows
        context.coordinator.isWindowActive = isWindowActive
        context.coordinator.tableView?.reloadData()
    }

    @MainActor
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

        @objc private func clearQueue(_ sender: NSButton) {
            parent.onClear()
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if rows[row].isCurrent { return 70 }
            if row == rows.firstIndex(where: { !$0.isCurrent }) {
                return row > 0 ? 80 : 70
            }
            return 46
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
                cell.clearButton.target = self
                cell.clearButton.action = #selector(clearQueue(_:))
            }

            cell.titleLabel.stringValue = value.title
            let isFirstUpcoming = row == rows.firstIndex(where: { !$0.isCurrent })
            cell.clearButton.isHidden = !isFirstUpcoming
            cell.configureSectionHeader(
                value.isCurrent ? "Tocando agora" : (isFirstUpcoming ? "Próximo na fila" : nil),
                topSpacing: isFirstUpcoming && row > 0 ? 14 : 4,
                accessibilityIdentifier: value.isCurrent ? "queue.nowPlaying" : "queue.upNext"
            )
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
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forRowIndexes rowIndexes: IndexSet
        ) {
            guard let row = rowIndexes.first, rows.indices.contains(row) else { return }
            let preview = dragPreviewImage(for: row, in: tableView)

            session.draggingFormation = .none
            session.enumerateDraggingItems(
                options: [],
                for: tableView,
                classes: [NSPasteboardItem.self],
                searchOptions: [:]
            ) { draggingItem, _, _ in
                let currentFrame = draggingItem.draggingFrame
                let previewFrame = NSRect(
                    x: currentFrame.midX - preview.size.width / 2,
                    y: currentFrame.midY - preview.size.height / 2,
                    width: preview.size.width,
                    height: preview.size.height
                )
                draggingItem.setDraggingFrame(previewFrame, contents: preview)
            }
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            (tableView as? QueueDropTableView)?.firstUpcomingRow = rows.firstIndex(where: { !$0.isCurrent })
            if !LibraryTrackDrag.ids(from: info.draggingPasteboard).isEmpty {
                tableView.setDropRow(max(row, rows.isEmpty ? 0 : 1), dropOperation: .above)
                return .copy
            }
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
            let ids = LibraryTrackDrag.ids(from: info.draggingPasteboard)
            if !ids.isEmpty {
                let insertion = min(max(proposedRow, rows.isEmpty ? 0 : 1), rows.count)
                parent.onDropTracks(ids, UInt64(insertion))
                return true
            }
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

        private let trackMenuController = TrackMenuController()

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView,
                  rows.indices.contains(tableView.clickedRow)
            else { return }

            trackMenuController.rootMenu = menu
            if !parent.configureMenu(trackMenuController, rows[tableView.clickedRow].trackID) {
                let info = NSMenuItem(title: "Info", action: #selector(showInfo(_:)), keyEquivalent: "")
                info.target = self
                info.representedObject = tableView.clickedRow
                menu.addItem(info)
            }
            let item = NSMenuItem(
                title: "Remover da fila",
                action: #selector(removeQueueItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = tableView.clickedRow
            item.isEnabled = rows[tableView.clickedRow].position > 0
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }

        func menuWillOpen(_ menu: NSMenu) {
            trackMenuController.menuWillOpen(menu)
        }

        func menuDidClose(_ menu: NSMenu) {
            trackMenuController.menuDidClose(menu)
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

        @objc func playDoubleClickedRow(_ sender: NSTableView) {
            guard rows.indices.contains(sender.clickedRow) else { return }
            let row = rows[sender.clickedRow]

            if row.isCurrent {
                if row.isPaused { parent.onTogglePlayback() }
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

        @objc private func showInfo(_ sender: NSMenuItem) {
            guard let row = sender.representedObject as? Int, rows.indices.contains(row) else { return }
            parent.onInfo(rows[row].trackID)
        }

        private func sourceRow(from info: NSDraggingInfo) -> Int? {
            guard info.draggingSource as? NSTableView === tableView,
                  let rawValue = info.draggingPasteboard.string(
                      forType: Self.queuePasteboardType
                  )
            else { return nil }
            return Int(rawValue)
        }

        private func dragPreviewImage(for row: Int, in tableView: NSTableView) -> NSImage {
            let value = rows[row]
            let previewSize = NSSize(width: 260, height: 54)
            let artwork = (tableView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
            ) as? QueueTableCellView)?.artworkImageView.image

            return NSImage(size: previewSize, flipped: false) { bounds in
                let cardBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
                let card = NSBezierPath(
                    roundedRect: cardBounds,
                    xRadius: 8,
                    yRadius: 8
                )
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                card.fill()
                NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
                card.lineWidth = 1
                card.stroke()

                let artworkRect = NSRect(x: 8, y: 8, width: 38, height: 38)
                artwork?.draw(
                    in: artworkRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil
                )

                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                let textWidth = previewSize.width - 64
                let titleY: CGFloat = value.artist.isEmpty ? 18 : 28
                (value.title as NSString).draw(
                    in: NSRect(x: 56, y: titleY, width: textWidth, height: 18),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: paragraph,
                    ]
                )

                if !value.artist.isEmpty {
                    (value.artist as NSString).draw(
                        in: NSRect(x: 56, y: 10, width: textWidth, height: 16),
                        withAttributes: [
                            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .paragraphStyle: paragraph,
                        ]
                    )
                }
                return true
            }
        }
    }
}

private final class QueueTableCellView: NSTableCellView {
    private static let placeholderImage = NSImage(
        systemSymbolName: "music.note",
        accessibilityDescription: nil
    )

    let artworkImageView = NSImageView()
    let clearButton = NSButton(title: "Limpar", target: nil, action: nil)
    private let nowPlayingLabel = NSTextField(labelWithString: "Tocando agora")
    private var artworkTopConstraint: NSLayoutConstraint!
    private var sectionHeaderTopConstraint: NSLayoutConstraint!
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

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.isBordered = false
        clearButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.isHidden = true
        clearButton.setAccessibilityIdentifier("queue.clear")

        nowPlayingLabel.translatesAutoresizingMaskIntoConstraints = false
        nowPlayingLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        nowPlayingLabel.textColor = .secondaryLabelColor
        nowPlayingLabel.isHidden = true
        nowPlayingLabel.setAccessibilityIdentifier("queue.nowPlaying")

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
        addSubview(nowPlayingLabel)
        addSubview(clearButton)
        addSubview(textStack)
        addSubview(playButton)

        artworkTopConstraint = artworkImageView.topAnchor.constraint(equalTo: topAnchor, constant: 5)
        sectionHeaderTopConstraint = nowPlayingLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4)
        NSLayoutConstraint.activate([
            nowPlayingLabel.leadingAnchor.constraint(equalTo: artworkImageView.leadingAnchor),
            sectionHeaderTopConstraint,
            nowPlayingLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            nowPlayingLabel.heightAnchor.constraint(equalToConstant: 16),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: nowPlayingLabel.centerYAnchor),
            nowPlayingLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -8),
            artworkImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            artworkTopConstraint,
            artworkImageView.widthAnchor.constraint(equalToConstant: 36),
            artworkImageView.heightAnchor.constraint(equalToConstant: 36),
            textStack.leadingAnchor.constraint(equalTo: artworkImageView.trailingAnchor, constant: 8),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            textStack.centerYAnchor.constraint(equalTo: artworkImageView.centerYAnchor),
            playButton.centerXAnchor.constraint(equalTo: artworkImageView.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: artworkImageView.centerYAnchor),
            playButton.widthAnchor.constraint(equalTo: artworkImageView.widthAnchor),
            playButton.heightAnchor.constraint(equalTo: artworkImageView.heightAnchor),
        ])
    }

    func configureSectionHeader(_ title: String?, topSpacing: CGFloat, accessibilityIdentifier: String) {
        nowPlayingLabel.isHidden = title == nil
        nowPlayingLabel.stringValue = title ?? ""
        nowPlayingLabel.setAccessibilityIdentifier(accessibilityIdentifier)
        sectionHeaderTopConstraint.constant = topSpacing
        artworkTopConstraint.constant = title == nil ? 5 : topSpacing + 24
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

        // AppKit keeps an inVisibleRect area aligned during scrolling; avoid
        // reallocating a tracking area for every visible cell on every frame.
        guard hoverTrackingArea == nil else { return }

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
        artworkTask?.cancel()
        artworkTask = nil
        representedArtworkID = nil
        artworkImageView.image = Self.placeholderImage
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

        let pixelSize = ArtworkRepository.pixelSize(for: 36, scale: window?.backingScaleFactor ?? 2)
        if let cached = ArtworkRepository.shared.cachedImage(for: artworkID, pixelSize: pixelSize, using: core) {
            artworkImageView.image = cached
            return
        }

        artworkTask = Task { @MainActor [weak self] in
            let image = try? await ArtworkRepository.shared.image(
                for: artworkID,
                pixelSize: pixelSize,
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

private final class QueueDropTableView: NSTableView {
    var firstUpcomingRow: Int?
    private let insertionLine = NSView()

    override func setDropRow(_ row: Int, dropOperation: NSTableView.DropOperation) {
        insertionLine.removeFromSuperview()
        guard row == firstUpcomingRow, row > 0, dropOperation == .above else {
            draggingDestinationFeedbackStyle = .regular
            super.setDropRow(row, dropOperation: dropOperation)
            return
        }
        draggingDestinationFeedbackStyle = .none
        super.setDropRow(row, dropOperation: dropOperation)
        insertionLine.wantsLayer = true
        insertionLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        let rowRect = rect(ofRow: row)
        insertionLine.frame = NSRect(x: bounds.minX, y: rowRect.minY + 34,
                                     width: bounds.width, height: 2)
        addSubview(insertionLine)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        insertionLine.removeFromSuperview()
        super.draggingExited(sender)
        draggingDestinationFeedbackStyle = .regular
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            insertionLine.removeFromSuperview()
            draggingDestinationFeedbackStyle = .regular
        }
        return super.performDragOperation(sender)
    }
}
