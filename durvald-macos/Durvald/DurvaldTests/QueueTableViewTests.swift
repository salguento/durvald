import AppKit
import XCTest
@testable import Durvald

@MainActor
final class QueueTableViewTests: XCTestCase {
    func testPauseAndMetadataReloadOnlyChangedRowsWithoutHeightChanges() {
        let fixture = makeFixture()
        var rows = fixture.coordinator.rows
        rows[0] = row(1, position: 0, current: true, paused: true)
        fixture.coordinator.parent = view(rows)
        fixture.coordinator.updateRows()
        XCTAssertEqual(fixture.table.fullReloads, 1)
        XCTAssertEqual(fixture.table.partialReloads, [IndexSet(integer: 0)])
        XCTAssertTrue(fixture.table.heightChanges.isEmpty)
        rows[2] = row(3, position: 2, title: "Título editado")
        fixture.coordinator.parent = view(rows)
        fixture.coordinator.updateRows()
        XCTAssertEqual(fixture.table.partialReloads.last, IndexSet(integer: 2))
        fixture.coordinator.updateRows()
        XCTAssertEqual(fixture.table.partialReloads.count, 2, "Unchanged snapshots do no table work")
    }

    func testFocusUpdatesExistingCurrentCellWithoutReloadOrRecreation() throws {
        let fixture = makeFixture()
        let cell = try XCTUnwrap(fixture.coordinator.tableView(fixture.table, viewFor: nil, row: 0) as? NSTableCellView)
        fixture.table.cells[0] = cell
        let artwork = cell.subviews.compactMap { $0 as? NSImageView }.first?.image
        fixture.coordinator.parent = view(fixture.coordinator.rows, active: false)
        fixture.coordinator.updateRows()
        XCTAssertEqual(cell.textField?.textColor, .secondaryLabelColor)
        XCTAssertEqual(fixture.table.fullReloads, 1)
        XCTAssertTrue(fixture.table.partialReloads.isEmpty)
        XCTAssertTrue(fixture.table.heightChanges.isEmpty)
        XCTAssertEqual(fixture.table.requestedCells, [0])
        XCTAssertFalse(fixture.table.requestedCreation)
        XCTAssertTrue(cell.subviews.compactMap { $0 as? NSImageView }.first?.image === artwork)
        fixture.coordinator.parent = view(fixture.coordinator.rows)
        fixture.coordinator.updateRows()
        XCTAssertEqual(cell.textField?.textColor, .controlAccentColor)
    }

    func testSectionChangeInvalidatesNeighborHeaderAndOnlyChangedHeights() throws {
        let fixture = makeFixture()
        var rows = fixture.coordinator.rows
        rows[0] = row(1, position: 0)
        fixture.coordinator.parent = view(rows)
        fixture.coordinator.updateRows()
        XCTAssertEqual(fixture.coordinator.firstUpcomingRow, 0)
        XCTAssertEqual(fixture.table.partialReloads.last, IndexSet([0, 1]))
        XCTAssertEqual(fixture.table.heightChanges, [IndexSet(integer: 1)])
        XCTAssertEqual(fixture.coordinator.tableView(fixture.table, heightOfRow: 0), 70)
        XCTAssertEqual(fixture.coordinator.tableView(fixture.table, heightOfRow: 1), 46)
        let first = try XCTUnwrap(fixture.coordinator.tableView(fixture.table, viewFor: nil, row: 0))
        let second = try XCTUnwrap(fixture.coordinator.tableView(fixture.table, viewFor: nil, row: 1))
        XCTAssertEqual(header(in: first)?.stringValue, "Próximo na fila")
        XCTAssertFalse(clearButton(in: first)?.isHidden ?? true)
        XCTAssertTrue(header(in: second)?.isHidden ?? false)
        XCTAssertTrue(clearButton(in: second)?.isHidden ?? false)
    }

