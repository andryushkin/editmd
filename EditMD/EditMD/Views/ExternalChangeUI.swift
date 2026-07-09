import SwiftUI
import AppKit

// MARK: - Model

enum ExternalChangeKind: Equatable, Sendable {
    /// Clean buffer was auto-reloaded; `before` is the previous in-memory text.
    case applied
    /// Buffer is dirty; `before` = mine, `after` = disk. Not applied yet.
    case conflict
}

struct ExternalChangeNotice: Equatable, Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let before: String
    let after: String
    let kind: ExternalChangeKind
    let added: Int
    let removed: Int

    var fileName: String { url.lastPathComponent }
}

/// Per-URL notices posted by `DocumentRegistry` when the open file changes on disk.
@MainActor
final class ExternalChangeCenter: ObservableObject {
    static let shared = ExternalChangeCenter()

    @Published private(set) var notices: [URL: ExternalChangeNotice] = [:]

    func post(_ notice: ExternalChangeNotice) {
        notices[notice.url.standardizedFileURL] = notice
    }

    func dismiss(_ url: URL) {
        notices.removeValue(forKey: url.standardizedFileURL)
    }

    func notice(for url: URL?) -> ExternalChangeNotice? {
        guard let url else { return nil }
        return notices[url.standardizedFileURL]
    }
}

// MARK: - Diff colors (banner + rows)

enum DiffChrome {
    static let insert = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.35, green: 0.95, blue: 0.50, alpha: 1)
            : NSColor(red: 0.05, green: 0.55, blue: 0.20, alpha: 1)
    })
    static let delete = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 1)
            : NSColor(red: 0.80, green: 0.10, blue: 0.15, alpha: 1)
    })
    static let insertBg = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.12, green: 0.32, blue: 0.16, alpha: 0.55)
            : NSColor(red: 0.82, green: 0.95, blue: 0.85, alpha: 1)
    }
    static let deleteBg = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.38, green: 0.12, blue: 0.12, alpha: 0.55)
            : NSColor(red: 0.98, green: 0.86, blue: 0.86, alpha: 1)
    }
}

/// `+12 −8` with green / red counts (banner + sheet header).
struct DiffStatsLabel: View {
    let added: Int
    let removed: Int
    var font: Font = .system(size: 11, design: .monospaced)

    var body: some View {
        HStack(spacing: 6) {
            if added > 0 {
                Text("+\(added)")
                    .foregroundStyle(DiffChrome.insert)
                    .fontWeight(.semibold)
            }
            if removed > 0 {
                Text("-\(removed)")
                    .foregroundStyle(DiffChrome.delete)
                    .fontWeight(.semibold)
            }
            if added == 0 && removed == 0 {
                Text("no line changes")
                    .foregroundStyle(.secondary)
            }
        }
        .font(font)
    }
}

// MARK: - Banner (all editor modes)

struct ExternalChangeBanner: View {
    let notice: ExternalChangeNotice
    let onShowDiff: () -> Void
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.kind == .conflict
                  ? "exclamationmark.triangle.fill"
                  : "arrow.down.doc.fill")
                .foregroundStyle(notice.kind == .conflict ? Color.orange : Color.accentColor)
                .help(notice.kind == .conflict
                      ? "Local edits conflict with a newer file on disk"
                      : "File was updated on disk and reloaded")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                DiffStatsLabel(added: notice.added, removed: notice.removed)
            }

            Spacer(minLength: 8)

            Button("Diff", action: onShowDiff)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("d", modifiers: [.command, .shift])

            if notice.kind == .conflict {
                Button("Keep Mine", action: onSecondary)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Write this buffer to disk, discarding the external version")
                Button("Take Disk", action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Replace the buffer with the file on disk")
            } else {
                Button("Revert", action: onSecondary)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Restore the text from before the external reload")
                Button("OK", action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bannerBackground)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var title: String {
        switch notice.kind {
        case .applied:
            return "Updated from disk — \(notice.fileName)"
        case .conflict:
            return "Conflict with disk — \(notice.fileName)"
        }
    }

    private var bannerBackground: some View {
        (notice.kind == .conflict
            ? Color.orange.opacity(0.12)
            : Color.accentColor.opacity(0.10))
    }
}

// MARK: - Unified diff sheet

struct UnifiedDiffSheet: View {
    let notice: ExternalChangeNotice
    let onClose: () -> Void

    private var result: LineDiffResult {
        lineDiff(before: notice.before, after: notice.after)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DiffTextRepresentable(lines: result.lines,
                                  before: notice.before,
                                  after: notice.after)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        // ~2× the previous 640pt minimum; prefer a large working width.
        .frame(minWidth: 1200, idealWidth: 1320, minHeight: 560, idealHeight: 780)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.kind == .conflict ? "Conflict diff" : "External change")
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(notice.fileName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    DiffStatsLabel(added: notice.added, removed: notice.removed,
                                   font: .system(size: 12, design: .monospaced))
                }
            }
            Spacer()
            Text(notice.kind == .conflict ? "mine → disk" : "before → after")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25),
                            in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Text("Source highlighting · green + added · red − removed")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
    }
}

