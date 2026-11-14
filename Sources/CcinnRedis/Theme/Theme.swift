import AppKit
import CcinnRedisKit
import RedisKit
import SwiftUI

/// Visual language: one accent ("ember crimson"), a distinct colour per data type, consistent metrics.
enum Theme {
    static let accent = Color(nsColor: .appAccent)

    enum Metrics {
        static let cornerRadius: CGFloat = 10
        static let smallCornerRadius: CGFloat = 6
        static let cardPadding: CGFloat = 14
    }

    static let monospaced = Font.system(size: 12, design: .monospaced)
    static let monospacedSmall = Font.system(size: 11, design: .monospaced)

    static func color(for profileColor: ProfileColor) -> Color {
        switch profileColor {
        case .none: .secondary
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }

    static func color(for type: KeyType) -> Color { Color(nsColor: nsColor(for: type)) }

    static func nsColor(for type: KeyType) -> NSColor {
        switch type {
        case .string: .typeString
        case .hash: .typeHash
        case .list: .typeList
        case .set: .typeSet
        case .zset: .typeZSet
        case .stream: .typeStream
        case .none: .tertiaryLabelColor
        default: type.isJSON ? .typeJSON : .systemGray
        }
    }

    static func icon(for type: KeyType) -> String {
        switch type {
        case .string: "textformat"
        case .hash: "number.square"
        case .list: "list.bullet"
        case .set: "circle.grid.2x2"
        case .zset: "chart.bar.xaxis"
        case .stream: "waveform.path"
        case .none: "questionmark.square.dashed"
        default: type.isJSON ? "curlybraces" : "puzzlepiece.extension"
        }
    }

    static func color(for deployment: Deployment) -> Color {
        switch deployment {
        case .standalone: .secondary
        case .replica: .orange
        case .sentinel: .purple
        case .cluster: .teal
        case .proxy: .orange
        }
    }

    static func icon(for deployment: Deployment) -> String {
        switch deployment {
        case .standalone: "server.rack"
        case .replica: "doc.on.doc"
        case .sentinel: "eye.trianglebadge.exclamationmark"
        case .cluster: "circle.hexagongrid"
        case .proxy: "arrow.triangle.branch"
        }
    }
}

extension NSColor {
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
        }
    }

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static let appAccent = adaptive(light: .hex(0xD13848), dark: .hex(0xFF6B78))

    static let typeString = adaptive(light: .hex(0x2563EB), dark: .hex(0x60A5FA))
    static let typeHash = adaptive(light: .hex(0x7C3AED), dark: .hex(0xB794F6))
    static let typeList = adaptive(light: .hex(0x0D9488), dark: .hex(0x2DD4BF))
    static let typeSet = adaptive(light: .hex(0xC2410C), dark: .hex(0xFDBA74))
    static let typeZSet = adaptive(light: .hex(0xDB2777), dark: .hex(0xF472B6))
    static let typeStream = adaptive(light: .hex(0x0891B2), dark: .hex(0x22D3EE))
    static let typeJSON = adaptive(light: .hex(0x15803D), dark: .hex(0x4ADE80))

    static let consoleCommand = adaptive(light: .hex(0xD13848), dark: .hex(0xFF8A94))
    static let consoleString = adaptive(light: .hex(0x15803D), dark: .hex(0x86EFAC))
    static let consoleNumber = adaptive(light: .hex(0xC2410C), dark: .hex(0xFDBA74))
    static let consoleNil = NSColor.tertiaryLabelColor
    static let consoleError = NSColor.systemRed
    static let consoleMeta = adaptive(light: .hex(0x7C3AED), dark: .hex(0xC4A1FF))
}

@MainActor
enum Format {
    @MainActor private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    @MainActor static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return byteFormatter.string(fromByteCount: max(0, value))
    }

    static func count(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number)
    }

    static func count(_ value: Int) -> String { value.formatted(.number) }

    static func ttl(milliseconds: Int64?) -> String {
        guard let milliseconds else { return "No expiry" }
        return duration(seconds: Double(milliseconds) / 1000)
    }

    static func duration(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return "\(SafeNumber.int(seconds * 1000) ?? 0) ms" }
        let total = SafeNumber.int(seconds) ?? 0
        let days = total / 86_400
        let hours = total % 86_400 / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    static func microseconds(_ value: Int64) -> String {
        if value < 1000 { return "\(value) µs" }
        if value < 1_000_000 { return String(format: "%.2f ms", Double(value) / 1000) }
        return String(format: "%.2f s", Double(value) / 1_000_000)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f%%", value)
    }

    static func bytesText(_ bytes: [UInt8], limit: Int = 200) -> String {
        let clipped = bytes.count > limit ? Array(bytes.prefix(limit)) : bytes
        var text = String(bytes: clipped, encoding: .utf8).map { $0.replacingOccurrences(of: "\n", with: "⏎ ") } ?? RedisKey.escape(clipped)
        if bytes.count > limit { text += "…" }
        return text
    }
}

/// Small rounded label used for versions, modes and states.
struct Badge: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
        .fixedSize()
    }
}

/// Coloured data-type badge (STR / HASH / LIST …).
struct TypeBadge: View {
    let type: KeyType
    var compact = false

    var body: some View {
        Text(compact ? String(type.badge.prefix(1)) : type.badge)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .frame(minWidth: compact ? 14 : 30)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .foregroundStyle(Theme.color(for: type))
            .background(Theme.color(for: type).opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
            .help(type.displayName)
            .fixedSize()
    }
}

/// Inline error presentation with a copy affordance.
struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { Pasteboard.copy(message) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy error")
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius).strokeBorder(Color.red.opacity(0.25)))
    }
}

/// Informational notice (unavailable features, proxies, read-only mode).
struct NoticeBanner: View {
    let message: String
    var systemImage = "info.circle"
    var color: Color = .secondary

    var body: some View {
        Label {
            Text(message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
    }
}

/// Explains why a whole view is unavailable (e.g. INFO through twemproxy).
struct UnavailableView: View {
    let title: String
    let reason: String
    var systemImage = "nosign"

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(reason).textSelection(.enabled)
        }
    }
}

/// Card container used across the app.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(Theme.accent) }
                    Text(title)
                }
                .font(.headline)
            }
            content
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

/// Big number with a caption, used in summary rows.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var systemImage: String?
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(tint) }
                Text(title).foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

/// Two-column key/value list.
struct KeyValueList: View {
    let items: [(String, String)]
    var monospacedValues = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                GridRow {
                    Text(item.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(item.1)
                        .font(monospacedValues ? Theme.monospacedSmall : .body)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
        }
        .font(.callout)
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The app mark, drawn in SwiftUI so it matches the generated app icon: a bolt over stacked memory bars.
struct AppLogo: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.36, blue: 0.38), Color(red: 0.62, green: 0.11, blue: 0.30),
                                              Color(red: 0.30, green: 0.07, blue: 0.27)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: size * 0.045) {
                ForEach(0..<3) { index in
                    Capsule()
                        .fill(.white.opacity(0.22 + Double(index) * 0.12))
                        .frame(width: size * (0.56 - CGFloat(index) * 0.06), height: size * 0.07)
                }
            }
            .offset(y: size * 0.22)
            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white.gradient)
                .offset(y: -size * 0.08)
                .shadow(color: .black.opacity(0.3), radius: size * 0.04, y: size * 0.02)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.15), radius: size * 0.08, y: size * 0.04)
    }
}
