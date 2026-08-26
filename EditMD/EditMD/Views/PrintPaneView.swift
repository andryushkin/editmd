import SwiftUI
import PDFKit
import AppKit

// MARK: - Outline

/// One entry of the Print pane's table of contents.
struct PrintOutlineEntry: Identifiable, Equatable {
    let id: Int
    let level: Int
    let title: String
    let pageIndex: Int
}

/// The pane's table of contents.
///
/// A PDF carries an outline only when whatever produced it wrote bookmarks. The
/// page renderer does, so the document's own outline is what the pane normally
/// shows; the rebuild below is for PDFs that carry none — the export path, and
/// any document opened here that was made elsewhere. It reads the markdown
/// headings — authoritative for text, level and order — and places each on the
/// first page at or after the previous heading that contains its text.
///
/// The scan is monotonic on purpose: a title that repeats ("Notes") then lands
/// under its own section instead of jumping back to the first occurrence.
@MainActor
func printOutline(for document: PDFDocument, markdown: String) -> [PrintOutlineEntry] {
    if let root = document.outlineRoot {
        var entries: [PrintOutlineEntry] = []
        appendOutline(root, level: 0, document: document, into: &entries)
        if !entries.isEmpty { return entries }
    }

    let headings = markdownOutline(markdown)
    guard !headings.isEmpty, document.pageCount > 0 else { return [] }
    // One pass over the pages: per-heading extraction would re-read the whole
    // document for every heading.
    let pageTexts = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }

    var entries: [PrintOutlineEntry] = []
    var cursor = 0
    for (index, heading) in headings.enumerated() {
        let needle = heading.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var page = cursor
        if !needle.isEmpty,
           let hit = (cursor..<pageTexts.count).first(where: { pageTexts[$0].contains(needle) }) {
            page = hit
            cursor = hit
        }
        entries.append(PrintOutlineEntry(id: index, level: heading.level,
                                         title: heading.title, pageIndex: page))
    }
    return entries
}

@MainActor
private func appendOutline(_ node: PDFOutline, level: Int, document: PDFDocument,
                           into entries: inout [PrintOutlineEntry]) {
    for index in 0..<node.numberOfChildren {
        guard let child = node.child(at: index) else { continue }
        if let label = child.label, !label.isEmpty {
            let page = child.destination?.page.flatMap { document.index(for: $0) } ?? 0
            entries.append(PrintOutlineEntry(id: entries.count, level: max(1, level + 1),
                                             title: label, pageIndex: page))
        }
        appendOutline(child, level: level + 1, document: document, into: &entries)
    }
}

// MARK: - Model

