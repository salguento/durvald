import AppKit
import SwiftUI

struct QueueTableRow: Equatable {
    let trackID: Int64
    let position: UInt64
    let title: String
    let artist: String
    let artworkID: String?
}

/// Native macOS table used for queue actions and row reordering.
struct QueueTableView: NSViewRepresentable {
    let rows: [QueueTableRow]
    let core: DurvaldCore?
    let onMove: (UInt64, UInt64) -> Void
    let onPlay: (UInt64) -> Void
    let onRemove: (UInt64) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        let column = NSTableColumn(identifier: Coordinator.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 46
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
        tableView.reloadData()

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard context.coordinator.rows != rows else { return }
        context.coordinator.rows = rows
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
            cell.playButton.tag = row
            cell.playButton.image = NSImage(
                systemSymbolName: value.position == 0
                    ? "speaker.wave.2.fill"
                    : "play.fill",
                accessibilityDescription: value.position == 0
                    ? "Tocando agora"
                    : "Reproduzir item da fila"
            )
            cell.playButton.isEnabled = value.position != 0
            cell.playButton.setAccessibilityLabel(
                value.position == 0 ? "Tocando agora" : "Reproduzir item da fila"
            )
            cell.playButton.setAccessibilityIdentifier(
                value.position == 0
                    ? "queue.current"
                    : "queue.item.\(value.position).play"
            )
            cell.playButton.setAccessibilityHelp(
                value.position == 0
                    ? "Indica a faixa reproduzida atualmente"
                    : "Reproduz este item da fila agora"
            )
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
            parent.onPlay(rows[sender.tag].position)
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
        textField = titleLabel

        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        artistLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, artistLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.distribution = .fill
        textStack.spacing = 1

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.isBordered = false
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
            textStack.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
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
