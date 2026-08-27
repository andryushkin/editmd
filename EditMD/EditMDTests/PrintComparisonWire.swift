import CryptoKit
import Foundation
@testable import EditMD

/// What one print looks like as a file, so that a print made here and a print
/// made by the command line can be compared without either side seeing the
/// other's code.
///
/// The comparison this exists for has two halves, and they fail differently.
/// One is "same job, two producers": both sides are handed the same manifest
/// and the SHA-256 of the two PDFs has to match. The other is "same input, two
/// jobs": both sides build a job from the same document and settings, and the
/// manifests are compared field by field.
///
/// Only the second names a field, and only about jobs built independently. When
/// the first fails there is no field to name — both sides were handed the same
/// manifest, so what differs is the producer or the boundary between them, not
/// a decision. Saying otherwise here would send a reader looking through the
/// fields of a job that both sides agreed on. The wire format spells out every
/// field rather than hashing the job as a whole so that the second half can
/// name one.
///
/// The format is a contract with a producer that does not read Swift, so the
/// key names and the shape below are fixed and cannot be changed on one side.
/// Both sides write the same `format`/`version` pair so a stale file is a
/// refusal rather than a silent mismatch.
enum PrintComparisonWire {

    // MARK: - Names on the wire

    static let jobFormat = "printdotmd-job"
    static let designFormat = "printdotmd-design"
    static let version = 1

    /// The manifest, the pages, and the bytes behind the digests in it.
    static let jobFileName = "app-job.json"
    static let designFileName = "app-design.json"
    static let pdfFileName = "app.pdf"
    static let blobDirectoryName = "blobs"

    enum WireError: Error, CustomStringConvertible {
        /// A record says bytes went over, and the caller cannot produce them.
        /// Silently writing a manifest with no blob behind a digest would make
        /// the other side fail at a place that has nothing to do with the
        /// cause, so it is refused here.
        case assetBytesMissing(name: String)
        /// The bytes the caller produced are not the bytes that were printed
        /// with. Nothing downstream can notice this: the manifest would be
        /// self-consistent and simply describe a different document.
        case assetBytesDisagree(name: String, recorded: String, produced: String)

        var description: String {
            switch self {
            case .assetBytesMissing(let name):
                return "no bytes for the supplied asset \(name)"
            case .assetBytesDisagree(let name, let recorded, let produced):
                return "asset \(name) was printed as \(recorded) and re-read as \(produced)"
            }
        }
    }

    // MARK: - Digests

    /// Lowercase hex SHA-256 — the same spelling the boundary records for an
    /// asset, so a digest computed here and one computed there compare as
    /// strings without either side normalizing.
    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The first field two manifests disagree on

    /// The first field two manifests disagree on, spelled as a path, or nil.
    ///
    /// It lives with the format rather than in whichever probe needed a field
    /// name first: this file spells the manifest, so it also owns the walk over
    /// it, and a second probe asking the same question gets the same spelling
    /// of the answer instead of inventing one.
    ///
    /// Keys are walked in sorted order so two runs name the same field first.
    /// The sides are named by the caller because the two halves of the
    /// comparison put different producers on them.
    static func firstDifference(_ mine: Any, _ theirs: Any,
                                left: String, right: String,
                                at path: String = "") -> String? {
        switch (mine, theirs) {
        case let (a as [String: Any], b as [String: Any]):
            for key in Set(a.keys).union(b.keys).sorted() {
                let here = path.isEmpty ? key : "\(path).\(key)"
                switch (a[key], b[key]) {
                case (nil, nil): continue
                case (let x?, let y?):
                    if let found = firstDifference(x, y, left: left, right: right, at: here) {
                        return found
                    }
                case (nil, _): return "\(here): missing on the \(left)'s side"
                case (_, nil): return "\(here): missing on the \(right)'s side"
                }
            }
            return nil
        case let (a as [Any], b as [Any]):
            if a.count != b.count { return "\(path): \(a.count) vs \(b.count) entries" }
            for (index, pair) in zip(a, b).enumerated() {
                if let found = firstDifference(pair.0, pair.1, left: left, right: right,
                                               at: "\(path)[\(index)]") {
                    return found
                }
            }
            return nil
        default:
            let a = mine as? NSObject
            let b = theirs as? NSObject
            if let a, let b, a.isEqual(b) { return nil }
            return "\(path): \(mine) (\(left)) vs \(theirs) (\(right))"
        }
    }

