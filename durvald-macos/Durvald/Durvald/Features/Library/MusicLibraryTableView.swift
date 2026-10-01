import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MusicLibraryColumn: String, CaseIterable, Identifiable, Codable {
    case artwork, title, duration, artist, album, favorite, plays, rating, actions
    case trackNumber, discNumber, lastPlayed, bitrate, sampleRate, kind, size

    var id: Self { self }

    var label: String {
        switch self {
        case .artwork: "Capa"
        case .title: "Título"
        case .duration: "Tempo"
        case .artist: "Artista"
        case .album: "Álbum"
        case .favorite: "Favorito"
        case .plays: "Reproduções"
        case .rating: "Avaliação"
        case .actions: "Ações"
        case .trackNumber: "Número da faixa"
        case .discNumber: "Número do disco"
        case .lastPlayed: "Última reprodução"
        case .bitrate: "Taxa de bits"
        case .sampleRate: "Taxa de amostragem"
        case .kind: "Tipo"
        case .size: "Tamanho"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .artwork: 58
        case .title: 240
        case .duration: 75
        case .artist, .album: 170
        case .favorite: 65
        case .plays: 110
        case .rating: 130
        case .actions: 72
        case .trackNumber, .discNumber, .bitrate, .sampleRate, .kind, .size: 110
        case .lastPlayed: 170
        }
    }

    var isResizable: Bool {
        switch self {
        case .artwork, .favorite, .rating, .actions: false
        default: true
        }
    }

    var alignment: Alignment {
        if self == .trackNumber { return .center }
        if self == .duration || self == .plays { return .trailing }
        return isResizable ? .leading : .center
    }

    var minimumWidth: CGFloat {
        switch self {
        case .artwork, .favorite: 48
        case .rating: 120
        default: 65
        }
    }

    var minimumRowHeight: CGFloat {
        self == .artwork ? 50 : 32
    }
}

struct MusicLibraryColumnLayout: Codable, Equatable {
    var order = MusicLibraryColumn.allCases
    var hidden: Set<MusicLibraryColumn> = [.discNumber, .lastPlayed, .bitrate, .sampleRate, .kind, .size]
    var widths: [String: Double] = [:]
}

/// AppKit owns column layout, cursor handling, scrolling and row selection.
struct MusicLibraryTableView: NSViewRepresentable {
    let tracks: [Track]
    @Binding var selection: Set<Int64>
    let savedScrollOffset: Binding<CGFloat>
    let layout: MusicLibraryColumnLayout
    let ratingsEnabled: Bool
    let artworkSize: Double
    let groupArtwork: Bool
    let activeTrackID: Int64?
    let onLayoutChange: (MusicLibraryColumnLayout) -> Void
    let onPlay: (Track) -> Void
    let onLoadMore: (Int64) -> Void
    let configureMenu: (TrackMenuController, Track) -> Void
    let cellContent: (Track, MusicLibraryColumn) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let background = NSVisualEffectView()
        background.wantsLayer = true
        background.layer?.masksToBounds = true
        background.material = .contentBackground
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState

