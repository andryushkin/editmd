import Foundation

// Filters for one-line text fields. `usesSingleLineMode` is layout-only — a
// pasted newline/tab arrives intact and would reach a file name or markdown
// syntax. Pure, deliberately outside the AppKit field-building file.
//
// Noise = Cc + line/paragraph separators (Zl, Zp — U+2028 comes with PDF/Word
// copies). NOT `controlCharacters`: it misses those separators and covers Cf,
// so a zero-width joiner would count as noise and `👨‍💻 Notes` would come out
// as two people and a laptop.

private let noisyCategories: Set<Unicode.GeneralCategory> =
    [.control, .lineSeparator, .paragraphSeparator]

/// One line of what a field holds: every run of control characters becomes a
/// single space, and only the ends are trimmed. Spaces the user typed are left
/// alone — collapsing them would rename `My  Note.md` behind their back.
func singleLineFieldText(_ raw: String) -> String {
    var out = String.UnicodeScalarView()
    var foldedRun = false
    for scalar in raw.unicodeScalars {
        if noisyCategories.contains(scalar.properties.generalCategory) {
            if !foldedRun { out.append(" ") }
            foldedRun = true
        } else {
            out.append(scalar)
            foldedRun = false
        }
    }
    return String(out).trimmingCharacters(in: .whitespaces)
}

/// The same characters dropped rather than folded — for a URL, where a space is
/// no better than the tab it replaced: it would have to be angle-bracketed to
/// survive as a destination.
func withoutControlCharacters(_ raw: String) -> String {
    String(String.UnicodeScalarView(raw.unicodeScalars.filter {
        !noisyCategories.contains($0.properties.generalCategory)
    }))
}
