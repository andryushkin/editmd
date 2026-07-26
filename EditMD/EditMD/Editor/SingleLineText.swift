import Foundation

// Filters for what a one-line text field hands back. A field is single-line in
// layout only — `usesSingleLineMode` does not touch the string — so a pasted
// newline or tab arrives intact and would otherwise reach a file name or the
// inside of markdown syntax. Pure, and deliberately not in the AppKit file that
// builds those fields: the naming funnel these guard has no UI in it.
//
// Only Unicode's *control* category (Cc) is treated as noise. `controlCharacters`
// would have been the obvious set and is wrong: it also covers format characters
// (Cf), so a zero-width joiner is noise by that measure and `👨‍💻 Notes` comes
// out as two people and a laptop.

/// One line of what a field holds: every run of control characters becomes a
/// single space, and only the ends are trimmed. Spaces the user typed are left
/// alone — collapsing them would rename `My  Note.md` behind their back.
func singleLineFieldText(_ raw: String) -> String {
    var out = String.UnicodeScalarView()
    var foldedRun = false
    for scalar in raw.unicodeScalars {
        if scalar.properties.generalCategory == .control {
            if !foldedRun { out.append(" ") }
            foldedRun = true
        } else {
            out.append(scalar)
            foldedRun = false
        }
    }
    return String(out).trimmingCharacters(in: .whitespaces)
}

/// The same string with control characters dropped rather than folded — for a
/// URL, where a space is no better than the tab it replaced: it would have to be
/// angle-bracketed to survive as a destination.
func withoutControlCharacters(_ raw: String) -> String {
    String(String.UnicodeScalarView(raw.unicodeScalars.filter {
        $0.properties.generalCategory != .control
    }))
}