        let table = MusicLibraryNativeTableView()
        table.focusRingType = .none
        table.style = .fullWidth
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.autoresizingMask = []
        table.allowsColumnResizing = true
        table.allowsColumnReordering = true
        table.allowsMultipleSelection = true
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.verticalMotionCanBeginDrag = true
        table.allowsEmptySelection = true
        table.allowsColumnSelection = false
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = true
        table.headerView = MusicLibraryHeaderView(frame: table.headerView?.frame ?? .zero)
        table.setAccessibilityIdentifier("library.musicTable")
        table.headerView?.setAccessibilityIdentifier("library.tableHeader")
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.playDoubleClickedRow(_:))

        for value in MusicLibraryColumn.allCases where value != .actions {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(value.rawValue))
            column.title = value.label
            column.headerCell = MusicLibraryHeaderCell(textCell: value == .trackNumber ? "#" : (value == .favorite || value == .actions || value == .artwork ? "" : value.label))
            column.headerCell.alignment = value.textAlignment
            column.headerCell.setAccessibilityLabel(value.label)
            if value == .favorite {
                (column.headerCell as? MusicLibraryHeaderCell)?.symbol = NSImage(
                    systemSymbolName: "star", accessibilityDescription: value.label
                )?.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
            }
            column.minWidth = value.isResizable ? value.minimumWidth : value.defaultWidth
            column.maxWidth = value.isResizable ? 10_000 : value.defaultWidth
            column.width = value.defaultWidth
            column.resizingMask = value.isResizable ? .userResizingMask : []
            table.addTableColumn(column)
        }

        let coordinator = context.coordinator
        coordinator.tableView = table
        coordinator.applyLayout()
        table.menu = coordinator.trackMenu
        table.headerView?.menu = coordinator.headerMenu

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.masksToBounds = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        coordinator.scrollView = scrollView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: background.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.clipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        coordinator.updateRows()
        coordinator.restoreScrollPositionIfNeeded()
        return background
    }

    func updateNSView(_ background: NSVisualEffectView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyLayout()
        context.coordinator.updateRows()
        context.coordinator.restoreScrollPositionIfNeeded()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ background: NSVisualEffectView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.scrollView?.documentView = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: MusicLibraryTableView
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?
        private var rows: [Track] = []
        private var activeTrackID: Int64?
        private var appliedSelection = Set<Int64>()
        private var appliedLayout: MusicLibraryColumnLayout?
        private var appliedRatingsEnabled: Bool?
        private var appliedArtworkSize: Double?
        private var appliedGroupArtwork: Bool?
        private var albumGroups: [Range<Int>] = []
        private var groupViews: [NSView] = []
        private var albumGroupsNeedLayout = true
        private var lastAlbumVisibleRect: NSRect?
        private var displayRows: [Track?] = []
        private var groupHeightSize: Double?
        private var groupedHeightActive = false
        private var appliedRowHeight: CGFloat?
        private var isUpdating = false
        private var didRestoreScroll = false
        private var isRestoringScroll = false
        private var pendingScrollUpdate = false
        private var prefetchedVisibleTrackIDs = Set<Int64>()
        private let trackMenuController = TrackMenuController()
        let trackMenu = NSMenu()
        let headerMenu = NSMenu()

        init(parent: MusicLibraryTableView) {
            self.parent = parent
            super.init()
            trackMenu.delegate = self
            trackMenu.autoenablesItems = false
            headerMenu.delegate = self
            headerMenu.autoenablesItems = false
        }

        func applyLayout() {
            guard let tableView,
                  appliedLayout != parent.layout || appliedRatingsEnabled != parent.ratingsEnabled || appliedArtworkSize != parent.artworkSize || appliedGroupArtwork != parent.groupArtwork else { return }
            isUpdating = true
            defer { isUpdating = false }
            let order = parent.layout.order.filter { $0 != .actions }
            for (index, value) in order.enumerated() {
                let currentIndex = tableView.column(withIdentifier: .init(value.rawValue))
                if currentIndex != index { tableView.moveColumn(currentIndex, toColumn: index) }
                guard let column = tableView.tableColumn(withIdentifier: .init(value.rawValue)) else { continue }
                column.isHidden = value != .title && value != .actions && (
                    parent.layout.hidden.contains(value) || (value == .rating && !parent.ratingsEnabled)
                )
                if value == .artwork {
                    column.headerCell.alignment = parent.groupArtwork ? .left : value.textAlignment
                    column.headerCell.stringValue = parent.groupArtwork ? "Álbum por artista" : ""
                    column.headerCell.setAccessibilityLabel(parent.groupArtwork ? "Álbum por artista" : value.label)
                    let width = CGFloat(parent.artworkSize + 24 + (parent.groupArtwork ? 200 : 0))
                    // Release the previous fixed limits before changing modes.
                    column.minWidth = 0
                    column.maxWidth = 10_000
                    column.width = width
                    column.minWidth = width
                    column.maxWidth = width
                }
                let width = value.isResizable
                    ? CGFloat(parent.layout.widths[value.rawValue] ?? Double(value.defaultWidth))
                    : value.defaultWidth
                column.width = min(column.maxWidth, max(column.minWidth, width))
            }
            tableView.rowHeight = tableView.tableColumns
                .filter { !$0.isHidden }
                .compactMap { MusicLibraryColumn(rawValue: $0.identifier.rawValue)?.minimumRowHeight }
                .max() ?? 32
            if !parent.layout.hidden.contains(.artwork) {
                tableView.rowHeight = CGFloat(parent.artworkSize + 16)
            }
            if parent.groupArtwork && !parent.layout.hidden.contains(.artwork) {
                tableView.rowHeight = 32
            }
            albumGroupsNeedLayout = true
            tableView.headerView?.needsDisplay = true
            appliedGroupArtwork = parent.groupArtwork
            appliedArtworkSize = parent.artworkSize
            appliedLayout = parent.layout
            appliedRatingsEnabled = parent.ratingsEnabled
        }

        func updateRows() {
            guard let tableView else { return }
            isUpdating = true
            defer { isUpdating = false }
            if rows != parent.tracks || activeTrackID != parent.activeTrackID
                || groupHeightSize != parent.artworkSize
                || groupedHeightActive != (parent.groupArtwork && !parent.layout.hidden.contains(.artwork))
                || (groupViews.isEmpty && parent.groupArtwork && !parent.layout.hidden.contains(.artwork))
                || (!groupViews.isEmpty && (!parent.groupArtwork || parent.layout.hidden.contains(.artwork))) {
                rows = parent.tracks
                activeTrackID = parent.activeTrackID
                prefetchedVisibleTrackIDs.removeAll()
                groupViews.forEach { $0.removeFromSuperview() }
                groupViews.removeAll()
                rebuildAlbumGroups()
                albumGroupsNeedLayout = true
                groupHeightSize = nil
                tableView.reloadData()
            }
            let changedSelection = appliedSelection.symmetricDifference(parent.selection)
            if !changedSelection.isEmpty {
                let changedRows = IndexSet(displayRows.indices.filter { displayRows[$0].map { changedSelection.contains($0.id) } ?? false })
                tableView.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
            }
            appliedSelection = parent.selection
            let indices = IndexSet(displayRows.indices.filter { displayRows[$0].map { parent.selection.contains($0.id) } ?? false })
            if indices != tableView.selectedRowIndexes {
                tableView.selectRowIndexes(indices, byExtendingSelection: false)
            }
            let grouped = parent.groupArtwork && !parent.layout.hidden.contains(.artwork)
            if groupHeightSize != parent.artworkSize || groupedHeightActive != grouped
                || appliedRowHeight != tableView.rowHeight || albumGroupsNeedLayout {
                groupHeightSize = parent.artworkSize
                groupedHeightActive = grouped
                appliedRowHeight = tableView.rowHeight
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: displayRows.indices))
                tableView.sizeToFit()
                scrollView?.tile()
                tableView.layoutSubtreeIfNeeded()
            }
            updateAlbumGroupViews()
            prefetchVisibleTracks()
        }

        private func rebuildAlbumGroups() {
            albumGroups = []
            displayRows = []
            let grouped = parent.groupArtwork && !parent.layout.hidden.contains(.artwork)
            let minimumRows = Int(ceil(max(parent.artworkSize + 16, 72) / 32))
            var start = 0
            while start < rows.count {
                var end = start + 1
                while end < rows.count && rows[end].releaseId == rows[start].releaseId { end += 1 }
                let displayStart = displayRows.count
                displayRows.append(contentsOf: rows[start..<end].map { Optional($0) })
                if grouped {
                    displayRows.append(contentsOf: Array(repeating: nil, count: max(0, minimumRows - (end - start))))
                }
                albumGroups.append(displayStart..<displayRows.count)
                start = end
            }
            (tableView as? MusicLibraryNativeTableView)?.nonselectableRows = IndexSet(
                displayRows.indices.filter { displayRows[$0] == nil }
            )
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            displayRows.indices.contains(row) && displayRows[row] != nil
        }

        func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
            IndexSet(proposedSelectionIndexes.filter { displayRows.indices.contains($0) && displayRows[$0] != nil })
        }

        private func updateAlbumGroupViews() {
            guard let tableView else { return }
            guard albumGroupsNeedLayout || lastAlbumVisibleRect != tableView.visibleRect else { return }
            albumGroupsNeedLayout = false
            lastAlbumVisibleRect = tableView.visibleRect
            groupViews.forEach { $0.removeFromSuperview() }
            groupViews.removeAll()
            guard parent.groupArtwork, !parent.layout.hidden.contains(.artwork),
                  let column = tableView.tableColumn(withIdentifier: .init("artwork")) else { return }
            let columnIndex = tableView.column(withIdentifier: column.identifier)
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound else { return }
            let visibleRange = visibleRows.location..<(visibleRows.location + visibleRows.length)
            for group in albumGroups where group.overlaps(visibleRange) {
                guard let track = displayRows[group.lowerBound] else { continue }
                let top = tableView.rect(ofRow: group.lowerBound)
                let bottom = tableView.rect(ofRow: group.upperBound - 1)
                let columnRect = tableView.rect(ofColumn: columnIndex)
                let view = MusicLibraryAlbumGroupHost(rootView: AnyView(
                    HStack(alignment: .top, spacing: 12) {
                        parent.cellContent(track, .artwork)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(track.release).font(.headline)
                            Text(track.artist).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: MusicLibraryAlbumGroupHost.backgroundColor))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(height: 1 / (tableView.window?.backingScaleFactor ?? 2))
                    }
                ))
                view.sizingOptions = []
                view.wantsLayer = true
                view.layer?.masksToBounds = true
                view.layer?.zPosition = 1
                view.frame = NSRect(x: columnRect.minX, y: top.minY, width: columnRect.width,
                                    height: bottom.maxY - top.minY)
                tableView.addSubview(view)
                groupViews.append(view)
            }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard displayRows.indices.contains(row), let track = displayRows[row] else { return nil }
            let item = NSPasteboardItem()
            item.setString("durvald-track:\(track.id)", forType: LibraryTrackDrag.pasteboardType)
            return item
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            let preview = NSImage(size: NSSize(width: 96, height: 96))
            preview.lockFocus()
            NSWorkspace.shared.icon(for: .data)
                .draw(in: NSRect(x: 0, y: 0, width: 96, height: 96))
            NSApp.applicationIconImage?.draw(in: NSRect(x: 28, y: 28, width: 40, height: 40))
            preview.unlockFocus()
            session.draggingFormation = .none
            let pointer = tableView.window.map {
                tableView.convert($0.convertPoint(fromScreen: screenPoint), from: nil)
            } ?? .zero
            let previewFrame = NSRect(x: pointer.x - preview.size.width / 2,
                                      y: pointer.y - preview.size.height / 2,
                                      width: preview.size.width, height: preview.size.height)
            let transparentPreview = NSImage(size: preview.size, flipped: false) { _ in true }
            var first = true
            session.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                if first {
                    first = false
                    item.setDraggingFrame(previewFrame, contents: preview)
                } else {
                    item.setDraggingFrame(previewFrame, contents: transparentPreview)
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { displayRows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard displayRows.indices.contains(row), let track = displayRows[row], let tableColumn,
                  let value = MusicLibraryColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            if value == .artwork && parent.groupArtwork { return NSView() }
            let identifier = NSUserInterfaceItemIdentifier("music.cell.\(value.rawValue)")
            if value == .title {
                let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? MusicLibraryTitleCell)
                    ?? MusicLibraryTitleCell(identifier: identifier)
                cell.textField?.stringValue = track.title
                cell.textField?.textColor = parent.selection.contains(track.id)
                    ? MusicLibrarySelectionStyle.accentForeground
                    : (track.id == parent.activeTrackID ? .controlAccentColor : .labelColor)
                cell.optionsButton.tag = row
                cell.optionsButton.target = self
                cell.optionsButton.action = #selector(showTrackOptions(_:))
                cell.optionsButton.contentTintColor = .controlAccentColor
                cell.toolTip = nil
                return cell
            }
            if let text = value.text(for: track) {
                let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? MusicLibraryTextCell)
                    ?? MusicLibraryTextCell(identifier: identifier)
                cell.textField?.stringValue = text
                cell.textField?.alignment = value.textAlignment
                cell.textField?.textColor = value == .title
                    ? (track.id == parent.activeTrackID
                        ? (parent.selection.contains(track.id) ? MusicLibrarySelectionStyle.accentForeground : .controlAccentColor)
                        : .labelColor)
                    : .secondaryLabelColor
                cell.toolTip = text
                cell.setAccessibilityIdentifier("track.\(track.id).\(value.rawValue)")
                return cell
            }
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? MusicLibraryHostedCell)
                ?? MusicLibraryHostedCell(identifier: identifier)
            cell.requiresRowHover = (value == .favorite && !track.isFavorite)
                || (value == .rating && (track.rating ?? 0) == 0)
            cell.host.rootView = AnyView(
                parent.cellContent(track, value)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: value.alignment)
            )
            cell.setAccessibilityIdentifier("track.\(track.id).\(value.rawValue)")
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("music.row")
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? MusicLibraryRowView {
                return reused
            }
            let rowView = MusicLibraryRowView(frame: .zero)
            rowView.identifier = identifier
            return rowView
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            guard displayRows.indices.contains(row), let track = displayRows[row] else {
                rowView.setAccessibilityIdentifier(nil)
                rowView.setAccessibilityLabel(nil)
                return
            }
            rowView.setAccessibilityIdentifier("track.\(track.id)")
            rowView.setAccessibilityLabel("\(track.title), \(track.artist)")
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let tableView else { return }
            let ids = Set(tableView.selectedRowIndexes.compactMap { displayRows.indices.contains($0) ? displayRows[$0]?.id : nil })
            parent.selection = ids
        }

        @objc private func showTrackOptions(_ sender: NSButton) {
            guard let tableView = tableView as? MusicLibraryNativeTableView,
                  displayRows.indices.contains(sender.tag), let track = displayRows[sender.tag] else { return }
            tableView.window?.makeFirstResponder(tableView)
            if !tableView.selectedRowIndexes.contains(sender.tag) {
                tableView.selectRowIndexes(IndexSet(integer: sender.tag), byExtendingSelection: false)
            }
            tableView.contextRow = sender.tag
            trackMenuController.rootMenu = trackMenu
            parent.configureMenu(trackMenuController, track)
            let pointer = tableView.window.map {
                sender.convert($0.mouseLocationOutsideOfEventStream, from: nil)
            } ?? NSPoint(x: sender.bounds.midX, y: sender.bounds.midY)
            trackMenu.popUp(positioning: nil, at: pointer, in: sender)
        }

        @objc func playDoubleClickedRow(_ tableView: NSTableView) {
            guard displayRows.indices.contains(tableView.clickedRow), let track = displayRows[tableView.clickedRow] else { return }
            parent.onPlay(track)
        }

        func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
            let actions = tableView.column(withIdentifier: .init(MusicLibraryColumn.actions.rawValue))
            return columnIndex != actions && newColumnIndex != actions
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            tableView?.sizeToFit()
            persistLayout()
            albumGroupsNeedLayout = true
            updateAlbumGroupViews()
        }
        func tableViewColumnDidMove(_ notification: Notification) {
            persistLayout()
            albumGroupsNeedLayout = true
            updateAlbumGroupViews()
        }

        private func persistLayout() {
            guard !isUpdating, let tableView else { return }
            var layout = parent.layout
            layout.order = tableView.tableColumns.compactMap { MusicLibraryColumn(rawValue: $0.identifier.rawValue) }
            for column in tableView.tableColumns {
                guard let value = MusicLibraryColumn(rawValue: column.identifier.rawValue), value.isResizable else { continue }
                layout.widths[value.rawValue] = Double(column.width)
            }
            appliedLayout = layout
            parent.onLayoutChange(layout)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === headerMenu {
                let selectedColumn = (tableView?.headerView as? MusicLibraryHeaderView)?.contextColumnIdentifier
                    .flatMap { MusicLibraryColumn(rawValue: $0.rawValue) }
                let sizeColumn = NSMenuItem(title: "Ajustar esta coluna", action: #selector(autoSizeColumn(_:)), keyEquivalent: "")
                sizeColumn.target = self
                sizeColumn.representedObject = selectedColumn?.rawValue
                sizeColumn.isEnabled = selectedColumn?.isResizable == true
                menu.addItem(sizeColumn)
                let sizeColumns = NSMenuItem(title: "Ajustar todas as colunas", action: #selector(autoSizeColumns(_:)), keyEquivalent: "")
                sizeColumns.target = self
                menu.addItem(sizeColumns)
                menu.addItem(.separator())
                for value in parent.layout.order where value != .actions && (value != .rating || parent.ratingsEnabled) {
                    let item = NSMenuItem(title: value.label, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = value.rawValue
                    item.state = parent.layout.hidden.contains(value) ? .off : .on
                    item.isEnabled = value != .title
                    menu.addItem(item)
                }
                menu.addItem(.separator())
                let reset = NSMenuItem(title: "Restaurar colunas padrão", action: #selector(resetColumns(_:)), keyEquivalent: "")
                reset.target = self
                menu.addItem(reset)
            } else if menu === trackMenu, let tableView = tableView as? MusicLibraryNativeTableView,
                      displayRows.indices.contains(tableView.contextRow), let track = displayRows[tableView.contextRow] {
                trackMenuController.rootMenu = menu
                parent.configureMenu(trackMenuController, track)
            }
        }

        func menuWillOpen(_ menu: NSMenu) {
            if menu === trackMenu { trackMenuController.menuWillOpen(menu) }
        }

        func menuDidClose(_ menu: NSMenu) {
            if menu === trackMenu { trackMenuController.menuDidClose(menu) }
        }

        @objc private func autoSizeColumn(_ item: NSMenuItem) {
            guard let rawValue = item.representedObject as? String,
                  let value = MusicLibraryColumn(rawValue: rawValue) else { return }
            fitColumnsToContent([value])
        }

        @objc private func autoSizeColumns(_ item: NSMenuItem) {
            guard let tableView else { return }
            let visibleColumns = tableView.tableColumns.filter { !$0.isHidden }
                .compactMap { MusicLibraryColumn(rawValue: $0.identifier.rawValue) }
            fitColumnsToContent(visibleColumns)
        }

        private func fitColumnsToContent(_ values: [MusicLibraryColumn]) {
            guard let tableView else { return }
            let font = NSTextField(labelWithString: "").font ?? .systemFont(ofSize: NSFont.systemFontSize)
            isUpdating = true
            for value in values where value.isResizable {
                guard let column = tableView.tableColumn(withIdentifier: .init(value.rawValue)) else { continue }
                let headerFont = column.headerCell.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
                let headerWidth = (value.label as NSString).size(withAttributes: [.font: headerFont]).width
                let contentWidth = rows.reduce(CGFloat.zero) { maximum, track in
                    guard let text = value.text(for: track) else { return maximum }
                    return max(maximum, (text as NSString).size(withAttributes: [.font: font]).width)
                }
                // Include the same horizontal padding used by the header and cells.
                column.width = min(column.maxWidth, max(column.minWidth, ceil(max(headerWidth, contentWidth)) + 18))
            }
            isUpdating = false
            persistLayout()
        }

        @objc private func toggleColumn(_ item: NSMenuItem) {
            guard let rawValue = item.representedObject as? String,
                  let value = MusicLibraryColumn(rawValue: rawValue), value != .title else { return }
            var layout = parent.layout
            if layout.hidden.contains(value) { layout.hidden.remove(value) }
            else { layout.hidden.insert(value) }
            parent.onLayoutChange(layout)
        }

        @objc private func resetColumns(_ item: NSMenuItem) {
            parent.onLayoutChange(MusicLibraryColumnLayout())
        }

        func restoreScrollPositionIfNeeded() {
            guard !didRestoreScroll, !isRestoringScroll, !rows.isEmpty else { return }
            isRestoringScroll = true
            let offset = parent.savedScrollOffset.wrappedValue
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.scrollView else { return }
                scrollView.superview?.layoutSubtreeIfNeeded()
                scrollView.tile()
                guard scrollView.window != nil, scrollView.contentView.bounds.height > 0 else {
                    self.isRestoringScroll = false
                    return
                }
                var point = scrollView.contentView.bounds.origin
                point.y = offset
                scrollView.contentView.scroll(to: point)
                if offset == 0 { self.tableView?.scrollRowToVisible(0) }
                scrollView.reflectScrolledClipView(scrollView.contentView)
                self.didRestoreScroll = true
                self.isRestoringScroll = false
                self.prefetchVisibleTracks()
            }
        }

        @objc func clipBoundsChanged(_ notification: Notification) {
            guard !pendingScrollUpdate else { return }
            pendingScrollUpdate = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingScrollUpdate = false
                if !self.didRestoreScroll {
                    self.restoreScrollPositionIfNeeded()
                    return
                }
                guard self.didRestoreScroll, let scrollView = self.scrollView else { return }
                let offset = max(0, scrollView.contentView.bounds.minY)
                if abs(self.parent.savedScrollOffset.wrappedValue - offset) > 0.5 {
                    self.parent.savedScrollOffset.wrappedValue = offset
                }
                self.updateAlbumGroupViews()
                self.prefetchVisibleTracks()
            }
        }

        private func prefetchVisibleTracks() {
            guard let tableView else { return }
            let range = tableView.rows(in: tableView.visibleRect)
            guard range.location != NSNotFound, range.length > 0 else { return }
            let lastRow = min(range.location + range.length - 1, displayRows.count - 1)
            guard displayRows.indices.contains(range.location), displayRows.indices.contains(lastRow) else { return }
            let visibleIDs = Set(displayRows[range.location...lastRow].compactMap { $0?.id })
            let newIDs = visibleIDs.subtracting(prefetchedVisibleTrackIDs)
            prefetchedVisibleTrackIDs = visibleIDs
            // Check every visible track, since display sorting can differ from page order.
            for id in newIDs {
                DispatchQueue.main.async { [weak self] in self?.parent.onLoadMore(id) }
            }
        }
    }
}

