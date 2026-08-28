import CryptoKit
import Foundation
import OSLog
import PrintDotMD

/// The app's whole view of the prebuilt core library: a thin wrapper over the
/// C ABI, not a re-modelling of it. Everything the app is allowed to know
/// about the core enters here, so the C names stay in one file and the rest of
/// the app talks Swift.
///
/// Two jobs: saying which contract the linked library speaks, and printing one
/// `PrintJob`. Printing takes a whole job in one call rather than exposing the
/// document handle, because the handle is what the C rules are attached to —
/// it is not thread-safe, it owns every pointer it hands back, and it loses its
/// last error on the next mutating call. All of that is answerable inside one
/// function and unanswerable once a handle is allowed out.
enum PDMCore {

    /// The contract this app was written against.
    ///
    /// A Swift literal on purpose. The header ships *inside* the artifact and
    /// clang imports `PDM_ABI_VERSION` into Swift as a constant, so writing
    /// `PDM_ABI_VERSION` here would compare the vendored library against its
    /// own header: a core built with a different version would move both sides
    /// of the comparison at once and the check could never fail. The literal
    /// lives in the app's own tree and moves only when a human moves it —
    /// together with `abi_version` in `Vendor/core.expected.json`.
    static let expectedABIVersion: UInt32 = 2

    /// The contract the linked library speaks. Reads it from the library, not
    /// from the header: this is the value the build gate cannot see.
    static func abiVersion() -> UInt32 {
        pdm_abi_version()
    }

    /// The verdict on the linked library, reached once and kept.
    ///
    /// A stored value rather than a check each caller repeats, and that is the
    /// whole of what changed here. The launch report and the print path used
    /// to decide the same question separately, and the launch one threw its
    /// answer away: `assertionFailure` was all of it, which is a trap in a
    /// development build and *nothing at all* in a shipping one. So an app
    /// linked against a core it does not speak used to start in silence and
    /// keep the news until somebody printed. The refusal now rests on a value
    /// that exists in every configuration, and the assertion is only how loud
    /// it is.
    ///
    /// `static let` is also when: once per process, at first use, off whatever
    /// thread got there first — which is what the print path wanted from its
    /// own `lazy` and now no longer has to arrange.
    static let contract: Result<UInt32, CoreError> = {
        let found = abiVersion()
        guard found == expectedABIVersion else {
            return .failure(.abiMismatch(found: found, expected: expectedABIVersion))
        }
        return .success(found)
    }()

    /// Why the core cannot be used. Distinguishable by case, not by a string,
    /// so a caller can tell "wrong core" from a document it refused.
    ///
    /// `LocalizedError` is not decoration: the Print pane shows
    /// `errorDescription`, and an `Error` without one is presented by the system
    /// as "The operation couldn't be completed. (error 0.)" — which is what the
    /// very first failed print would have said.
    enum CoreError: Error, Equatable, LocalizedError, CustomStringConvertible {
        /// The linked library speaks a different contract than this app.
        case abiMismatch(found: UInt32, expected: UInt32)
        /// The core would not take the markdown at all. It reports no status
        /// here — there is no handle yet to hang a message on — so the reasons
        /// (not UTF-8, an impossible length, no memory for the copy) are not
        /// distinguishable from this side.
        case documentRejected
        /// A call answered with something other than `PDM_OK`. The status is
        /// kept raw: the header freezes the numbers and says outright that an
        /// unlisted one means the library is newer than this app, so mapping it
        /// onto a Swift enum here would lose exactly the case worth reporting.
        case call(name: String, status: Int32, message: String?)
        /// The render said `PDM_OK` and produced nothing to print.
        ///
        /// Its own case because it is not a refusal the core made — it is a
        /// success this side declines to believe. The reading functions of the
        /// C ABI answer a caught panic with their *absent* value, NULL or 0,
        /// because a function returning a pointer has nowhere to put a status
        /// code; the header says so outright. So "no bytes" and "the library
        /// panicked while handing them over" arrive here as the same thing,
        /// and the only safe reading of the pair is that there is nothing to
        /// print. Turning it into an empty `Data` — which is what this used to
        /// do — hands a zero-byte file to whoever asked and calls it done.
        case emptyResult(pages: Int)

