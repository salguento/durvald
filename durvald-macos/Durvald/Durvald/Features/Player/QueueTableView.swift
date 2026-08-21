import AppKit
import SwiftUI

struct QueueTableRow: Equatable {
    let trackID: Int64
    let position: UInt64
    let title: String
    let artist: String
}

/// Native macOS table used for queue actions and row reordering.
struct QueueTableView: NSViewRepresentable {
    let rows: [QueueTableRow]
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
        tableView.usesAlternatingRowBackgroundColors = true
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

            cell.titleLabel.stringValue = value.artist.isEmpty
                ? value.title
                : "\(value.title) — \(value.artist)"
            cell.playButton.tag = row
            cell.toolTip = "\(value.title), \(value.artist)"
            return cell
        }

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> NSPasteboardWriting? {
            guard rows.indices.contains(row) else { return nil }

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
            tableView.setDropRow(row, dropOperation: .above)
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

            let boundedInsertion = min(max(proposedRow, 0), rows.count)
            let destinationRow = min(
                boundedInsertion > sourceRow
                    ? boundedInsertion - 1
                    : boundedInsertion,
                rows.count - 1
            )

            guard destinationRow != sourceRow else { return false }

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
                  rows.indices.contains(tableView.clickedRow)
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
    let titleLabel = NSTextField(labelWithString: "")
    let playButton = NSButton(
        image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Reproduzir")!,
        target: nil,
        action: nil
    )

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        textField = titleLabel

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.isBordered = false
        playButton.setAccessibilityLabel("Reproduzir item da fila")

        addSubview(titleLabel)
        addSubview(playButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
