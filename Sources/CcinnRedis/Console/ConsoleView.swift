import AppKit
import CcinnRedisKit
import RedisKit
import SwiftUI

struct ConsoleView: View {
    @Bindable var model: ConsoleModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ConsoleOutputView(entries: model.entries, revision: model.revision, prompt: model.prompt)
            Divider()
            inputArea
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal").foregroundStyle(Theme.accent)
            Text(model.prompt).font(.callout.monospaced()).foregroundStyle(.secondary)
            if model.isCluster {
                Picker("Node", selection: $model.targetNode) {
                    Text("Route by key").tag(Endpoint?.none)
                    ForEach(model.client.nodeEndpoints(.all), id: \.self) { endpoint in
                        Text(endpoint.description).tag(Endpoint?.some(endpoint))
                    }
                }
                .frame(width: 220)
                .help("Commands with keys go to the slot owner; pick a node for keyless or stateful commands")
            }
            Spacer()
            Toggle("Raw", isOn: $model.rawOutput).toggleStyle(.checkbox).help("Print payloads verbatim like redis-cli --raw")
            if model.isRunning || model.isStreaming {
                Button(role: .destructive) { model.cancelRunning() } label: { Label("Stop", systemImage: "stop.fill") }
            }
            Button { model.clear() } label: { Label("Clear", systemImage: "trash") }
                .help("Clear output")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text(">").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent).padding(.top, 3)
                ConsoleInput(model: model)
                    .frame(height: min(110, CGFloat(max(1, model.input.split(separator: "\n", omittingEmptySubsequences: false).count)) * 17 + 8))
                Button { model.submit() } label: { Image(systemName: "return") }
                    .buttonStyle(.borderless)
                    .disabled(model.isRunning)
                    .help("Run (⏎). ⇧⏎ inserts a newline.")
            }
            if let doc = model.hint(for: model.input) {
                HStack(spacing: 8) {
                    Text(doc.syntax).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    Text("— \(doc.summary)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Read-only, selectable transcript on NSTextView (re-rendered at most ~10×/s while streaming).
struct ConsoleOutputView: NSViewRepresentable {
    let entries: [ConsoleEntry]
    let revision: Int
    let prompt: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.autohidesScrollers = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 10, height: 10)
            textView.usesFindBar = true
            context.coordinator.textView = textView
        }
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.schedule(entries: entries, revision: revision, prompt: prompt)
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        private var rendered = -1
        private var pending: (entries: [ConsoleEntry], revision: Int, prompt: String)?
        private var scheduled = false

        func schedule(entries: [ConsoleEntry], revision: Int, prompt: String) {
            guard revision != rendered else { return }
            pending = (entries, revision, prompt)
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduled = false
                    if let pending = self.pending { self.render(pending.entries, revision: pending.revision) }
                }
            }
        }

        private func render(_ entries: [ConsoleEntry], revision: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let wasAtBottom = isAtBottom
            let text = NSMutableAttributedString()
            let promptFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            let metaFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
            for entry in entries {
                if !entry.command.isEmpty {
                    text.append(NSAttributedString(string: "› " + entry.command, attributes: [.font: promptFont, .foregroundColor: NSColor.consoleCommand]))
                    var meta: [String] = []
                    if let target = entry.target { meta.append(target) }
                    if let duration = entry.duration { meta.append(Self.format(duration)) }
                    if entry.isLive { meta.append("● live") }
                    if !meta.isEmpty {
                        text.append(NSAttributedString(string: "   " + meta.joined(separator: " · "), attributes: [.font: metaFont, .foregroundColor: NSColor.tertiaryLabelColor]))
                    }
                    text.append(NSAttributedString(string: "\n"))
                }
                text.append(entry.output)
                text.append(NSAttributedString(string: "\n\n"))
            }
            storage.setAttributedString(text)
            rendered = revision
            if wasAtBottom { textView.scrollToEndOfDocument(nil) }
        }

        private var isAtBottom: Bool {
            guard let scrollView, let document = scrollView.documentView else { return true }
            let visible = scrollView.contentView.bounds
            return visible.maxY >= document.bounds.height - 40
        }

        static func format(_ duration: Duration) -> String {
            let milliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
            return milliseconds < 1 ? String(format: "%.2f ms", milliseconds) : milliseconds < 1000 ? String(format: "%.1f ms", milliseconds) : String(format: "%.2f s", milliseconds / 1000)
        }
    }
}

/// Command input: ⏎ runs, ⇧⏎ newline, ↑/↓ history, Tab/⌃Space completion with a popup.
struct ConsoleInput: NSViewRepresentable {
    @Bindable var model: ConsoleModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let textView = ConsoleTextView(frame: .zero)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        guard let textView = coordinator.textView else { return }
        if textView.string != model.input {
            coordinator.isApplying = true
            textView.string = model.input
            textView.setSelectedRange(NSRange(location: (model.input as NSString).length, length: 0))
            coordinator.isApplying = false
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.hideCompletions()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: ConsoleModel
        weak var textView: ConsoleTextView?
        var isApplying = false
        private let list = CompletionListModel()
        private var panel: CompletionPanel?
        private var active: CompletionResult?
        private var completionTask: Task<Void, Never>?

        init(model: ConsoleModel) {
            self.model = model
            super.init()
            list.onAccept = { [weak self] item in self?.accept(item) }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView else { return }
            model.input = textView.string
            scheduleCompletion(force: false)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if panel?.isVisible == true {
                switch selector {
                case #selector(NSResponder.moveDown(_:)): list.move(1); return true
                case #selector(NSResponder.moveUp(_:)): list.move(-1); return true
                case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
                    if let item = list.selectedItem { accept(item) }
                    return true
                case #selector(NSResponder.cancelOperation(_:)): hideCompletions(); return true
                default: break
                }
            }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
                hideCompletions()
                model.submit()
                return true
            case #selector(NSResponder.insertTab(_:)):
                scheduleCompletion(force: true)
                return true
            case #selector(NSResponder.moveUp(_:)):
                guard isOnFirstLine(textView) else { return false }
                if let previous = model.historyPrevious() { model.input = previous }
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard isOnLastLine(textView) else { return false }
                if let next = model.historyNext() { model.input = next }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if model.isRunning || model.isStreaming { model.cancelRunning() }
                return true
            default:
                return false
            }
        }

