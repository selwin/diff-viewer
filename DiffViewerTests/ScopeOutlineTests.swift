import SwiftTreeSitter
import Testing

@testable import DiffViewer

struct ScopeOutlineTests {
    private func outline(_ lines: [String]) throws -> ScopeOutline {
        let config = try #require(LanguageRegistry.configuration(forFileNamed: "a.swift"))
        let rules = try #require(LanguageRegistry.scopeRules(forFileNamed: "a.swift"))
        let text = lines.joined(separator: "\n")
        let parser = Parser()
        try parser.setLanguage(config.language)
        let tree = try #require(parser.parse(text))
        return ScopeOutline.build(tree: tree, text: text, lines: lines, rules: rules)
    }

    private let cart = [
        "class Cart {",  // 0
        "    var items: [Int] = []",
        "",
        "    func total() -> Int {",
        "        items.reduce(0, +)",  // 4
        "    }",
        "",
        "    struct Line {",
        "        func price() -> Int {",
        "            1",  // 9
        "        }",
        "    }",
        "}",
    ]

    @Test func namesTheInnermostEnclosingScope() throws {
        let outline = try outline(cart)
        #expect(outline.name(atLine: 4) == "total")
        #expect(outline.name(atLine: 1) == "Cart")
        #expect(outline.name(atLine: 9) == "price")
    }

    @Test func chainRunsFromOutermostToInnermost() throws {
        let outline = try outline(cart)
        #expect(outline.chain(atLine: 4).map { outline.scopes[$0].name } == ["Cart", "total"])
    }

    @Test func closingBraceIsInsideAndLinesOutsideHaveNoScope() throws {
        let outline = try outline([
            "func a() {",
            "    work()",
            "}",
            "",
            "let x = 1",
            "func b() {",
            "}",
        ])
        #expect(outline.name(atLine: 2) == "a")
        #expect(outline.name(atLine: 3) == nil)
        #expect(outline.name(atLine: 4) == nil)
        #expect(outline.name(atLine: 5) == "b")
    }

    @Test func declarationsSharingALineFallBackToTheEnclosingScope() throws {
        let nested = try outline([
            "struct S {",
            "    func a() {}; func b() {}",
            "    func c() {",
            "    }; func d() {",
            "    }",
            "}",
        ])
        #expect(nested.name(atLine: 1) == "S")
        #expect(nested.name(atLine: 3) == "S")
        #expect(nested.name(atLine: 4) == "d")

        let topLevel = try outline(["func a() {}; func b() {}"])
        #expect(topLevel.name(atLine: 0) == nil)

        let oneLine = try outline(["class Cart { func total() {} }"])
        #expect(oneLine.name(atLine: 0) == "Cart")
    }

    @Test func oneLineFunctionAloneOnItsLineIsItsOwnScope() throws {
        let outline = try outline(["struct S {", "    func a() {}", "}"])
        #expect(outline.name(atLine: 1) == "a")
    }

    @Test func closingBraceFollowedBySemicolonIsInside() throws {
        let outline = try outline(["func a() {", "    work()", "};"])
        #expect(outline.name(atLine: 2) == "a")
    }

    @Test func computedPropertyIsAScopeButStoredPropertyIsNot() throws {
        let outline = try outline([
            "struct S {",
            "    var count: Int {",
            "        1",
            "    }",
            "    var stored: Int = {",
            "        2",
            "    }()",
            "}",
        ])
        #expect(outline.name(atLine: 2) == "count")
        #expect(outline.name(atLine: 5) == "S")
    }

    @Test func subscriptIsLabelledSubscript() throws {
        let outline = try outline([
            "struct S {",
            "    subscript(index: Int) -> Int {",
            "        index",
            "    }",
            "}",
        ])
        #expect(outline.name(atLine: 2) == "subscript")
    }

    @Test func appendShiftsLinesAndParentIndices() throws {
        var combined = try outline(cart)
        let second = [
            "struct Line {",
            "    func price() -> Int {",
            "        1",
            "    }",
            "}",
        ]
        combined.append(try outline(second), lineOffset: cart.count)

        let priceLine = cart.count + 2
        #expect(combined.name(atLine: priceLine) == "price")
        #expect(combined.chain(atLine: priceLine).map { combined.scopes[$0].name } == ["Line", "price"])
        #expect(combined.name(atLine: 4) == "total")
        #expect(combined.name(atLine: cart.count - 1) == "Cart")
    }

    @Test func unicodeWhitespaceBeforeADeclarationStillClaimsItsFirstLine() throws {
        for indent in ["\u{0C}", "\u{0B}", "\u{00A0}", "\u{3000}"] {
            let outline = try outline(["struct S {", "\(indent)func a() {", "    work()", "    }", "}"])
            #expect(outline.name(atLine: 1) == "a", "indent \(indent.unicodeScalars.first!.value)")
        }
    }

    @Test func nonASCIITextBeforeADeclarationKeepsNamesAndColumnsRight() throws {
        let outline = try outline([
            "// héllo 🎉",
            "func greet() {",
            "    work()",
            "}",
            "let s = \"héllo 🎉\"; func wave() {",
            "    work()",
            "}",
        ])
        #expect(outline.name(atLine: 1) == "greet")
        #expect(outline.name(atLine: 4) == nil)
        #expect(outline.name(atLine: 5) == "wave")
    }
}
