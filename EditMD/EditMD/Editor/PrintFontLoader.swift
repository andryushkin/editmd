import Foundation
import CoreText

/// Cap height assumed when the body face cannot be measured — no family
/// resolved, or the host answered with a face of zero cap height.
///
/// 0.71 em is where the macOS text faces sit (measured 25 Aug 2026: New York
/// 0.705, SF Pro Text 0.705, Helvetica Neue 0.714), so a document that lost its
/// font still gets leading within a few thousandths of an em of right instead of
/// a line height that is off by the whole cap height.
let printCoreCapHeightFallbackEm: Double = 0.71

/// What the host answered for one print: the font files, in fallback order, and
/// the two families the renderer is told to prefer.
struct PrintFontSelection: Equatable, Sendable {
    /// Every face the renderer is given, in the order it should fall back
    /// through.
    var files: [PrintFontFile]
    /// Family for body text, or nil when none of the candidates resolved.
    var bodyFont: String?
    /// Family for code, or nil.
    var monoFont: String?
    /// Cap height of the body face, in em — what the leading is computed from.
    var bodyCapHeightEm: Double
}

/// Turns family names into the bytes of the faces behind them.
///
/// The renderer is built without the typesetter's bundled fonts: everything it
/// draws with arrives from here. That makes this the only place in the app that
/// decides *which* faces a page may use, and the order it hands them over in is
/// the fallback chain — so the order is fixed on purpose rather than left to
/// whatever the host enumerates today. A chain that reshuffles between runs
/// would also make two prints of one document differ byte for byte, and the
/// whole point of comparing a print here with a print from the command line is
/// that they cannot.
enum PrintFontLoader {

    /// Everything `settings` asks the renderer to draw with.
    ///
    /// Reads files, so it belongs off the main actor — see `PrintRenderService`.
    static func selection(for settings: PrintSettings) -> PrintFontSelection {
        let theme = settings.resolvedTheme
        // Files whose bytes are actually in hand. Having a descriptor is not the
        // same thing: the host answers from an index, and a face whose file has
        // since been deleted, emptied or made unreadable still has one. A family
        // counted as resolved on the strength of a descriptor would be named to
        // the renderer without its bytes ever being handed over — the one way to
        // name a font that is not there.
        var loadedURLs = Set<URL>()
        var files: [PrintFontFile] = []
        // A family the renderer can draw with. Not the same as "a family that
        // contributed a file": two families can live in one collection file, and
        // the second is available to the renderer even though the bytes were
        // handed over under the first one's name. The renderer reads family
        // names out of the file itself; `family` here is our bookkeeping.
        var resolved = Set<String>()

        // `settings.fontSet` and the theme's stacks are already normalized —
        // `normalizedFontFamily` owns that rule, and nothing here repeats it.
        for name in settings.fontSet {
            var answered = false
            for url in faceFiles(of: name) {
                // Already handed over for an earlier family: the bytes are in
                // the chain, so this family is drawable even though it adds
                // nothing.
                if loadedURLs.contains(url) { answered = true; continue }
                // Mapped rather than copied: the emoji collection alone is
                // ~192 MB, and every print of every document carries it.
                guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe),
                      !bytes.isEmpty else { continue }
                loadedURLs.insert(url)
                files.append(PrintFontFile(family: name, bytes: bytes))
                answered = true
            }
            if answered { resolved.insert(name) }
        }

        // The theme's stack already stands behind the user's choice inside
        // `resolvedBodyFamilies`, so a family that has since been uninstalled
        // falls back to a text face rather than to whatever came first in the
        // set — which, with nothing else resolving, would be the monospaced one.
        let bodyFont = firstResolved(theme.resolvedBodyFamilies(userFamily: settings.fontFamily),
                                     in: resolved)
        let monoFont = firstResolved(theme.monoFamilies, in: resolved)

        return PrintFontSelection(
            files: files,
            bodyFont: bodyFont,
            monoFont: monoFont,
            // The face that will actually set the text, not the first family
            // that was asked for: naming a family the host does not have and
            // then measuring it would put the leading of a substitute on the
            // page.
            bodyCapHeightEm: bodyFont.flatMap(capHeightEm(of:)) ?? printCoreCapHeightFallbackEm)
    }

    /// First family the host answered for. A family it did not answer for is
    /// never named to the renderer: naming one it has no bytes for is worse than
    /// naming none, because it silently falls through to the first file in the
    /// chain instead of to the theme's next choice.
    private static func firstResolved(_ families: [String], in resolved: Set<String>) -> String? {
        families.first { resolved.contains($0) }
    }

    /// Files holding the faces of one family, sorted by path.
    ///
    /// Sorted because the host enumerates faces in no documented order and the
    /// result is a fallback chain. Deduplicated because a collection file holds
    /// several faces and would otherwise be handed over once per face.
    static func faceFiles(of family: String) -> [URL] {
        var urls = Set<URL>()
        for descriptor in matchingDescriptors(family) {
            if let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL {
                urls.insert(url)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    /// Cap height of a family's regular face, in em, or nil when the host has no
    /// such family.
    static func capHeightEm(of family: String) -> Double? {
        let descriptors = matchingDescriptors(family)
        guard !descriptors.isEmpty else { return nil }
        // Faces of one family differ here — Helvetica Neue spans 0.714…0.722 em
        // — so the upright face is picked rather than whichever came first.
        // "Roman" and other names for the same thing fall through to the first
        // match, which is what the host lists as the family's representative.
        let regular = descriptors.first {
            (CTFontDescriptorCopyAttribute($0, kCTFontStyleNameAttribute) as? String) == "Regular"
        } ?? descriptors[0]
        let size: CGFloat = 100
        let cap = Double(CTFontGetCapHeight(CTFontCreateWithFontDescriptor(regular, size, nil)))
            / Double(size)
        return cap > 0 ? cap : nil
    }

    /// Faces the host has for exactly this family.
    ///
    /// The family attribute is passed as *mandatory*. Without that, CoreText
    /// treats the descriptor as a wish list and answers with its idea of the
    /// closest thing it does have: measured 25 Aug 2026, every family name —
    /// including one that does not exist — came back as Helvetica. A loader that
    /// silently substitutes is worse than one that finds nothing, because the
    /// page then prints in a face nobody chose.
    private static func matchingDescriptors(_ family: String) -> [CTFontDescriptor] {
        let query = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: family] as CFDictionary)
        let mandatory = Set([kCTFontFamilyNameAttribute as String]) as CFSet
        return CTFontDescriptorCreateMatchingFontDescriptors(query, mandatory)
            as? [CTFontDescriptor] ?? []
    }
}