    func testStructuralChangesReloadButPositionChangesAndDuplicateTracksAreIncremental() {
        let fixture = makeFixture(rows: [row(1, position: 0, current: true), row(2, position: 1), row(2, position: 2)])
        var rows = fixture.coordinator.rows
        rows[2] = row(2, position: 8)
        fixture.coordinator.parent = view(rows)
        fixture.coordinator.updateRows()
        XCTAssertEqual(fixture.table.fullReloads, 1)
        XCTAssertEqual(fixture.table.partialReloads.last, IndexSet(integer: 2))
        rows.append(row(4, position: 9))
        fixture.coordinator.parent = view(rows)
        fixture.coordinator.updateRows()
        XCTAssertEqual(fixture.table.fullReloads, 2)
        rows.swapAt(1, 3)
        fixture.coordinator.parent = view(rows)
        fixture.coordinator.updateRows()
        XCTAssertEqual(fixture.table.fullReloads, 3)
        fixture.coordinator.parent = view([])
        fixture.coordinator.updateRows()
        XCTAssertEqual(fixture.table.fullReloads, 4)
        XCTAssertNil(fixture.coordinator.firstUpcomingRow)
        XCTAssertEqual(fixture.coordinator.tableView(fixture.table, heightOfRow: 0), 46)
    }

    func testCoreChangeRefreshesArtworkWithoutStructuralReload() {
        let fixture = makeFixture()
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        fixture.coordinator.parent = view(fixture.coordinator.rows, core: core)
        fixture.coordinator.updateRows()
        XCTAssertEqual(fixture.table.fullReloads, 1)
        XCTAssertEqual(fixture.table.partialReloads.last, IndexSet(integersIn: 0..<3))
        XCTAssertTrue(fixture.table.heightChanges.isEmpty)
    }