/// Owns the pane's pages: what to render, whether a render is running, and the
/// last good result. The previous document deliberately stays on screen while
/// a new one is being laid out — Print is allowed to be slow, but it is not
/// allowed to blink.
@MainActor
final class PrintPaneModel: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var outline: [PrintOutlineEntry] = []
    @Published private(set) var isRendering = false
    @Published private(set) var errorMessage: String?
    /// What the last print survived, and what it printed differently from the
    /// way the other modes draw it. Shown by the report button in the pane
    /// chrome; empty when there is nothing to say.
    @Published private(set) var report = PrintReport.empty
    /// The warnings of the last print, on their own.
    ///
    /// Kept as its own name because that is the question asked of this model —
    /// what the print survived — and it must stay answerable without a reader
    /// knowing how the report is assembled.
    var warnings: [PrintWarning] { report.warnings }
    /// One-shot commands for the hosted `PDFView`, which owns page position and
    /// scale. Identified so the view applies each exactly once and a SwiftUI
    /// update pass cannot replay the last one.
    @Published private(set) var command: PrintPaneCommand?

    /// Edits reach Print only from outside the pane (an agent, a file watcher,
    /// a settings change), so this is a guard against a burst, not a typing
    /// debounce — long enough to coalesce a save, short enough to feel live.
    static let debounce: Duration = .milliseconds(400)

    func render(_ request: PrintRenderRequest, debounced: Bool) async {
        if debounced {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
        }
        isRendering = true
        defer { isRendering = false }
        do {
            let result = try await PrintPDFRenderer.render(request)
            guard !Task.isCancelled else { return }
            guard let pdf = PDFDocument(data: result.pdf) else {
                errorMessage = PrintRenderError.noOutput.errorDescription
                return
            }
            errorMessage = nil
            // Off this actor: the notes come from a parse of the whole
            // document, and the main actor is drawing the pages that are
            // already on screen while it runs.
            let markdown = request.markdown
            let notes = await Task.detached(priority: .userInitiated) {
                PrintReport.tokenNotes(in: markdown)
            }.value
            guard !Task.isCancelled else { return }
            report = PrintReport(warnings: result.warnings, tokenNotes: notes)
            document = pdf
            outline = printOutline(for: pdf, markdown: request.markdown)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func send(_ kind: PrintPaneCommand.Kind) {
        command = PrintPaneCommand(id: (command?.id ?? 0) &+ 1, kind: kind)
    }
}

/// A one-shot instruction from the pane chrome to the page view.
struct PrintPaneCommand: Equatable {
    enum Kind: Equatable {
        case goToPage(Int)
        case zoom(factor: CGFloat)
        case fitPage
    }

    let id: Int
    let kind: Kind
}

// MARK: - PDFView host

/// PDFKit view for the Print pane: continuous paged scrolling, zoom, find and
/// link following. The document is swapped in place so a re-render keeps the
/// reader where they were.
struct PrintPDFView: NSViewRepresentable {
    let document: PDFDocument?
    @ObservedObject var findModel: PaneFindModel
    let command: PrintPaneCommand?

    func makeCoordinator() -> Coordinator { Coordinator(findModel: findModel) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        context.coordinator.apply(document: document)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.bind(findModel: findModel)
        context.coordinator.apply(document: document)
        context.coordinator.apply(command: command)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        private weak var view: PDFView?
        private var findModel: PaneFindModel
        private var appliedDocument: PDFDocument?
        private var lastCommandID: Int?
        /// Matches for the live query, in document order.
        private var matches: [PDFSelection] = []
        private var matchIndex = 0

        init(findModel: PaneFindModel) {
            self.findModel = findModel
            super.init()
        }

        func attach(to view: PDFView) {
            self.view = view
            bind(findModel: findModel)
        }

        func detach() {
            clearFindClosures()
        }

        // MARK: Document

        func apply(document: PDFDocument?) {
            guard appliedDocument !== document else { return }
            guard let view else { return }
            // Same reader, new pages: keep the page and the zoom.
            let page = view.currentPage.flatMap { view.document?.index(for: $0) }
            let scale = view.scaleFactor
            let wasAutoScaling = view.autoScales

            appliedDocument = document
            view.document = document
            resetMatches()

            if let document, let page, page < document.pageCount,
               let restored = document.page(at: page) {
                view.go(to: restored)
            }
            if !wasAutoScaling {
                view.autoScales = false
                view.scaleFactor = scale
            }
            // A live query must find its matches in the new pages, not report
            // a tally from the old ones.
            if !findModel.query.isEmpty { runSearch(findModel.query) }
        }

        func apply(command: PrintPaneCommand?) {
            guard let command, command.id != lastCommandID, let view else { return }
            lastCommandID = command.id
            switch command.kind {
            case .goToPage(let index):
                guard let document = view.document, index < document.pageCount,
                      let page = document.page(at: index) else { return }
                view.go(to: page)
            case .zoom(let factor):
                // Stepping the scale means leaving auto-scaling; otherwise the
                // next layout pass snaps it straight back to the fitted size.
                view.autoScales = false
                view.scaleFactor = min(view.maxScaleFactor,
                                       max(view.minScaleFactor, view.scaleFactor * factor))
            case .fitPage:
                view.autoScales = true
            }
        }

        // MARK: Links

        /// Implementing this takes over link handling entirely, so external
        /// URLs are opened here. Internal jumps never arrive: PDFKit resolves
        /// a `GoTo` action itself.
        nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            let scheme = url.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" || scheme == "mailto" else { return }
            NSWorkspace.shared.open(url)
        }

        // MARK: Find

        func bind(findModel: PaneFindModel) {
            self.findModel = findModel
            findModel.runSearch = { [weak self] query in self?.runSearch(query) }
            findModel.stepMatch = { [weak self] delta in self?.step(delta) }
            findModel.clearSearch = { [weak self] in self?.resetMatches() }
            findModel.currentSelection = { [weak self] in self?.view?.currentSelection?.string }
        }

        private func clearFindClosures() {
            findModel.runSearch = nil
            findModel.stepMatch = nil
            findModel.clearSearch = nil
            findModel.currentSelection = nil
        }

        /// Synchronous on the main actor, deliberately. The asynchronous
        /// `beginFindString` hands each `PDFSelection` back on the search
        /// thread, and a non-`Sendable` PDFKit object cannot cross into the
        /// main actor without an unchecked escape hatch. A whole-document
        /// search is cheap enough not to buy that: measured 4 Aug 2026, 4 ms
        /// over 39 A4 pages, and the pane is read-only — nobody types here.
        private func runSearch(_ query: String) {
            guard let document = appliedDocument else {
                findModel.report(count: 0, index: 0)
                return
            }
            matchIndex = 0
            guard !query.isEmpty else {
                matches = []
                highlight()
                findModel.report(count: 0, index: 0)
                return
            }
            matches = document.findString(query, withOptions: [.caseInsensitive,
                                                               .diacriticInsensitive])
            highlight()
            findModel.report(count: matches.count, index: matches.isEmpty ? 0 : 1)
        }

        private func step(_ delta: Int) {
            guard !matches.isEmpty else { return }
            matchIndex = (matchIndex + delta + matches.count) % matches.count
            highlight()
            findModel.report(count: matches.count, index: matchIndex + 1)
        }

        private func resetMatches() {
            matches = []
            matchIndex = 0
            highlight()
        }

        private func highlight() {
            guard let view else { return }
            guard !matches.isEmpty else {
                view.highlightedSelections = nil
                view.clearSelection()
                return
            }
            for match in matches { match.color = .findHighlightColor.withAlphaComponent(0.35) }
            let current = matches[matchIndex]
            current.color = .findHighlightColor
            view.highlightedSelections = matches
            view.setCurrentSelection(current, animate: false)
            view.go(to: current)
        }
    }
}