        private func isOnFirstLine(_ textView: NSTextView) -> Bool {
            let text = textView.string as NSString
            return !text.substring(to: min(textView.selectedRange().location, text.length)).contains("\n")
        }

        private func isOnLastLine(_ textView: NSTextView) -> Bool {
            let text = textView.string as NSString
            let location = min(textView.selectedRange().location, text.length)
            return !text.substring(from: location).contains("\n")
        }

        func forceCompletion() { scheduleCompletion(force: true) }

        private func scheduleCompletion(force: Bool) {
            completionTask?.cancel()
            guard let textView else { return }
            let text = textView.string
            let cursor = textView.selectedRange().location
            completionTask = Task { [weak self] in
                if !force { try? await Task.sleep(for: .milliseconds(90)) }
                guard let self, !Task.isCancelled, let textView = self.textView, textView.string == text else { return }
                let result = self.model.complete(text: text, cursor: cursor)
                let exact = result.items.count == 1 && result.items[0].label.caseInsensitiveCompare(result.prefix) == .orderedSame
                if result.items.isEmpty || exact || (!force && result.prefix.isEmpty) {
                    self.hideCompletions()
                } else {
                    self.show(result)
                }
            }
        }

        private func show(_ result: CompletionResult) {
            guard let textView, let window = textView.window else { return }
            active = result
            list.update(items: result.items, prefix: result.prefix)
            let panel = self.panel ?? CompletionPanel(model: list)
            self.panel = panel
            let anchor = textView.firstRect(forCharacterRange: NSRange(location: result.replacementRange.lowerBound, length: 0), actualRange: nil)
            let size = list.preferredSize
            var origin = NSPoint(x: anchor.minX - 26, y: anchor.maxY + 4)
            if let screen = window.screen?.visibleFrame {
                if origin.y + size.height > screen.maxY { origin.y = anchor.minY - size.height - 4 }
                origin.x = min(max(screen.minX, origin.x), screen.maxX - size.width)
            }
            // Above the input (the console input sits at the bottom of the window).
            origin.y = anchor.maxY + 4
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
            panel.orderFront(nil)
        }

        func hideCompletions() {
            completionTask?.cancel()
            active = nil
            guard let panel, panel.isVisible else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        private func accept(_ item: CompletionItem) {
            guard let textView, let active else { return }
            let cursor = textView.selectedRange().location
            let start = min(active.replacementRange.lowerBound, cursor)
            hideCompletions()
            textView.insertText(item.insertText + " ", replacementRange: NSRange(location: start, length: cursor - start))
        }
    }
}

final class ConsoleTextView: NSTextView {
    weak var coordinator: ConsoleInput.Coordinator?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .control, event.keyCode == 49 { // ⌃Space
            coordinator?.forceCompletion()
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        coordinator?.hideCompletions()
        return super.resignFirstResponder()
    }
}

// MARK: - Completion popup

@MainActor
@Observable
final class CompletionListModel {
    var items: [CompletionItem] = []
    var prefix = ""
    var selectedIndex = 0
    var onAccept: (CompletionItem) -> Void = { _ in }

    static let rowHeight: CGFloat = 24
    static let visibleRows = 9

    func update(items: [CompletionItem], prefix: String) {
        self.items = items
        self.prefix = prefix
        selectedIndex = 0
    }

    var selectedItem: CompletionItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), items.count - 1)
    }

    var preferredSize: NSSize {
        let rows = CGFloat(min(items.count, Self.visibleRows))
        return NSSize(width: 520, height: rows * Self.rowHeight + 10 + (selectedItem?.detail != nil ? 26 : 0))
    }
}

final class CompletionPanel: NSPanel {
    init(model: CompletionListModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: CompletionListView(model: model))
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct CompletionListView: View {
    @Bindable var model: CompletionListModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            CompletionRow(item: item, isSelected: index == model.selectedIndex)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selectedIndex = index
                                    model.onAccept(item)
                                }
                        }
                    }
                    .padding(5)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selectedIndex) { _, index in proxy.scrollTo(index) }
            }
            if let detail = model.selectedItem?.detail {
                Divider()
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.7), lineWidth: 0.5))
    }
}

private struct CompletionRow: View {
    let item: CompletionItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? .white : color)
                .frame(width: 18)
            Text(item.label)
                .font(.system(size: 12.5, weight: item.kind == .command ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if item.kind == .key {
                Text("key").font(.system(size: 10)).foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: CompletionListModel.rowHeight)
        .background(isSelected ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private var icon: String {
        switch item.kind {
        case .command: "chevron.left.forwardslash.chevron.right"
        case .subcommand: "arrow.turn.down.right"
        case .key: "key"
        case .keyword: "textformat"
        }
    }

    private var color: Color {
        switch item.kind {
        case .command: Theme.accent
        case .subcommand: .purple
        case .key: Color(nsColor: .typeString)
        case .keyword: .secondary
        }
    }
}