private extension MusicLibraryColumn {
    var textAlignment: NSTextAlignment {
        if self == .trackNumber { return .center }
        if self == .duration || self == .plays { return .right }
        return isResizable ? .left : .center
    }

    func text(for track: Track) -> String? {
        switch self {
        case .title: track.title
        case .artist: track.artist
        case .album: track.release
        case .duration:
            String(format: "%d:%02d", Int(max(0, track.durationSeconds.rounded())) / 60,
                   Int(max(0, track.durationSeconds.rounded())) % 60)
        case .plays: track.playCount.formatted()
        case .trackNumber: track.trackNumber == 0 ? "—" : String(track.trackNumber)
        case .discNumber: track.discNumber == 0 ? "—" : String(track.discNumber)
        case .lastPlayed: track.lastPlayed ?? "—"
        case .bitrate: track.bitrate.map { "\($0) kbps" } ?? "—"
        case .sampleRate: track.sampleRate.map { "\($0) Hz" } ?? "—"
        case .kind: URL(fileURLWithPath: track.filePath).pathExtension.uppercased()

        default: nil
        }
    }
}

private final class MusicLibraryNativeTableView: NSTableView {
    var contextRow = -1
    var nonselectableRows = IndexSet()

    override func menu(for event: NSEvent) -> NSMenu? {
        contextRow = row(at: convert(event.locationInWindow, from: nil))
        guard contextRow >= 0, !nonselectableRows.contains(contextRow) else { return nil }
        window?.makeFirstResponder(self)
        if !selectedRowIndexes.contains(contextRow) {
            selectRowIndexes(IndexSet(integer: contextRow), byExtendingSelection: false)
        }
        return menu
    }
}

