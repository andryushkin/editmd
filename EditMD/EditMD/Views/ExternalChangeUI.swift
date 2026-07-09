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

// MARK: - Status-bar chip (bottom-right, next to word count)

/// Compact external-change control for the status bar — same row as
/// “N words · M chars”, right-aligned. Full unified diff still opens as a sheet.
struct ExternalChangeStatusChip: View {
    let notice: ExternalChangeNotice
    let onShowDiff: () -> Void
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: notice.kind == .conflict
                  ? "exclamationmark.triangle.fill"
                  : "arrow.triangle.2.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(notice.kind == .conflict ? Color.orange : Color.secondary)

            DiffStatsLabel(added: notice.added, removed: notice.removed,
                           font: .system(size: 11, design: .monospaced))

            // Primary actions as plain text buttons — matches status-bar density.
            Button("Diff", action: onShowDiff)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .help("Show unified diff (⌘⇧D)")

            if notice.kind == .conflict {
                Button("Mine", action: onSecondary)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Keep my buffer (write to disk)")
                Button("Disk", action: onPrimary)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .help("Take file from disk")
            } else {
                Button("Revert", action: onSecondary)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Restore pre-reload text")
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .help(notice.kind == .conflict
              ? "Conflict with disk for \(notice.fileName)"
              : "Reloaded from disk — \(notice.fileName)")
    }
}

/// Legacy name kept so call sites can migrate gradually.
typealias ExternalChangeBanner = ExternalChangeStatusChip

// MARK: - Unified diff sheet

/// Payload for the shared unified-diff sheet (external change, git sidebar, …).
struct DiffSheetContent: Equatable, Sendable {
    var title: String
    var fileName: String
    /// Right-side chip, e.g. `HEAD → working tree` or `mine → disk`.
    var sideLabel: String
    var before: String
    var after: String

    var stats: LineDiffResult { lineDiff(before: before, after: after) }
}

struct UnifiedDiffSheet: View {
    let content: DiffSheetContent
    let onClose: () -> Void

    /// External-change banner (v34).
    init(notice: ExternalChangeNotice, onClose: @escaping () -> Void) {
        self.content = DiffSheetContent(
            title: notice.kind == .conflict ? "Conflict diff" : "External change",
            fileName: notice.fileName,
            sideLabel: notice.kind == .conflict ? "mine → disk" : "before → after",
            before: notice.before,
            after: notice.after
        )
        self.onClose = onClose
    }

    /// Generic before/after (git sidebar, etc.).
    init(content: DiffSheetContent, onClose: @escaping () -> Void) {
        self.content = content
        self.onClose = onClose
    }

    private var result: LineDiffResult { content.stats }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DiffTextRepresentable(lines: result.lines,
                                  before: content.before,
                                  after: content.after)
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
                Text(content.title)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(content.fileName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    DiffStatsLabel(added: result.added, removed: result.removed,
                                   font: .system(size: 12, design: .monospaced))
                }
            }
            Spacer()
            Text(content.sideLabel)
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
