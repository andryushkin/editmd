import AppKit

enum MarkdownCalloutStyle: String, CaseIterable, Sendable {
    case note
    case tip
    case warning
    case important
    case example
}

struct MarkdownCallout: Equatable, Sendable {
    let type: String
    let style: MarkdownCalloutStyle
    let title: String?
    let markerRange: NSRange

    var iconSystemName: String {
        switch style {
        case .note: "info.circle.fill"
        case .tip: "lightbulb.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .important: "exclamationmark.circle.fill"
        case .example: "list.bullet.rectangle"
        }
    }

    var iconText: String {
        switch style {
        case .note: "ℹ︎"
        case .tip: "✦"
        case .warning: "⚠︎"
        case .important: "!"
        case .example: "◇"
        }
    }

    var color: NSColor {
        switch style {
        case .note: .systemBlue
        case .tip: .systemGreen
        case .warning: .systemOrange
        case .important: .systemPurple
        case .example: .systemIndigo
        }
    }
}

/// Detects the first-line `> [!type] Optional title` marker of a top-level
/// blockquote. Quotes nested in lists/callouts and foldable markers stay plain.
func markdownCallout(in text: String, quoteRange: NSRange) -> MarkdownCallout? {
    let ns = text as NSString
    guard quoteRange.location >= 0,
          quoteRange.length > 0,
          NSMaxRange(quoteRange) <= ns.length else { return nil }

    let lineRange = ns.lineRange(for: NSRange(location: quoteRange.location, length: 0))
    let prefixLength = quoteRange.location - lineRange.location
    if prefixLength > 0 {
        let prefix = ns.substring(with: NSRange(location: lineRange.location,
                                                length: prefixLength))
        guard prefix.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    }

    let contentEnd = min(NSMaxRange(lineRange), NSMaxRange(quoteRange))
    let line = ns.substring(with: NSRange(location: quoteRange.location,
                                          length: contentEnd - quoteRange.location))
        .trimmingCharacters(in: .newlines)
    let lineNS = line as NSString
    func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }
    guard lineNS.length >= 5, lineNS.character(at: 0) == 0x3E else { return nil }
    var cursor = 1
    while cursor < lineNS.length,
          isHorizontalWhitespace(lineNS.character(at: cursor)) {
        cursor += 1
    }
    guard cursor + 3 < lineNS.length,
          lineNS.character(at: cursor) == 0x5B,
          lineNS.character(at: cursor + 1) == 0x21 else { return nil }
    let typeStart = cursor + 2
    var close = typeStart
    while close < lineNS.length, lineNS.character(at: close) != 0x5D { close += 1 }
    guard close < lineNS.length, close > typeStart else { return nil }
    if close + 1 < lineNS.length {
        guard isHorizontalWhitespace(lineNS.character(at: close + 1)) else {
            return nil
        }
    }

    let type = lineNS.substring(with: NSRange(location: typeStart, length: close - typeStart))
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    guard type.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
    let style = MarkdownCalloutStyle(rawValue: type.lowercased()) ?? .note
    let titleStart = close + 1
    let title: String? = {
        guard titleStart < lineNS.length else { return nil }
        let value = lineNS.substring(from: titleStart)
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }()
    return MarkdownCallout(
        type: type,
        style: style,
        title: title,
        markerRange: NSRange(location: quoteRange.location + cursor,
                             length: close - cursor + 1))
}
