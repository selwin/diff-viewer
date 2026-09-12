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
}

extension DiffTheme {
    private static func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static let syntaxColors: [TokenStyle: NSColor] = [
        .keyword: dynamicColor(light: hex(0x9B2393), dark: hex(0xFC5FA3)),
        .string: dynamicColor(light: hex(0xC41A16), dark: hex(0xFC6A5D)),
        .escape: dynamicColor(light: hex(0x1C00CF), dark: hex(0xD0BF69)),
        .comment: dynamicColor(light: hex(0x5D6C79), dark: hex(0x6C7986)),
        .type: dynamicColor(light: hex(0x0B4F79), dark: hex(0x5DD8FF)),
        .function: dynamicColor(light: hex(0x326D74), dark: hex(0x67B7A4)),
        .property: dynamicColor(light: hex(0x3E8087), dark: hex(0x67B7A4)),
        .number: dynamicColor(light: hex(0x1C00CF), dark: hex(0xD0BF69)),
        .constant: dynamicColor(light: hex(0x1C00CF), dark: hex(0xD0BF69)),
        .attribute: dynamicColor(light: hex(0x643820), dark: hex(0xFD8F3F)),
        .tag: dynamicColor(light: hex(0x9B2393), dark: hex(0xFC5FA3)),
        .label: dynamicColor(light: hex(0x9B2393), dark: hex(0xFC5FA3)),
        .heading: dynamicColor(light: hex(0x0B4F79), dark: hex(0x5DD8FF)),
    ]

    static func color(for style: TokenStyle) -> NSColor {
        syntaxColors[style] ?? text
    }
}
