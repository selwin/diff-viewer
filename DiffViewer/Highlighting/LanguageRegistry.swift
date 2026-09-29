import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterKotlin
import TreeSitterMarkdown
import TreeSitterPHP
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// Bundled tree-sitter grammars, looked up by file name.
enum LanguageRegistry {
    struct Spec: Sendable {
        /// Which pattern wins when two capture the same range. tree-sitter-highlight lets
        /// the later pattern win, and queries are written for that: general captures
        /// first, specific ones later. A few upstream queries are ordered the other way.
        enum Precedence: Sendable {
            case laterPatternWins
            case earlierPatternWins
        }

        let name: String
        let bundleName: String
        let precedence: Precedence
        /// Node kinds that name an enclosing function, method or type.
        let scopes: [String: ScopeRule]
        let language: @Sendable () -> OpaquePointer?

        init(
            _ name: String, bundleName: String? = nil, precedence: Precedence = .laterPatternWins,
            scopes: [String: ScopeRule] = [:],
            _ language: @escaping @Sendable () -> OpaquePointer?
        ) {
            self.name = name
            self.bundleName = bundleName ?? "TreeSitter\(name)_TreeSitter\(name)"
            self.precedence = precedence
            self.scopes = scopes
            self.language = language
        }
    }

    /// `class_declaration` also covers struct, enum, actor and extension. A subscript's
    /// name field is its type, and only computed properties have a body.
    private static let swiftScopes: [String: ScopeRule] = [
        "class_declaration": ScopeRule(name: .field("name")),
        "protocol_declaration": ScopeRule(name: .field("name")),
        "function_declaration": ScopeRule(name: .field("name")),
        "init_declaration": ScopeRule(name: .field("name")),
        "protocol_function_declaration": ScopeRule(name: .field("name")),
        "subscript_declaration": ScopeRule(name: .fixed("subscript")),
        "property_declaration": ScopeRule(
            name: .field("name"), requires: ScopeRule.Requirement(field: "computed_value")),
    ]

    private static func named(_ kinds: String...) -> [String: ScopeRule] {
        Dictionary(uniqueKeysWithValues: kinds.map { ($0, ScopeRule(name: .field("name"))) })
    }

    private static let pythonScopes = named("class_definition", "function_definition")

    /// An arrow or function expression assigned to a plain name (`const render = () => {}`)
    /// or a class field. Destructuring and computed keys don't name anything.
    private static let assignedFunction = ScopeRule.Requirement(
        field: "value", types: ["arrow_function", "function_expression", "generator_function"])

    private static let javaScriptScopes: [String: ScopeRule] = {
        var rules = named(
            "class_declaration", "function_declaration", "generator_function_declaration", "method_definition")
        rules["variable_declarator"] = ScopeRule(
            name: .field("name", types: ["identifier"]), requires: assignedFunction)
        rules["field_definition"] = ScopeRule(
            name: .field("property", types: ["property_identifier", "private_property_identifier"]),
            requires: assignedFunction)
        return rules
    }()

    /// TypeScript's class fields are `public_field_definition` with a `name` field.
    private static let typeScriptScopes: [String: ScopeRule] = {
        var rules = javaScriptScopes
        rules["field_definition"] = nil
        rules["public_field_definition"] = ScopeRule(
            name: .field("name", types: ["property_identifier", "private_property_identifier"]),
            requires: assignedFunction)
        let typeKinds = named(
            "abstract_class_declaration", "interface_declaration", "enum_declaration", "module", "internal_module")
        for (kind, rule) in typeKinds {
            rules[kind] = rule
        }
        return rules
    }()

    private static let goScopes = named("function_declaration", "method_declaration", "type_spec")

    /// An `impl` block is named by the type it implements.
    private static let rustScopes: [String: ScopeRule] = {
        var rules = named("function_item", "trait_item", "mod_item", "struct_item", "enum_item")
        rules["impl_item"] = ScopeRule(name: .field("type"))
        return rules
    }()

    /// C function names sit at the end of a `declarator` chain. C++ type specifiers are
    /// only scopes when they have a body, so `struct Cart *p` and `class Cart;` are not.
    private static let cScopes: [String: ScopeRule] = [
        "function_definition": ScopeRule(name: .cDeclaratorIdentifier)
    ]

    private static let cppScopes: [String: ScopeRule] = {
        var rules = cScopes
        rules["namespace_definition"] = ScopeRule(name: .field("name"))
        for kind in ["class_specifier", "struct_specifier"] {
            rules[kind] = ScopeRule(name: .field("name"), requires: ScopeRule.Requirement(field: "body"))
        }
        return rules
    }()

    private static let javaScopes = named(
        "class_declaration", "interface_declaration", "enum_declaration", "record_declaration",
        "method_declaration", "constructor_declaration")

    /// The Kotlin grammar has no fields: types are named by a `type_identifier` child and
    /// functions by a `simple_identifier` child.
    private static let kotlinScopes: [String: ScopeRule] = [
        "class_declaration": ScopeRule(name: .childOfType("type_identifier")),
        "object_declaration": ScopeRule(name: .childOfType("type_identifier")),
        "function_declaration": ScopeRule(name: .childOfType("simple_identifier")),
    ]

    private static let rubyScopes = named("class", "module", "method", "singleton_method")

    private static let phpScopes = named(
        "class_declaration", "interface_declaration", "trait_declaration", "enum_declaration",
        "function_definition", "method_declaration", "namespace_definition")