// MARK: - Pane

/// Full-window Print mode: the document's pages, a table of contents, zoom and
/// ⌘F. Read-only by construction — everything that edits markdown lives in the
/// other modes.
struct PrintPane: View {
    @ObservedObject var document: MarkdownDocument
    let fileURL: URL?
    @ObservedObject var findModel: PaneFindModel
    @StateObject private var model = PrintPaneModel()
    @ObservedObject private var editorSettings = EditorSettings.shared
    @State private var showOutline = false
    @State private var showReport = false

    /// Not private, and the reason is a probe: File ▸ Export as PDF has to
    /// print what this pane prints, and the only way to state that without
    /// rebuilding the request in the test — which would compare two copies of
    /// the same guess — is to read the request the pane itself would use.
    var request: PrintRenderRequest {
        .forDocument(markdown: document.content, fileURL: fileURL,
                     settings: editorSettings)
    }

    var body: some View {
        ZStack {
            PrintPDFView(document: model.document, findModel: findModel,
                         command: model.command)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.document == nil {
                placeholder
            }
        }
        .overlay(alignment: .topLeading) { controls }
        .overlay(alignment: .topTrailing) {
            if findModel.isActive {
                PaneFindBar(model: findModel)
                    .padding(.top, 8)
                    .padding(.trailing, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let message = model.errorMessage { errorBar(message) }
        }
        .animation(.easeOut(duration: 0.12), value: findModel.isActive)
        // First render is immediate; every later one waits out the burst.
        .task(id: request) { [request] in
            await model.render(request, debounced: model.document != nil)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            if model.isRendering {
                ProgressView()
                Text("Laying out pages…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if model.errorMessage == nil {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
            Button {
                showOutline.toggle()
            } label: {
                Image(systemName: "list.bullet.indent")
            }
            .disabled(model.outline.isEmpty)
            .editMDHelp(String(localized: "Table of Contents"))
            .popover(isPresented: $showOutline, arrowEdge: .bottom) {
                outlineList
            }

            Divider().frame(height: 14)

            Button { model.send(.zoom(factor: 1 / 1.2)) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .editMDHelp(String(localized: "Zoom Out"))
            Button { model.send(.zoom(factor: 1.2)) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .editMDHelp(String(localized: "Zoom In"))
            Button { model.send(.fitPage) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .editMDHelp(String(localized: "Fit Page"))

            if !model.report.isEmpty {
                Divider().frame(height: 14)

                Button {
                    showReport.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(verbatim: "\(model.report.count)").monospacedDigit()
                    }
                }
                .editMDHelp(String(localized: "Print Report"))
                .popover(isPresented: $showReport, arrowEdge: .bottom) {
                    reportList
                }
            }

            if model.isRendering, model.document != nil {
                ProgressView().controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(nsColor: .separatorColor)))
        .padding(.top, 8)
        .padding(.leading, 14)
    }

    private var outlineList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.outline) { entry in
                    Button {
                        model.send(.goToPage(entry.pageIndex))
                        showOutline = false
                    } label: {
                        HStack(spacing: 6) {
                            Text(entry.title)
                                .lineLimit(1)
                                .padding(.leading, CGFloat(entry.level - 1) * 12)
                            Spacer(minLength: 12)
                            Text("\(entry.pageIndex + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .frame(width: 280, height: 320)
    }

    /// What the last print survived, and what it printed differently.
    ///
    /// The line and the kind are shown as two separate columns of one row, from
    /// the two separate fields — a warning that arrived with its kind and its
    /// line swapped has to look wrong here, not merely different.
    private var reportList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(model.report.warnings.enumerated()), id: \.offset) { entry in
                    let warning = entry.element
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(warning.line.map { String(localized: "Line \($0)") }
                             ?? String(localized: "No line"))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.kindTitle).font(.system(size: 12, weight: .medium))
                            Text(warning.message)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                ForEach(model.report.tokenNotes) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(note.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title).font(.system(size: 12, weight: .medium))
                            Text(note.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 340, height: 300)
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(message).lineLimit(2)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(nsColor: .separatorColor)))
        .padding(.bottom, 14)
    }
}