    func testNativeTablePreservesSelectionScrollAndRecalculatesSectionHeights() {
        var rows: [QueueTableRow] = []
        for index in 0..<100 {
            rows.append(row(Int64(index + 1), position: UInt64(index), current: index == 0))
        }
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 280, height: 240))
        table.addTableColumn(NSTableColumn(identifier: QueueTableView.Coordinator.columnIdentifier))
        table.headerView = nil
        table.intercellSpacing = .zero
        let coordinator = view(rows).makeCoordinator()
        coordinator.tableView = table
        table.dataSource = coordinator
        table.delegate = coordinator
        let scroll = NSScrollView(frame: table.frame)
        scroll.documentView = table
        coordinator.updateRows()
        table.layoutSubtreeIfNeeded()
        table.selectRowIndexes(IndexSet(integer: 20), byExtendingSelection: false)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        let offset = scroll.contentView.bounds.origin
        rows[80] = row(81, position: 80, title: "Título atualizado")
        coordinator.parent = view(rows)
        coordinator.updateRows()
        coordinator.parent = view(rows, active: false)
        coordinator.updateRows()
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 20))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, offset.y, accuracy: 0.5)
        XCTAssertEqual(table.rect(ofRow: 1).height, 80, accuracy: 0.5)
        XCTAssertTrue(coordinator.moveRow(from: 1, to: 3))
        XCTAssertEqual(table.rect(ofRow: 1).height, 80, accuracy: 0.5)
        XCTAssertEqual(table.rect(ofRow: 3).height, 46, accuracy: 0.5)
        rows = coordinator.rows
        rows[0] = row(1, position: 0)
        coordinator.parent = view(rows)
        coordinator.updateRows()
        XCTAssertEqual(table.rect(ofRow: 1).height, 46, accuracy: 0.5)
        XCTAssertEqual(table.numberOfRows, 100)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 20))
    }

    func testOptimisticMoveRefreshesHeadersButtonTagsAndAffectedHeights() throws {
        var moves: [(UInt64, UInt64)] = []
        let fixture = makeFixture(onMove: { moves.append(($0, $1)) })
        XCTAssertTrue(fixture.coordinator.moveRow(from: 1, to: 2))
        XCTAssertEqual(fixture.coordinator.rows.map(\.trackID), [1, 3, 2])
        XCTAssertEqual(fixture.coordinator.firstUpcomingRow, 1)
        XCTAssertEqual(fixture.table.moves.count, 1)
        XCTAssertEqual(fixture.table.partialReloads.last, IndexSet([1, 2]))
        XCTAssertEqual(fixture.table.heightChanges.last, IndexSet([1, 2]))
        XCTAssertEqual(moves.first?.0, 1)
        XCTAssertEqual(moves.first?.1, 2)
        for index in 1...2 {
            let cell = try XCTUnwrap(fixture.coordinator.tableView(fixture.table, viewFor: nil, row: index))
            let play = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSButton }.first { $0 !== clearButton(in: cell) })
            XCTAssertEqual(play.tag, index)
            XCTAssertEqual(clearButton(in: cell)?.isHidden, index != 1)
        }
        var echoed = fixture.coordinator.rows
        echoed[1] = row(3, position: 1)
        echoed[2] = row(2, position: 2)
        fixture.coordinator.parent = view(echoed)
        fixture.coordinator.updateRows()
        XCTAssertEqual(fixture.table.fullReloads, 1, "The core's renumbered echo must not recreate the queue")
        XCTAssertFalse(fixture.coordinator.moveRow(from: 0, to: 2))
        XCTAssertFalse(fixture.coordinator.moveRow(from: 2, to: 0))
    }

    private func row(_ id: Int64, position: UInt64, current: Bool = false, paused: Bool = false, title: String = "Faixa") -> QueueTableRow {
        .init(trackID: id, position: position, title: title, artist: "Artista", artworkID: nil, isCurrent: current, isPaused: paused)
    }

    private func view(_ rows: [QueueTableRow], active: Bool = true, core: DurvaldCore? = nil,
                      onMove: @escaping (UInt64, UInt64) -> Void = { _, _ in }) -> QueueTableView {
        QueueTableView(rows: rows, core: core, isWindowActive: active, topContentInset: 0,
            onDropTracks: { _, _ in }, onMove: onMove, onPlay: { _ in }, onTogglePlayback: {},
            onRemove: { _ in }, onInfo: { _ in }, onClear: {}, configureMenu: { _, _ in false })
    }

    private func makeFixture(rows: [QueueTableRow]? = nil, onMove: @escaping (UInt64, UInt64) -> Void = { _, _ in }) -> (coordinator: QueueTableView.Coordinator, table: RecordingQueueTable) {
        let table = RecordingQueueTable()
        table.addTableColumn(NSTableColumn(identifier: QueueTableView.Coordinator.columnIdentifier))
        let coordinator = view(rows ?? [row(1, position: 0, current: true), row(2, position: 1), row(3, position: 2)], onMove: onMove).makeCoordinator()
        coordinator.tableView = table
        coordinator.updateRows()
        return (coordinator, table)
    }

    private func header(in cell: NSView) -> NSTextField? { cell.subviews.compactMap { $0 as? NSTextField }.first }
    private func clearButton(in cell: NSView) -> NSButton? { cell.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Limpar" } }
}

@MainActor
private final class RecordingQueueTable: NSTableView {
    var fullReloads = 0
    var partialReloads: [IndexSet] = []
    var heightChanges: [IndexSet] = []
    var moves: [(Int, Int)] = []
    var cells: [Int: NSView] = [:]
    var requestedCells: [Int] = []
    var requestedCreation = false
    override func reloadData() { fullReloads += 1 }
    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) { partialReloads.append(rowIndexes) }
    override func noteHeightOfRows(withIndexesChanged indexSet: IndexSet) { heightChanges.append(indexSet) }
    override func beginUpdates() {}
    override func endUpdates() {}
    override func moveRow(at oldIndex: Int, to newIndex: Int) { moves.append((oldIndex, newIndex)) }
    override func view(atColumn column: Int, row: Int, makeIfNecessary: Bool) -> NSView? {
        requestedCells.append(row)
        requestedCreation = requestedCreation || makeIfNecessary
        return cells[row]
    }
}