    // MARK: - The job as a value

    /// The manifest for one job and the files that were actually handed over.
    ///
    /// `fonts` keeps **the order of the job** and is never sorted: that order is
    /// the fallback chain the renderer walks, so two jobs whose faces are the
    /// same set in a different order print different pages and must not compare
    /// equal. `assets`, on the contrary, is sorted by name, because on both
    /// sides it is a mapping from a name to some bytes and a mapping has no
    /// order at all — the order the renderer *asked* in is a different fact,
    /// and it is not this one. Only supplied assets appear: for a file that
    /// never went over there are no bytes to hash, and "absent here" is the
    /// same statement on both sides.
    static func jobManifest(_ job: PrintJob, assets: [PrintAssetRecord]) -> [String: Any] {
        let supplied = assets.filter(\.supplied).sorted { $0.name < $1.name }
        return [
            "format": jobFormat,
            "version": version,
            "markdown": job.markdown,
            "title": job.page.title.map { $0 as Any } ?? NSNull(),
            "layout": [
                "paper": job.paper,
                "margins_mm": [
                    "top": job.marginsMM.top,
                    "right": job.marginsMM.right,
                    "bottom": job.marginsMM.bottom,
                    "left": job.marginsMM.left,
                ],
                "flipped": job.flipped,
                "font_size_pt": job.fontSizePt,
                "leading_em": job.leadingEm,
                "justify": job.page.justify,
                "body_font": job.bodyFont.map { $0 as Any } ?? NSNull(),
                "mono_font": job.monoFont.map { $0 as Any } ?? NSNull(),
                "lang": job.page.lang,
                "outline": job.page.outline,
                "running_header": job.page.runningHeader,
                "page_numbers": job.page.pageNumbers,
                "pdf_ua": job.page.pdfUA,
            ] as [String: Any],
            "fonts": job.fonts.map {
                [
                    "family": $0.family,
                    "digest": digest($0.bytes),
                    "bytes": $0.bytes.count,
                ] as [String: Any]
            },
            "assets": supplied.map {
                [
                    "name": $0.name,
                    "digest": $0.digest ?? "",
                    "bytes": $0.byteCount,
                ] as [String: Any]
            },
            "links": job.links,
        ]
    }