        var description: String {
            switch self {
            case let .abiMismatch(found, expected):
                return "PrintDotMD ABI \(found), expected \(expected)"
            case .documentRejected:
                return "PrintDotMD refused the document"
            case let .call(name, status, message):
                return "PrintDotMD \(name) failed with \(status): \(message ?? "no message")"
            case let .emptyResult(pages):
                return "PrintDotMD reported success with no pages (\(pages) claimed)"
            }
        }

        var errorDescription: String? {
            switch self {
            case .abiMismatch:
                return String(localized: "The page renderer does not match this version of the app.")
            case .documentRejected:
                return String(localized: "The page renderer could not read this document.")
            case let .call(_, status, message):
                guard let message, !message.isEmpty else {
                    return String(localized: "The pages could not be produced (error \(Int(status))).")
                }
                // The core's sentence is written for a human and names the field
                // or the glyph that stopped the print — far more use than
                // anything this side could say instead.
                return String(localized: "The pages could not be produced: \(message)")
            case .emptyResult:
                return String(localized: "The page renderer returned no pages.")
            }
        }
    }

    /// Refuses when the linked library speaks a contract this app does not.
    ///
    /// `scripts/verify-core.sh` catches the same mismatch before the build
    /// starts, from the vendored header. This is the runtime half of the pair:
    /// the gate reads a file next to the library, this reads the library.
    static func checkABI() throws {
        if case .failure(let mismatch) = contract { throw mismatch }
    }

    private static let log = Logger(subsystem: "andryushkin.EditMD", category: "core")

    /// Called once at launch. Two jobs, and the second is not incidental: it
    /// says out loud which core the app is running, and it is the app's only
    /// reference to the library, so it is what keeps the core linked into a
    /// Release binary at all — the linker drops archive members nothing
    /// reaches.
    static func reportABI() {
        switch contract {
        case .success(let version):
            log.info("PrintDotMD ABI \(version, privacy: .public)")
        case .failure(let error):
            log.error("PrintDotMD core refused: \(String(describing: error), privacy: .public)")
            // A build mistake, not a user's problem: the vendored library and
            // this app were built against different contracts. Loud in debug,
            // logged in release — the app itself still runs, it just has no
            // core to call, and everything that would call one reads
            // `contract` and refuses by name.
            assertionFailure("\(error)")
        }
    }
}

// MARK: - Printing

extension PDMCore {

    /// Picture formats the core draws itself, by lowercased file extension.
    ///
    /// Knowledge about the boundary, so it lives with the boundary rather than
    /// with the loader that consults it. Measured against the linked library on
    /// 26 Aug 2026 — each of these prints with no warning — and it is the half
    /// of the contract that decides whether a file is handed over untouched or
    /// re-encoded first. A format wrongly listed here prints as a warning
    /// instead of a picture, which is why the list is measured and not read off
    /// a document.
    static let readableImageFormats: Set<String> = ["png", "jpg", "jpeg",
                                                    "gif", "webp", "svg"]

    /// Print one job.
    ///
    /// Synchronous and blocking: the C call has no cancellation, so this must be
    /// called from somewhere a long print is allowed to sit — see
    /// `PrintRenderService`, which is the only caller.
    ///
    /// `asset` is asked for the files the document turns out to refer to. It is
    /// called from inside this function, on the handle that parsed the markdown,
    /// because the boundary requires the two to be the same document: asking one
    /// text for its assets and printing another is a mistake this shape cannot
    /// express. Returning nil is a legitimate answer — the core reports the file
    /// as missing and prints the rest.
    ///
    /// The handle never leaves this function, in either direction. It is not
    /// thread-safe, every pointer it returns belongs to it, and its last error
    /// survives only until the next mutating call.
    static func render(_ job: PrintJob,
                       asset: (String) -> Data?) throws -> PrintRenderResult {
        // The markdown goes over as bytes and a length, not as a C string: a
        // markdown document may legitimately contain U+0000, and a C string
        // would truncate it there without saying so. The buffer is allocated
        // rather than borrowed from an Array so that its address is non-null
        // even for an empty document — `pdm_document_new(NULL, 0)` creates
        // nothing, an empty document is an ordinary state of the pane, and the
        // language does not promise an empty Array a real address.
        let markdown = Array(job.markdown.utf8)
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: max(markdown.count, 1), alignment: 1)
        defer { buffer.deallocate() }
        markdown.withUnsafeBytes { buffer.copyMemory(from: $0) }
        guard let start = buffer.baseAddress,
              let doc = pdm_document_new(start.assumingMemoryBound(to: CChar.self),
                                         markdown.count)
        else { throw CoreError.documentRejected }
        defer { pdm_document_free(doc) }