// MARK: - NSTextView diff body (Source fonts + full width)

/// Read-only NSTextView so long lines scroll horizontally, gutters stay tight
/// on the left, and line bodies use the same highlighting as Source mode.
private struct DiffTextRepresentable: NSViewRepresentable {
    let lines: [DiffLine]
    let before: String
    let after: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 6, height: 8)   // tight left margin
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        if let container = tv.textContainer {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                             height: CGFloat.greatestFiniteMagnitude)
            container.lineFragmentPadding = 2
        }
        tv.font = EditorSettings.shared.source.resolvedFont(defaultMono: true)

        scroll.documentView = tv
        context.coordinator.textView = tv
        applyContent(to: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView ?? scroll.documentView as? NSTextView
        else { return }
        context.coordinator.textView = tv
        applyContent(to: tv)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var textView: NSTextView?
        var lastSignature: String = ""
    }

    private func applyContent(to textView: NSTextView) {
        let built = buildDiffAttributedString(lines: lines, before: before, after: after)
        if textView.textStorage?.string == built.string { return }
        textView.textStorage?.setAttributedString(built)
        // Expand text view width to the longest layout line so H-scroll works.
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let width = max(used.width + textView.textContainerInset.width * 2 + 24, 400)
        var frame = textView.frame
        frame.size.width = width
        textView.frame = frame
    }
}

/// Builds the full unified-diff document: compact gutters + Source-styled body.
@MainActor
func buildDiffAttributedString(lines: [DiffLine],
                               before: String,
                               after: String) -> NSAttributedString {
    let display = lines.count > 8_000 ? Array(lines.prefix(8_000)) : lines
    let beforeHL = sourceHighlightedLines(before)
    let afterHL = sourceHighlightedLines(after)
    let baseFont = EditorSettings.shared.source.resolvedFont(defaultMono: true)
    let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: baseFont.pointSize - 0.5,
                                                      weight: .regular)
    let secondary = EditorSettings.shared.effectiveTheme.secondaryColor
    let out = NSMutableAttributedString()

    let insertFg = DiffChrome.insert.nsColorCompatible
    let deleteFg = DiffChrome.delete.nsColorCompatible

    for line in display {
        let lineStart = out.length

        // Compact gutters (4-digit fixed, no huge left pad).
        let oldG = line.oldNumber.map { String(format: "%4d", $0) } ?? "    "
        let newG = line.newNumber.map { String(format: "%4d", $0) } ?? "    "
        let gutter = "\(oldG) \(newG) "
        out.append(NSAttributedString(string: gutter, attributes: [
            .font: gutterFont,
            .foregroundColor: secondary,
        ]))

        let mark: String
        let markColor: NSColor
        switch line.kind {
        case .same:
            mark = " "
            markColor = secondary
        case .insert:
            mark = "+"
            markColor = insertFg
        case .delete:
            mark = "-"
            markColor = deleteFg
        }
        out.append(NSAttributedString(string: mark + " ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .semibold),
            .foregroundColor: markColor,
        ]))

        // Body: Source-highlighted line (fallback to plain).
        let body: NSAttributedString
        switch line.kind {
        case .delete:
            let idx = (line.oldNumber ?? 1) - 1
            body = (idx >= 0 && idx < beforeHL.count) ? beforeHL[idx]
                : NSAttributedString(string: line.text, attributes: [
                    .font: baseFont, .foregroundColor: deleteFg,
                ])
        case .insert:
            let idx = (line.newNumber ?? 1) - 1
            body = (idx >= 0 && idx < afterHL.count) ? afterHL[idx]
                : NSAttributedString(string: line.text, attributes: [
                    .font: baseFont, .foregroundColor: insertFg,
                ])
        case .same:
            let idx = (line.newNumber ?? line.oldNumber ?? 1) - 1
            if idx >= 0, idx < afterHL.count {
                body = afterHL[idx]
            } else if idx >= 0, idx < beforeHL.count {
                body = beforeHL[idx]
            } else {
                body = NSAttributedString(string: line.text, attributes: [
                    .font: baseFont,
                    .foregroundColor: EditorSettings.shared.effectiveTheme.textColor,
                ])
            }
        }
        out.append(body)
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: baseFont,
            .foregroundColor: secondary,
        ]))

        // Row tint for insert/delete (full line including gutters).
        let lineRange = NSRange(location: lineStart, length: out.length - lineStart)
        switch line.kind {
        case .insert:
            out.addAttribute(.backgroundColor, value: DiffChrome.insertBg, range: lineRange)
        case .delete:
            out.addAttribute(.backgroundColor, value: DiffChrome.deleteBg, range: lineRange)
        case .same:
            break
        }
    }

    if lines.count > display.count {
        out.append(NSAttributedString(
            string: "… \(lines.count - display.count) more lines omitted\n",
            attributes: [.font: gutterFont, .foregroundColor: secondary]))
    }
    return out
}

private extension Color {
    /// Resolve a SwiftUI Color to NSColor for NSAttributedString attributes.
    var nsColorCompatible: NSColor {
        NSColor(self)
    }
}
