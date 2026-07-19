import Foundation

// App-only bridge: vault findings → Source-mode `LintDiagnostic`s.
// Split from VaultLint.swift so the pure lint core compiles into the
// offline editmdctl target without MarkdownLint's editor dependencies.

/// Convert vault findings for one file into Source-compatible diagnostics
/// (no auto-fixes). Ranges: zero-length at link offset when known.
func vaultFindingsAsLintDiagnostics(
    _ findings: [VaultLintFinding],
    for file: URL
) -> [LintDiagnostic] {
    let std = file.standardizedFileURL
    return findings.compactMap { f -> LintDiagnostic? in
        guard f.file.standardizedFileURL == std else { return nil }
        // Orphans have no range — skip Source underline (still in report).
        guard let offset = f.utf16Offset else { return nil }
        guard let rule = lintRule(for: f.rule) else { return nil }
        let severity: LintSeverity
        switch f.severity {
        case .error: severity = .error
        case .warning, .info: severity = .warning
        }
        return LintDiagnostic(
            range: NSRange(location: max(0, offset), length: 0),
            severity: severity,
            rule: rule,
            message: f.message,
            fixes: []
        )
    }
}

private func lintRule(for rule: VaultLintRule) -> LintRule? {
    switch rule {
    case .deadWikiLink: return .vaultDeadWikiLink
    case .ambiguousWikiLink: return .vaultAmbiguousWikiLink
    case .selfWikiLink: return .vaultSelfWikiLink
    case .deadRelativeLink: return .vaultDeadRelativeLink
    case .deadImageLink: return .vaultDeadImageLink
    case .deadHeadingAnchor: return .vaultDeadHeadingAnchor
    case .orphanFile: return nil
    }
}
