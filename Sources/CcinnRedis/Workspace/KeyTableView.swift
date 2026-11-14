import AppKit
import CcinnRedisKit
import RedisKit
import SwiftUI

/// Virtualised key tree on NSTableView: only visible rows get views, folders expand inline, and visible
/// keys request their TYPE/TTL lazily. Handles millions of loaded keys.
struct KeyTableView: NSViewRepresentable {
    let browser: KeyBrowserModel
    let revision: Int
    var onOpen: (RedisKey) -> Void
    var menu: (RedisKey?, Int32?) -> NSMenu?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = KeyRowsTableView()
        tableView.coordinator = context.coordinator
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.focusRingType = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.clicked(_:))
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.tableView = tableView
        context.coordinator.observe(scrollView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard coordinator.renderedRevision != revision else { return }
        coordinator.renderedRevision = revision
        coordinator.reload()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: KeyTableView
        weak var tableView: NSTableView?
        var renderedRevision = -1
        private var observer: (any NSObjectProtocol)?

        init(_ parent: KeyTableView) {
            self.parent = parent
        }

        func observe(_ scrollView: NSScrollView) {
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestVisibleMetadata() }
            }
        }

        func reload() {
            guard let tableView else { return }
            let selected = parent.browser.selectedKey
            tableView.reloadData()
            if let selected, let index = parent.browser.rows.firstIndex(where: { parent.browser.snapshot.key(of: $0.node) == selected }) {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
            requestVisibleMetadata()
        }

        func requestVisibleMetadata() {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            parent.browser.requestMetadata(rows: visible.location..<(visible.location + visible.length))
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.browser.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let browser = parent.browser
            guard browser.rows.indices.contains(row) else { return nil }
            let entry = browser.rows[row]
            let snapshot = browser.snapshot
            let identifier = NSUserInterfaceItemIdentifier("keyRow")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? KeyRowCell) ?? KeyRowCell(identifier: identifier)
            if snapshot.isFolder(entry.node) {
                cell.configureFolder(name: snapshot.name(of: entry.node), count: snapshot.leafCount(of: entry.node), depth: entry.depth,
                                     expanded: browser.isExpanded(entry.node))
            } else if let key = snapshot.key(of: entry.node) {
                let name = browser.viewMode == .list ? key.display : snapshot.name(of: entry.node)
                cell.configureKey(name: name, metadata: browser.metadata[key], depth: browser.viewMode == .list ? 0 : entry.depth)
                cell.toolTip = key.display
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            KeyRowView()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView, tableView.selectedRow >= 0 else { return }
            let browser = parent.browser
            guard browser.rows.indices.contains(tableView.selectedRow) else { return }
            let node = browser.rows[tableView.selectedRow].node
            if let key = browser.snapshot.key(of: node), browser.selectedKey != key {
                browser.selectedKey = key
                parent.onOpen(key)
            }
        }

        @objc func clicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            let browser = parent.browser
            guard browser.rows.indices.contains(row) else { return }
            let node = browser.rows[row].node
            if browser.snapshot.isFolder(node) {
                browser.toggle(node)
            }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            let browser = parent.browser
            guard browser.rows.indices.contains(row), let key = browser.snapshot.key(of: browser.rows[row].node) else { return }
            parent.onOpen(key)
        }

        func menu(forRow row: Int) -> NSMenu? {
            let browser = parent.browser
            guard browser.rows.indices.contains(row) else { return parent.menu(nil, nil) }
            let node = browser.rows[row].node
            return parent.menu(browser.snapshot.key(of: node), browser.snapshot.isFolder(node) ? node : nil)
        }

        func keyDown(_ event: NSEvent) -> Bool {
            guard let tableView else { return false }
            let row = tableView.selectedRow
            let browser = parent.browser
            guard browser.rows.indices.contains(row) else { return false }
            let node = browser.rows[row].node
            switch event.keyCode {
            case 124 where browser.snapshot.isFolder(node) && !browser.isExpanded(node): // →
                browser.toggle(node)
                return true
            case 123 where browser.snapshot.isFolder(node) && browser.isExpanded(node): // ←
                browser.toggle(node)
                return true
            case 36, 76: // return
                if browser.snapshot.isFolder(node) { browser.toggle(node) } else if let key = browser.snapshot.key(of: node) { parent.onOpen(key) }
                return true
            default:
                return false
            }
        }
    }
}

final class KeyRowsTableView: NSTableView {
    weak var coordinator: KeyTableView.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return coordinator?.menu(forRow: row)
    }

    override func keyDown(with event: NSEvent) {
        if coordinator?.keyDown(event) == true { return }
        super.keyDown(with: event)
    }
}

private final class KeyRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        (isEmphasized ? NSColor.appAccent.withAlphaComponent(0.85) : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        path.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected && isEmphasized ? .emphasized : .normal }
}

/// One row: disclosure chevron or type badge, name, and a trailing count or TTL.
final class KeyRowCell: NSTableCellView {
    private let chevron = NSImageView()
    private let icon = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        for view in [chevron, icon, badge, name, trailing] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        badge.font = .systemFont(ofSize: 8.5, weight: .heavy)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 12.5)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        trailing.textColor = .tertiaryLabelColor
        trailing.alignment = .right
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        let leading = chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        self.leading = leading
        NSLayoutConstraint.activate([
            leading,
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            icon.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            badge.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 2),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 13),
            name.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 37),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configureFolder(name text: String, count: Int, depth: Int, expanded: Bool) {
        leading?.constant = 6 + CGFloat(depth) * 14
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        chevron.isHidden = false
        icon.isHidden = false
        icon.image = NSImage(systemSymbolName: expanded ? "folder.fill" : "folder", accessibilityDescription: nil)
        icon.contentTintColor = NSColor.appAccent.withAlphaComponent(0.85)
        badge.isHidden = true
        name.stringValue = text.isEmpty ? "(empty)" : text
        name.textColor = .labelColor
        name.font = .systemFont(ofSize: 12.5, weight: .medium)
        trailing.stringValue = count.formatted(.number.notation(.compactName))
        toolTip = nil
    }

    func configureKey(name text: String, metadata: KeyMetadata?, depth: Int) {
        leading?.constant = 6 + CGFloat(depth) * 14
        chevron.isHidden = true
        icon.isHidden = true
        badge.isHidden = false
        if let metadata {
            let type = metadata.type
            badge.stringValue = type.badge
            let color = Theme.nsColor(for: type)
            badge.textColor = color
            badge.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
            if let ttl = metadata.ttlMilliseconds {
                trailing.stringValue = "⏱ " + Format.ttl(milliseconds: ttl)
            } else {
                trailing.stringValue = type.exists ? "" : "gone"
            }
        } else {
            badge.stringValue = "···"
            badge.textColor = .tertiaryLabelColor
            badge.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2).cgColor
            trailing.stringValue = ""
        }
        name.stringValue = text
        name.textColor = .labelColor
        name.font = .systemFont(ofSize: 12.5)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            name.textColor = emphasized ? .white : .labelColor
            trailing.textColor = emphasized ? NSColor.white.withAlphaComponent(0.8) : .tertiaryLabelColor
        }
    }
}