private final class MusicLibraryHeaderView: NSTableHeaderView {
    private(set) var contextColumnIdentifier: NSUserInterfaceItemIdentifier?

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = column(at: convert(event.locationInWindow, from: nil))
        if let tableView, tableView.tableColumns.indices.contains(index) {
            contextColumnIdentifier = tableView.tableColumns[index].identifier
        } else {
            contextColumnIdentifier = nil
        }
        return super.menu(for: event)
    }
}

private final class MusicLibraryHeaderCell: NSTableHeaderCell {
    var symbol: NSImage?

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let symbol {
            let frame = NSRect(x: cellFrame.midX - 8, y: cellFrame.midY - 8, width: 16, height: 16)
            symbol.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: nil)
        } else {
            super.drawInterior(withFrame: cellFrame.insetBy(dx: 8, dy: 0), in: controlView)
        }
    }
}

private final class MusicLibraryRowView: NSTableRowView {
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var isHovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        isHovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        updateHoverControls()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHoverControls()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateHoverControls()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? MusicLibraryHostedCell)?.updateHoverVisibility()
    }

    private func updateHoverControls() {
        for cell in subviews.compactMap({ $0 as? MusicLibraryHostedCell }) {
            cell.updateHoverVisibility()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        super.drawSelection(in: dirtyRect)
        guard isSelected, isNextRowSelected else { return }
        let height: CGFloat = 1
        let separator = NSRect(x: bounds.minX, y: bounds.maxY - height,
                               width: bounds.width, height: height)
        NSColor.gridColor.withAlphaComponent(1).setFill()
        separator.intersection(dirtyRect).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // AppKit still supplies the alternating colors and updates them with the
        // appearance. Let the native content material show through opaque stripes.
        backgroundColor.withAlphaComponent(backgroundColor.alphaComponent * 0.35).setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

private final class MusicLibraryTextCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class MusicLibraryHostedCell: NSTableCellView {
    var requiresRowHover = false {
        didSet { updateHoverVisibility() }
    }

    func updateHoverVisibility() {
        host.isHidden = requiresRowHover && !((superview as? MusicLibraryRowView)?.isHovered ?? false)
    }

    let host = NSHostingView(rootView: AnyView(EmptyView()))

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = []
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class MusicLibraryAlbumGroupHost: NSHostingView<AnyView> {
    static let backgroundColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 32 / 255, green: 43 / 255, blue: 51 / 255, alpha: 1)
        }
        return .windowBackgroundColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum MusicLibrarySelectionStyle {
    static var accentForeground: NSColor { .alternateSelectedControlTextColor }
}

private final class MusicLibraryTitleCell: NSTableCellView {
    let optionsButton = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Opções da faixa")!, target: nil, action: nil)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        optionsButton.translatesAutoresizingMaskIntoConstraints = false
        optionsButton.isBordered = false
        optionsButton.contentTintColor = .controlAccentColor
        optionsButton.setAccessibilityLabel("Opções da faixa")
        addSubview(label)
        addSubview(optionsButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: optionsButton.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            optionsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            optionsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            optionsButton.widthAnchor.constraint(equalToConstant: 24),
            optionsButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