        // Every call below goes through `check`, which copies the message at the
        // point of failure. One implementation, and this is the shim that saves
        // repeating the handle at every call site.
        func check(_ status: pdm_status, _ name: String) throws {
            try Self.check(status, name, doc: doc)
        }

        // Every setter is called and every status is read straight away. An
        // unchecked setter leaves the core on its own default and the print
        // succeeds looking exactly like the one that was asked for.
        try check(pdm_document_set_title(doc, job.page.title), "set_title")
        try check(pdm_document_set_paper(doc, job.paper), "set_paper")
        try check(pdm_document_set_flipped(doc, job.flipped), "set_flipped")
        try check(pdm_document_set_margins_mm(doc,
                                              job.marginsMM.top,
                                              job.marginsMM.right,
                                              job.marginsMM.bottom,
                                              job.marginsMM.left), "set_margins_mm")
        try check(pdm_document_set_font_size_pt(doc, job.fontSizePt), "set_font_size_pt")
        try check(pdm_document_set_leading_em(doc, job.leadingEm), "set_leading_em")
        try check(pdm_document_set_justify(doc, job.page.justify), "set_justify")
        // No probe can tell this call from its absence today, and that is a
        // property of our own font order rather than a gap in the probes: the
        // body families lead `PrintSettings.fontSet`, so the renderer's fallback
        // — the first family it was handed — always lands on the family we would
        // have named. The call stays as the guard against that order changing,
        // and saying so is better than dressing a probe up as a check.
        try check(pdm_document_set_body_font(doc, job.bodyFont), "set_body_font")
        try check(pdm_document_set_mono_font(doc, job.monoFont), "set_mono_font")
        try check(pdm_document_set_lang(doc, job.page.lang), "set_lang")
        try check(pdm_document_set_outline(doc, job.page.outline), "set_outline")
        try check(pdm_document_set_running_header(doc, job.page.runningHeader),
                  "set_running_header")
        try check(pdm_document_set_page_numbers(doc, job.page.pageNumbers), "set_page_numbers")
        try check(pdm_document_set_pdf_ua(doc, job.page.pdfUA), "set_pdf_ua")

        for file in job.fonts {
            let status = file.bytes.withUnsafeBytes { raw in
                pdm_document_add_font(doc, raw.bindMemory(to: UInt8.self).baseAddress,
                                      raw.count)
            }
            try check(status, "add_font(\(file.family))")
        }

        for target in job.links.keys.sorted() {
            try check(pdm_document_set_link(doc, target, job.links[target]), "set_link")
        }

        let assets = try setAssets(doc, asset: asset)

