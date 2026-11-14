import AppKit
import SwiftUI

struct TableColumnSpec: Identifiable {
    let id: String
    var title: String
    var width: CGFloat = 140
    var minWidth: CGFloat = 50
    var monospaced = false
    var alignment: NSTextAlignment = .left
    /// The last flexible column absorbs remaining width.
    var flexible = false
}

/// Virtualised NSTableView for element lists (hash fields, list items, slowlog, clients…). Cells are
/// produced lazily by closures, so tables with hundreds of thousands of rows stay cheap.
struct DataTable: NSViewRepresentable {
    let columns: [TableColumnSpec]
    let rowCount: Int
    /// Change it to force a reload when the underlying data changed.
    let revision: Int
    let cell: (_ row: Int, _ column: Int) -> String
    var cellColor: ((_ row: Int, _ column: Int) -> NSColor?)?
    var selection: Binding<Set<Int>>?
    var onDoubleClick: ((Int) -> Void)?
    var menu: ((IndexSet) -> NSMenu?)?
    var onScrollNearEnd: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = DataTableView()
        tableView.coordinator = context.coordinator
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            column.maxWidth = 4000
            column.headerCell.alignment = spec.alignment
            column.resizingMask = spec.flexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            tableView.addTableColumn(column)
        }
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.tableView = tableView
        context.coordinator.observe(scrollView)
        context.coordinator.renderedRevision = revision
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard coordinator.renderedRevision != revision else { return }
        coordinator.renderedRevision = revision
        coordinator.tableView?.reloadData()
        if let selection = selection?.wrappedValue {
            let valid = IndexSet(selection.filter { $0 < rowCount })
            coordinator.tableView?.selectRowIndexes(valid, byExtendingSelection: false)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: DataTable
        weak var tableView: NSTableView?
        var renderedRevision = -1
        private var observer: (any NSObjectProtocol)?
        private static let font = NSFont.systemFont(ofSize: 12)
        private static let monospaced = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

        init(_ parent: DataTable) {
            self.parent = parent
        }

        func observe(_ scrollView: NSScrollView) {
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let tableView = self.tableView, let callback = self.parent.onScrollNearEnd else { return }
                    let visible = tableView.rows(in: tableView.visibleRect)
                    if visible.location + visible.length >= self.parent.rowCount - 20 { callback() }
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rowCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let columnIndex = parent.columns.firstIndex(where: { $0.id == tableColumn.identifier.rawValue }),
                  row < parent.rowCount else { return nil }
            let spec = parent.columns[columnIndex]
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            guard let field = cell.textField else { return cell }
            let text = parent.cell(row, columnIndex)
            field.stringValue = text.count > 400 ? String(text.prefix(400)) + "…" : text
            field.font = spec.monospaced ? Self.monospaced : Self.font
            field.alignment = spec.alignment
            field.textColor = parent.cellColor?(row, columnIndex) ?? .labelColor
            cell.toolTip = text.count > 50 ? String(text.prefix(2000)) : nil
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView, let selection = parent.selection else { return }
            let indices = Set(tableView.selectedRowIndexes)
            if selection.wrappedValue != indices { selection.wrappedValue = indices }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            guard sender.clickedRow >= 0 else { return }
            parent.onDoubleClick?(sender.clickedRow)
        }

        func menu(for rows: IndexSet) -> NSMenu? { parent.menu?(rows) }

        /// Copies the selected rows as tab-separated text.
        func copySelection() {
            guard let tableView else { return }
            let lines = tableView.selectedRowIndexes.map { row in
                parent.columns.indices.map { parent.cell(row, $0) }.joined(separator: "\t")
            }
            guard !lines.isEmpty else { return }
            Pasteboard.copy(lines.joined(separator: "\n"))
        }
    }
}

final class DataTableView: NSTableView {
    weak var coordinator: DataTable.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return coordinator?.menu(for: selectedRowIndexes)
    }

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelection()
    }
}
