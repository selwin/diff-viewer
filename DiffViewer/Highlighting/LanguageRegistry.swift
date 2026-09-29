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

    private static let byExtension: [String: Spec] = {
        var map: [String: Spec] = [:]
        func add(_ spec: Spec, _ extensions: String...) {
            for ext in extensions { map[ext] = spec }
        }
        add(Spec("Swift", scopes: swiftScopes, tree_sitter_swift), "swift")
        add(Spec("Python", tree_sitter_python), "py", "pyi", "pyw")
        add(Spec("JavaScript", tree_sitter_javascript), "js", "mjs", "cjs", "jsx")
        add(Spec("TypeScript", tree_sitter_typescript), "ts", "mts", "cts")
        add(Spec("TSX", bundleName: "TreeSitterTypeScript_TreeSitterTSX", tree_sitter_tsx), "tsx")
        add(Spec("JSON", tree_sitter_json), "json", "jsonc", "json5")
        // tree-sitter-go lists call and definition captures before `(identifier) @variable`.
        add(Spec("Go", precedence: .earlierPatternWins, tree_sitter_go), "go")
        add(Spec("Rust", tree_sitter_rust), "rs")
        add(Spec("C", tree_sitter_c), "c", "h")
        add(Spec("CPP", tree_sitter_cpp), "cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++", "mm", "ipp")
        add(Spec("HTML", tree_sitter_html), "html", "htm", "xhtml")
        add(Spec("CSS", tree_sitter_css), "css")
        add(Spec("Bash", tree_sitter_bash), "sh", "bash", "zsh", "bashrc", "zshrc")
        add(Spec("Ruby", tree_sitter_ruby), "rb", "rake", "gemspec")
        add(Spec("YAML", tree_sitter_yaml), "yml", "yaml")
        add(Spec("TOML", tree_sitter_toml), "toml")
        add(Spec("Java", tree_sitter_java), "java")
        add(Spec("PHP", tree_sitter_php), "php", "phtml")
        add(Spec("Markdown", tree_sitter_markdown), "md", "markdown", "mdx")
        add(Spec("Kotlin", tree_sitter_kotlin), "kt", "kts")
        return map
    }()

    private static let byFileName: [String: Spec] = [
        "Makefile": Spec("Bash", tree_sitter_bash),
        "Dockerfile": Spec("Bash", tree_sitter_bash),
        "Podfile": Spec("Ruby", tree_sitter_ruby),
        "Gemfile": Spec("Ruby", tree_sitter_ruby),
        "Rakefile": Spec("Ruby", tree_sitter_ruby),
        "Package.resolved": Spec("JSON", tree_sitter_json),
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
        guard let spec = spec(forFileNamed: fileName),
            let config = configuration(forFileNamed: fileName)
        else { return nil }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = scopeRulesCache[spec.name] { return cached }
        let rules = ScopeRules(spec.scopes, language: config.language)
        scopeRulesCache[spec.name] = rules
        return rules
    }
}
