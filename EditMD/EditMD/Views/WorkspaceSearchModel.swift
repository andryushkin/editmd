import Foundation
import Combine

/// Debounced workspace full-text search (plan 07). Scan runs off-main;
/// results publish on the main actor. Never reads disk from SwiftUI `body`.
@MainActor
final class WorkspaceSearchModel: ObservableObject {
    static let shared = WorkspaceSearchModel()

    @Published var queryText: String = ""
    @Published var sortByDate: Bool = false

    @Published private(set) var results: [SearchFileResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var skippedOversized = 0
    @Published private(set) var truncated = false
    @Published private(set) var emptyReason: String?
    @Published private(set) var elapsedMs: Int = 0
    @Published private(set) var lastQuery: SearchQuery = .empty
    /// Bumps when a run finishes so UI can rebind cheaply.
    @Published private(set) var revision = 0

    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private let cache = SearchContentCache()
    private let debounceNs: UInt64 = 300_000_000

    /// Injected at run time (tag index + git modified paths).
    private var tagIndex: [String: [URL]] = [:]
    private var modifiedPaths: Set<String> = []
    private var gitAvailable = false
    private var roots: [URL] = []

    init() {}

    /// Update workspace context (roots, tags, git). Does not auto-search.
    func updateContext(
        roots: [URL],
        tagIndex: [String: [URL]],
        modifiedPaths: Set<String>,
        gitAvailable: Bool
    ) {
        self.roots = roots.map(\.standardizedFileURL)
        self.tagIndex = tagIndex
        self.modifiedPaths = modifiedPaths
        self.gitAvailable = gitAvailable
    }

    /// Debounced query change from the search field.
    func setQueryText(_ text: String) {
        queryText = text
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNs ?? 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    /// Immediate re-run (sort toggle, context refresh, tests).
    func runSearchNow() {
        debounceTask?.cancel()
        Task { await runSearch() }
    }

    func clear() {
        debounceTask?.cancel()
        searchTask?.cancel()
        queryText = ""
        results = []
        skippedOversized = 0
        truncated = false
        emptyReason = nil
        elapsedMs = 0
        lastQuery = .empty
        isSearching = false
        revision += 1
    }

    // MARK: - Engine

    private func runSearch() async {
        let raw = queryText
        let query = parseSearchQuery(raw)
        lastQuery = query
        searchTask?.cancel()

        if query.isEmpty {
            results = []
            skippedOversized = 0
            truncated = false
            emptyReason = nil
            elapsedMs = 0
            isSearching = false
            revision += 1
            return
        }

        // Refresh shared git cache only when `is:modified` is present and stale.
        // Reuses Git sidebar snapshot when available — no Process per keystroke.
        if query.isModified {
            await WorkspaceSearchGitBridge.shared.ensureFresh(
                roots: roots,
                openURLs: DocumentRegistry.shared.openURLs
            )
            let bridge = WorkspaceSearchGitBridge.shared
            modifiedPaths = bridge.modifiedPaths
            gitAvailable = bridge.gitAvailable
        }

        isSearching = true
        let roots = self.roots
        let tags = self.tagIndex
        let modified = self.modifiedPaths
        let gitOK = self.gitAvailable
        let byDate = self.sortByDate
        let cache = self.cache

        searchTask = Task.detached(priority: .userInitiated) {
            let started = Date()
            let metas = collectSearchFileMetas(
                roots: roots,
                tagIndex: tags,
                modifiedPaths: modified,
                isCancelled: { Task.isCancelled }
            )
            if Task.isCancelled {
                await MainActor.run {
                    // Leave previous results; a newer task owns the UI.
                }
                return
            }

            var options = SearchRunOptions.default
            options.meta.gitAvailable = gitOK

            let run = runWorkspaceSearch(
                query: query,
                files: metas,
                contentProvider: { meta in
                    if Task.isCancelled { return nil }
                    return loadSearchFileContent(
                        meta: meta, cache: cache, maxBytes: options.maxFileBytes
                    )
                },
                options: options,
                isCancelled: { Task.isCancelled }
            )

            if Task.isCancelled || run.cancelled { return }

            let sorted = sortSearchResults(run.files, byDate: byDate)
            let ms = Int(Date().timeIntervalSince(started) * 1000)

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.results = sorted
                self.skippedOversized = run.skippedOversized
                self.truncated = run.truncated
                self.emptyReason = run.emptyReason
                self.elapsedMs = ms
                self.isSearching = false
                self.revision += 1
            }
        }
    }
}