    /// The manifest as the bytes that go on disk.
    ///
    /// Sorted keys and nothing else: the file is read back as JSON on the other
    /// side, so what matters is that one job always produces one byte string —
    /// a dictionary written in hash order would make two identical runs differ.
    /// Slashes are left unescaped because the other producer writes them that
    /// way, and a file a person may have to diff by eye is worth the option.
    static func encode(_ manifest: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: manifest,
                                   options: [.sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Writing the job out

    /// Writes the manifest and one file per digest into `directory`.
    ///
    /// The blobs are named by their own digest, so two fonts that are the same
    /// file under two family names cost one copy, and a rerun that produced the
    /// same bytes rewrites nothing. `assetBytes` re-reads what the renderer was
    /// given rather than the manifest carrying the bytes: the record on the
    /// result is the only statement of what actually went over, and re-reading
    /// is checked against it here instead of being trusted.
    @discardableResult
    static func writeJob(_ job: PrintJob,
                         assets: [PrintAssetRecord],
                         assetBytes: (String) -> Data?,
                         to directory: URL) throws -> Data {
        let manifest = jobManifest(job, assets: assets)
        let encoded = try encode(manifest)

        let blobs = directory.appendingPathComponent(blobDirectoryName)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)

        for file in job.fonts {
            try writeBlob(file.bytes, named: digest(file.bytes), into: blobs)
        }
        for record in assets where record.supplied {
            guard let bytes = assetBytes(record.name) else {
                throw WireError.assetBytesMissing(name: record.name)
            }
            let produced = digest(bytes)
            guard produced == record.digest else {
                throw WireError.assetBytesDisagree(name: record.name,
                                                   recorded: record.digest ?? "",
                                                   produced: produced)
            }
            try writeBlob(bytes, named: produced, into: blobs)
        }

        try encoded.write(to: directory.appendingPathComponent(jobFileName))
        return encoded
    }

    /// A blob is written once. Rewriting it would be harmless and is still not
    /// done: the name *is* the hash of the content, so a file that is already
    /// there is already the right file, and skipping keeps a run over a vault
    /// with many copies of one picture from doing the same write hundreds of
    /// times.
    private static func writeBlob(_ bytes: Data, named name: String, into blobs: URL) throws {
        let target = blobs.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        try bytes.write(to: target)
    }

    // MARK: - The typesetting table as a value

    /// Everything the app decides about a page *before* a document is involved:
    /// the theme catalog, the settings a fresh install prints with, and the
    /// font set each theme comes to.
    ///
    /// The other side keeps a mirror of this table, and a mirror kept by hand
    /// is a copy that agrees with the original on the day it was written and
    /// never again. So the mirror is checked against this dump, taken from the
    /// live catalog — and `font_sets` in particular is the *measured* answer of
    /// `PrintSettings.fontSet` rather than a restatement of the rule it
    /// follows. Restating the rule is exactly the mistake the dump exists to
    /// prevent: a mirror that reimplements "body, then headings, then mono,
    /// then coverage, first occurrence wins" can be wrong in the same way on
    /// both sides and nothing would show it.
    static func designManifest() -> [String: Any] {
        let defaults = PrintSettings()
        return [
            "format": designFormat,
            "version": version,
            "coverage_families": printCoverageFontFamilies,
            "settings_defaults": [
                "paper": defaults.paper.rawValue,
                "orientation": defaults.orientation.rawValue,
                "margins": margins(defaults.margins),
                "font_size": Double(defaults.fontSize),
                "font_family": defaults.fontFamily,
                "line_height": Double(defaults.lineHeight),
                "theme": defaults.theme,
            ] as [String: Any],
            "themes": PrintTheme.allPresets.map { theme in
                [
                    "id": theme.id,
                    "body_families": theme.bodyFamilies,
                    "heading_families": theme.headingFamilies,
                    "mono_families": theme.monoFamilies,
                    "preferred_font_size": theme.preferredFontSize.map { Double($0) as Any }
                        ?? NSNull(),
                    "preferred_line_height": theme.preferredLineHeight.map { Double($0) as Any }
                        ?? NSNull(),
                    "preferred_margins": theme.preferredMargins.map { margins($0) as Any }
                        ?? NSNull(),
                ] as [String: Any]
            },
            // Grouped by the chosen family and not interleaved: the empty
            // choice is the whole table as shipped, and the second group is the
            // same table with a face put in front of every stack — which is the
            // one rule an unset choice cannot exercise at all. "Menlo" is the
            // witness because it is already in every theme's mono list, so the
            // group also states what happens to a family named twice.
            "font_sets": ["", "Menlo"].flatMap { chosen in
                PrintTheme.allPresets.map { theme -> [String: Any] in
                    var settings = PrintSettings()
                    settings.theme = theme.id
                    settings.fontFamily = chosen
                    return [
                        "theme": theme.id,
                        "user_family": chosen,
                        "families": settings.fontSet,
                    ]
                }
            },
        ]
    }

    /// Margins as the app names them — top/bottom/leading/trailing in points.
    /// Deliberately not the renderer's top/right/bottom/left in millimetres:
    /// this table is what the app decided, and the conversion to the other
    /// naming is itself one of the things being compared.
    private static func margins(_ margins: PrintMargins) -> [String: Any] {
        [
            "top": Double(margins.top),
            "bottom": Double(margins.bottom),
            "leading": Double(margins.leading),
            "trailing": Double(margins.trailing),
        ]
    }

    @discardableResult
    static func writeDesign(to directory: URL) throws -> Data {
        let encoded = try encode(designManifest())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded.write(to: directory.appendingPathComponent(designFileName))
        return encoded
    }
}