        var out: OpaquePointer?
        try check(pdm_document_render(doc, &out), "render")
        guard let result = out else {
            throw CoreError.call(name: "render", status: PDM_OK,
                                 message: "no result for a successful render")
        }
        defer { pdm_result_free(result) }
        return try copyOut(result, assets: assets)
    }

    /// Hands over the bytes of every file the parsed document turned out to
    /// refer to, and reports what was handed over.
    ///
    /// The record is written here because here is the only place that knows: the
    /// list of names exists only after the markdown was parsed, on the handle
    /// that will print it.
    private static func setAssets(_ doc: OpaquePointer,
                                  asset: (String) -> Data?) throws -> [PrintAssetRecord] {
        var records: [PrintAssetRecord] = []
        for index in 0..<pdm_document_required_asset_count(doc) {
            guard let namePointer = pdm_document_required_asset(doc, index) else { continue }
            // Read with the length the core gives, not as a C string. The length
            // is what the core matches the key against, and it keeps this
            // protocol standing on its own rather than on a filter elsewhere
            // in the core continuing to forbid a NUL inside a name.
            let nameLength = pdm_document_required_asset_len(doc, index)
            let nameBytes = [UInt8](UnsafeRawBufferPointer(start: namePointer,
                                                           count: nameLength))
            guard let decoded = String(bytes: nameBytes, encoding: .utf8) else {
                // A name the core cannot have produced. Still recorded, so the
                // list accounts for every request rather than for the ones that
                // went well.
                records.append(.notSupplied(String(decoding: nameBytes, as: UTF8.self)))
                continue
            }
            // The single door a name comes through, so the single place its
            // form is settled — before the loader is asked, and therefore
            // before anything reaches the disk. Everything downstream of here
            // says `name` and means one spelling.
            let name = PrintAssetLoader.canonicalName(decoded)
            guard let data = asset(name) else {
                records.append(.notSupplied(name))
                continue
            }
            // The key goes back in the bytes the core asked with, not in the
            // canonical form: it is the core's own key into its own map, and
            // matching it is not ours to reinterpret. Ours is `name`, and it
            // is what the record carries.
            let status = nameBytes.withUnsafeBytes { rawName in
                data.withUnsafeBytes { rawData in
                    pdm_document_set_asset(
                        doc,
                        rawName.bindMemory(to: CChar.self).baseAddress,
                        nameLength,
                        // NULL with a length of 0 is the empty file, and the
                        // header allows it; the core then warns rather than
                        // failing.
                        rawData.bindMemory(to: UInt8.self).baseAddress,
                        rawData.count)
                }
            }
            try check(status, "set_asset", doc: doc)
            records.append(PrintAssetRecord(
                name: name, supplied: true, byteCount: data.count,
                digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }
        return records
    }

    /// The one place a status is turned into a failure.
    ///
    /// The message belongs to the last *mutating* call on this handle and is
    /// destroyed by the next one, so it is copied out here, at the point of
    /// failure, and never fetched later. That is the most fragile rule at this
    /// boundary, which is exactly why it is written once.
    private static func check(_ status: pdm_status, _ name: String,
                              doc: OpaquePointer) throws {
        guard status != PDM_OK else { return }
        let message = pdm_document_last_error(doc).map { String(cString: $0) }
        throw CoreError.call(name: name, status: status, message: message)
    }

    /// Everything worth keeping out of a result, copied into Swift before the
    /// result is freed. Every pointer in there belongs to the library.
    private static func copyOut(_ result: OpaquePointer,
                                assets: [PrintAssetRecord]) throws -> PrintRenderResult {
        let length = pdm_result_pdf_len(result)
        // No `?? Data()`. A NULL here is the absent value of a reading
        // function, which is also what a caught panic answers with — see
        // `CoreError.emptyResult`. Kept as nil so the rule below can tell it
        // from bytes that arrived and were empty; both are refused, and both
        // are refused by a rule a probe can reach without a result handle.
        let pdf = pdm_result_pdf(result).map { Data(bytes: $0, count: length) }
        let warnings = (0..<pdm_result_warning_count(result)).map { index in
            let line = pdm_result_warning_line(result, index)
            return PrintWarning(
                // Kept as the raw number the header froze. The header says
                // plainly that an unlisted kind means the library is newer than
                // this app and must be shown as unknown rather than dropped —
                // a warning nobody displays is a warning nobody acts on.
                rawKind: pdm_result_warning_kind(result, index),
                message: pdm_result_warning_message(result, index)
                    .map { String(cString: $0) } ?? "",
                line: line >= 0 ? line : nil)
        }
        return try checkedResult(pdf: pdf,
                                 pageCount: Int(pdm_result_page_count(result)),
                                 warnings: warnings,
                                 assets: assets)
    }

    /// What a successful render has to have produced to count as one.
    ///
    /// Separate from `copyOut` and taking values rather than a handle, because
    /// this is the rule and the rule is what a probe needs to reach: a result
    /// handle cannot be fabricated on this side of the boundary, and a rule
    /// that can only be exercised by making the real library misbehave is a
    /// rule nothing tests. `pdf` is nil when the library answered NULL and
    /// empty when it answered a zero length; neither is a document.
    ///
    /// The page count is checked too, and not as a formality: the boundary
    /// hands it over as a plain number with no way to say "absent", so zero is
    /// what both an empty document and a panicked counter look like. A file
    /// with bytes and no pages is not something to write out and call done.
    static func checkedResult(pdf: Data?,
                              pageCount: Int,
                              warnings: [PrintWarning],
                              assets: [PrintAssetRecord]) throws -> PrintRenderResult {
        guard let pdf, !pdf.isEmpty, pageCount > 0 else {
            throw CoreError.emptyResult(pages: pageCount)
        }
        return PrintRenderResult(pdf: pdf, pageCount: pageCount,
                                 warnings: warnings, assets: assets)
    }
}
