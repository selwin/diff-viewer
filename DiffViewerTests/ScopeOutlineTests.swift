import SwiftTreeSitter
import Testing

@testable import DiffViewer

struct ScopeOutlineTests {
    private func outline(_ lines: [String], fileName: String = "a.swift") throws -> ScopeOutline {
        let config = try #require(LanguageRegistry.configuration(forFileNamed: fileName))
        let rules = try #require(LanguageRegistry.scopeRules(forFileNamed: fileName))
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

    // MARK: Other grammars

    @Test func kotlinNamesTypesAndFunctionsWithoutFields() throws {
        let outline = try outline(
            [
                "class Cart {",
                "    fun total(): Int {",
                "        return 1",
                "    }",
                "}",
                "object Registry {",
                "    val x = 1",
                "}",
                "fun String.shout() {",
                "    println(this)",
                "}",
            ], fileName: "a.kt")
        #expect(outline.name(atLine: 2) == "total")
        #expect(outline.name(atLine: 4) == "Cart")
        #expect(outline.name(atLine: 6) == "Registry")
        #expect(outline.name(atLine: 9) == "shout")
    }

    @Test func cFunctionNamesFollowThePointerDeclarator() throws {
        let outline = try outline(
            [
                "int add(int a, int b) {",
                "    return a + b;",
                "}",
                "int *find(int n) {",
                "    return 0;",
                "}",
            ], fileName: "a.c")
        #expect(outline.name(atLine: 1) == "add")
        #expect(outline.name(atLine: 4) == "find")
    }

    @Test func cppOutOfLineMethodsAreNamedByTheirClosestNameAndReferenceReturnsAreNamed() throws {
        let outline = try outline(
            [
                "namespace shop {",
                "void Cart::total() {",
                "    work();",
                "}",
                "int& Cart::ref() {",
                "    return x;",
                "}",
                "}",
                "struct Cart *pending;",
                "class Later;",
            ], fileName: "a.cpp")
        #expect(outline.name(atLine: 2) == "total")
        #expect(outline.name(atLine: 5) == "ref")
        #expect(outline.name(atLine: 0) == "shop")
        // A type used without a body is not a scope.
        #expect(outline.name(atLine: 8) == nil)
        #expect(outline.name(atLine: 9) == nil)
    }

    @Test func cppNestedQualifiersDestructorsAndConversionOperatorsAreNamed() throws {
        let outline = try outline(
            [
                "void A::B::run() {",
                "    work();",
                "}",
                "Cart::~Cart() {",
                "    work();",
                "}",
                "Cart::operator bool() const {",
                "    return true;",
                "}",
                "class Flag {",
                "    operator bool() const {",
                "        return true;",
                "    }",
                "};",
            ], fileName: "a.cpp")
        #expect(outline.name(atLine: 2) == "run")
        #expect(outline.name(atLine: 5) == "~Cart")
        #expect(outline.name(atLine: 8) == "operator bool")
        #expect(outline.name(atLine: 12) == "operator bool")
    }

    @Test func cppBodiedClassesAreScopes() throws {
        let outline = try outline(
            [
                "class Cart {",
                "    int total() {",
                "        return 1;",
                "    }",
                "    int count;",
                "};",
            ], fileName: "a.cpp")
        #expect(outline.name(atLine: 2) == "total")
        #expect(outline.name(atLine: 4) == "Cart")
    }

    @Test func rustImplIsNamedByItsTypeAndFunctionsByTheirOwnName() throws {
        let outline = try outline(
            [
                "impl Cart {",
                "    const LIMIT: u32 = 3;",
                "    fn total() -> u32 {",
                "        1",
                "    }",
                "}",
            ], fileName: "a.rs")
        #expect(outline.name(atLine: 3) == "total")
        #expect(outline.name(atLine: 1) == "Cart")
    }

    @Test func pythonMethodInsideAClass() throws {
        let outline = try outline(
            [
                "class Cart:",
                "    limit = 3",
                "",
                "    def total(self):",
                "        return 1",
            ], fileName: "a.py")
        #expect(outline.name(atLine: 4) == "total")
        #expect(outline.name(atLine: 1) == "Cart")
        #expect(outline.chain(atLine: 4).map { outline.scopes[$0].name } == ["Cart", "total"])
    }

    @Test func javaScriptAssignedFunctionsAreNamedAfterTheirVariable() throws {
        let outline = try outline(
            [
                "const render = () => {",
                "    draw();",
                "};",
                "const x = 5;",
                "const y = 6;",
            ], fileName: "a.js")
        #expect(outline.name(atLine: 1) == "render")
        #expect(outline.name(atLine: 3) == nil)
    }

    @Test func javaScriptDestructuringAndComputedKeysAreNotScopes() throws {
        let destructured = try outline(
            [
                "const { a, b } = () => {",
                "    draw();",
                "};",
            ], fileName: "a.js")
        #expect(destructured.name(atLine: 1) == nil)

        let computed = try outline(
            [
                "class Cart {",
                "    [key] = () => {",
                "        draw();",
                "    };",
                "    named = () => {",
                "        draw();",
                "    };",
                "}",
            ], fileName: "a.js")
        #expect(computed.name(atLine: 2) == "Cart")
        #expect(computed.name(atLine: 5) == "named")
    }

    @Test func typeScriptNamesInterfacesAndClassFieldFunctions() throws {
        let outline = try outline(
            [
                "interface Shape {",
                "    area: number;",
                "}",
                "class Cart {",
                "    total = (): number => {",
                "        return 1;",
                "    };",
                "}",
            ], fileName: "a.ts")
        #expect(outline.name(atLine: 1) == "Shape")
        #expect(outline.name(atLine: 5) == "total")
    }

    @Test func javaGoRubyPhpAndBashFunctionsAreNamed() throws {
        let java = try outline(
            ["class Cart {", "    int total() {", "        return 1;", "    }", "}"], fileName: "A.java")
        #expect(java.name(atLine: 2) == "total")

        let go = try outline(
            ["func (c *Cart) Total() int {", "    return 1", "}"], fileName: "a.go")
        #expect(go.name(atLine: 1) == "Total")

        let ruby = try outline(
            ["class Cart", "  def total", "    1", "  end", "end"], fileName: "a.rb")
        #expect(ruby.name(atLine: 2) == "total")

        let php = try outline(
            ["<?php", "class Cart {", "    function total() {", "        return 1;", "    }", "}"], fileName: "a.php")
        #expect(php.name(atLine: 3) == "total")

        let bash = try outline(["build() {", "    make", "}"], fileName: "a.sh")
        #expect(bash.name(atLine: 1) == "build")
    }

    @Test func languagesWithoutRulesHaveNoScopes() throws {
        let json = try outline(["{", "  \"a\": 1", "}"], fileName: "a.json")
        #expect(json.scopes.isEmpty)
    }

    @Test func filesFoundByNameGetTheSameRulesAsThoseFoundByExtension() throws {
        let lines = ["build() {", "    make", "}"]
        // Order must not matter: the rules are cached per language.
        #expect(try outline(lines, fileName: "Makefile").name(atLine: 1) == "build")
        #expect(try outline(lines, fileName: "a.sh").name(atLine: 1) == "build")
        let ruby = ["def total", "  1", "end"]
        #expect(try outline(ruby, fileName: "Rakefile").name(atLine: 1) == "total")
        #expect(try outline(ruby, fileName: "a.rb").name(atLine: 1) == "total")
    }
}