    private static let bashScopes = named("function_definition")

    // Files found by name and by extension share one Spec, because scope rules are cached
    // per language name: a second Spec with different rules would be ignored or win at random.
    private static let bashSpec = Spec("Bash", scopes: bashScopes, tree_sitter_bash)
    private static let rubySpec = Spec("Ruby", scopes: rubyScopes, tree_sitter_ruby)
    private static let jsonSpec = Spec("JSON", tree_sitter_json)

    private static let byExtension: [String: Spec] = {
        var map: [String: Spec] = [:]
        func add(_ spec: Spec, _ extensions: String...) {
            for ext in extensions { map[ext] = spec }
        }
        add(Spec("Swift", scopes: swiftScopes, tree_sitter_swift), "swift")
        add(Spec("Python", scopes: pythonScopes, tree_sitter_python), "py", "pyi", "pyw")
        add(Spec("JavaScript", scopes: javaScriptScopes, tree_sitter_javascript), "js", "mjs", "cjs", "jsx")
        add(Spec("TypeScript", scopes: typeScriptScopes, tree_sitter_typescript), "ts", "mts", "cts")
        add(
            Spec(
                "TSX", bundleName: "TreeSitterTypeScript_TreeSitterTSX", scopes: typeScriptScopes,
                tree_sitter_tsx), "tsx")
        add(jsonSpec, "json", "jsonc", "json5")
        // tree-sitter-go lists call and definition captures before `(identifier) @variable`.
        add(Spec("Go", precedence: .earlierPatternWins, scopes: goScopes, tree_sitter_go), "go")
        add(Spec("Rust", scopes: rustScopes, tree_sitter_rust), "rs")
        add(Spec("C", scopes: cScopes, tree_sitter_c), "c", "h")
        add(
            Spec("CPP", scopes: cppScopes, tree_sitter_cpp),
            "cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++", "mm", "ipp")
        add(Spec("HTML", tree_sitter_html), "html", "htm", "xhtml")
        add(Spec("CSS", tree_sitter_css), "css")
        add(bashSpec, "sh", "bash", "zsh", "bashrc", "zshrc")
        add(rubySpec, "rb", "rake", "gemspec")
        add(Spec("YAML", tree_sitter_yaml), "yml", "yaml")
        add(Spec("TOML", tree_sitter_toml), "toml")
        add(Spec("Java", scopes: javaScopes, tree_sitter_java), "java")
        add(Spec("PHP", scopes: phpScopes, tree_sitter_php), "php", "phtml")
        add(Spec("Markdown", tree_sitter_markdown), "md", "markdown", "mdx")
        add(Spec("Kotlin", scopes: kotlinScopes, tree_sitter_kotlin), "kt", "kts")
        return map
    }()

    private static let byFileName: [String: Spec] = [
        "Makefile": bashSpec,
        "Dockerfile": bashSpec,
        "Podfile": rubySpec,
        "Gemfile": rubySpec,
        "Rakefile": rubySpec,
        "Package.resolved": jsonSpec,
    ]

    static func spec(forFileNamed fileName: String) -> Spec? {
        if let spec = byFileName[fileName] { return spec }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return byExtension[ext]
    }

    /// SPM resource bundles are copied into the app's Resources directory; the
    /// Products directory is checked too so app-hosted tests find them.
    private static func queriesURL(forBundleNamed bundleName: String) -> URL? {
        var containers: [URL] = []
        if let resources = Bundle.main.resourceURL { containers.append(resources) }
        containers.append(Bundle.main.bundleURL.deletingLastPathComponent())
        for container in containers {
            let url =
                container
                .appendingPathComponent("\(bundleName).bundle", isDirectory: true)
                .appendingPathComponent("Contents/Resources/queries", isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: LanguageConfiguration] = [:]
    nonisolated(unsafe) private static var scopeRulesCache: [String: ScopeRules] = [:]

    /// The parser and highlight queries for a file, or nil if the language is not bundled
    /// or its queries fail to load. Configurations are cached per language.
    static func configuration(forFileNamed fileName: String) -> LanguageConfiguration? {
        guard let spec = spec(forFileNamed: fileName) else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[spec.name] { return cached }
        guard let pointer = spec.language(), let queriesURL = queriesURL(forBundleNamed: spec.bundleName) else {
            NSLog("Grammar resources for \(spec.name) not found")
            return nil
        }
        do {
            let config = try LanguageConfiguration(pointer, name: spec.name, queriesURL: queriesURL)
            cache[spec.name] = config
            return config
        } catch {
            NSLog("Failed to load grammar \(spec.name): \(error)")
            return nil
        }
    }

    /// The file's scope rules resolved to grammar symbols, cached per language. Nil when
    /// the language is not bundled; empty when it has no rules.
    static func scopeRules(forFileNamed fileName: String) -> ScopeRules? {
        guard let config = configuration(forFileNamed: fileName) else { return nil }
        return scopeRules(forFileNamed: fileName, configuration: config)
    }

    /// As `scopeRules(forFileNamed:)`, for a caller that already holds the configuration.
    static func scopeRules(forFileNamed fileName: String, configuration: LanguageConfiguration) -> ScopeRules? {
        guard let spec = spec(forFileNamed: fileName) else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = scopeRulesCache[spec.name] { return cached }
        let rules = ScopeRules(spec.scopes, language: configuration.language)
        scopeRulesCache[spec.name] = rules
        return rules
    }
}
