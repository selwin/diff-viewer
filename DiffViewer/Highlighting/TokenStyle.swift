import AppKit

/// Semantic token classes produced by the highlighter and colored by the theme.
enum TokenStyle: UInt8, Sendable, CaseIterable {
    case plain = 0
    case keyword
    case string
    case escape
    case comment
    case type
    case function
    case property
    case number
    case constant
    case attribute
    case tag
    case label
    case punctuation
    case heading

    /// Maps a tree-sitter capture name (e.g. `keyword.function`, `string.escape`) to a style.
    static func from(captureName: String) -> TokenStyle {
        let parts = captureName.split(separator: ".")
        guard let first = parts.first else { return .plain }
        let second = parts.count > 1 ? parts[1] : ""
        switch first {
        case "keyword", "include", "repeat", "conditional", "exception", "storageclass":
            return .keyword
        case "string":
            return second == "escape" || second == "special" ? .escape : .string
        case "character":
            return second == "special" ? .escape : .string
        case "escape":
            return .escape
        case "comment":
            return .comment
        case "type", "constructor", "namespace", "module", "structure":
            return .type
        case "function", "method":
            return .function
        case "property", "field":
            return .property
        case "variable":
            switch second {
            case "member", "field": return .property
            case "builtin": return .constant
            default: return .plain
            }
        case "number", "float":
            return .number
        case "constant", "boolean":
            return .constant
        case "attribute", "annotation", "decorator":
            return .attribute
        case "tag":
            return .tag
        case "label":
            return .label
        case "operator", "punctuation", "delimiter":
            return .punctuation
        case "markup", "text":
            switch second {
            case "heading", "title": return .heading
            case "raw", "literal": return .string
            case "link", "uri", "reference": return .type
            case "list": return .punctuation
            case "strong", "emphasis", "italic", "bold": return .keyword
            default: return .plain
            }
        default:
            return .plain
        }
    }

    /// Capture classes the theme deliberately leaves in the text color. They still paint,
    /// as a reset to plain, so an identifier nested in a wider capture (a string
    /// interpolation, a `return` expression) drops the outer color.
    private static let plainClasses: Set<Substring> = ["variable", "none"]

    /// The style to paint for a capture, or nil when the capture is not a highlight:
    /// helper captures used only by predicates (`@_name`) and names the theme does not know.
    static func paintStyle(forCaptureName name: String) -> TokenStyle? {
        if name.hasPrefix("_") { return nil }
        let style = from(captureName: name)
        if style != .plain { return style }
        return plainClasses.contains(name.split(separator: ".").first ?? "") ? .plain : nil
    }
}

extension DiffTheme {
    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Dark hues stay light and off red and green, so text stays readable on the added and
    /// deleted fills.
    private static let syntaxColors: [TokenStyle: NSColor] = [
        .keyword: dynamic(light: hex(0x9B2393), dark: hex(0xFF9CD2)),
        .string: dynamic(light: hex(0xC41A16), dark: hex(0xA5D6FF)),
        .escape: dynamic(light: hex(0x1C00CF), dark: hex(0xE5C07B)),
        .comment: dynamic(light: hex(0x5D6C79), dark: hex(0x959EA8)),
        .type: dynamic(light: hex(0x0B4F79), dark: hex(0xFFB86C)),
        .function: dynamic(light: hex(0x326D74), dark: hex(0xD2A8FF)),
        .property: dynamic(light: hex(0x3E8087), dark: hex(0xD2A8FF)),
        .number: dynamic(light: hex(0x1C00CF), dark: hex(0xE5C07B)),
        .constant: dynamic(light: hex(0x1C00CF), dark: hex(0xE5C07B)),
        .attribute: dynamic(light: hex(0x643820), dark: hex(0xE5C07B)),
        .tag: dynamic(light: hex(0x9B2393), dark: hex(0xFF9CD2)),
        .label: dynamic(light: hex(0x9B2393), dark: hex(0xFF9CD2)),
        .heading: dynamic(light: hex(0x0B4F79), dark: hex(0xFFB86C)),
    ]

    static func color(for style: TokenStyle) -> NSColor {
        syntaxColors[style] ?? text
    }
}
