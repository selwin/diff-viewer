import Foundation
import Testing
@testable import DiffViewer

struct DifftRunnerTests {
    @Test func decodesJSONWithMissingSides() throws {
        let json = """
        {"chunks":[[{"rhs":{"line_number":2,"changes":[{"start":0,"end":4,"content":"new1","highlight":"normal"}]}},
        {"lhs":{"line_number":1,"changes":[{"start":16,"end":17,"content":"1","highlight":"normal"}]},
         "rhs":{"line_number":1,"changes":[{"start":16,"end":17,"content":"b","highlight":"normal"}]}}]],
         "language":"Text","path":"p2.txt","status":"changed"}
        """
        let file = try JSONDecoder().decode(DifftFile.self, from: Data(json.utf8))
        let hints = DifftHints(file: file)
        #expect(hints.pairs.map { $0.old } == [1])
        #expect(hints.newChanges[2] == [0..<4])
        #expect(hints.oldChanges[1] == [16..<17])
    }

    @Test func decodesUnchangedFileWithoutChunks() throws {
        let file = try JSONDecoder().decode(DifftFile.self, from: Data(#"{"language":"Text","path":"x","status":"unchanged"}"#.utf8))
        #expect(file.chunks == nil)
        #expect(DifftHints(file: file).pairs.isEmpty)
    }

    @Test func bundledBinaryProducesSyntaxAwareHints() async throws {
        let old = Data("func foo(a: Int) -> Int {\n    let x = a + 1\n    return x\n}\n".utf8)
        let new = Data("func foo(a: Int, b: Int) -> Int {\n    let x = a + b\n    return x\n}\n".utf8)
        let file = try await DifftRunner.run(old: old, new: new, fileName: "a.swift")
        #expect(file.language == "Swift")
        let hints = DifftHints(file: file)
        #expect(hints.pairs.contains { $0.old == 1 && $0.new == 1 })
        #expect(hints.oldChanges[1] == [16..<17])
    }

    @Test func engineHidesAndShowsWhitespaceChanges() async {
        let sources = DiffEngine.Sources(old: Data("x = 1\n".utf8), new: Data("x  =  1\n".utf8), fileName: "w.py")
        guard case let .text(hidden) = await DiffEngine.build(sources, hideWhitespace: true, cache: .bundled(), priority: .foreground) else { Issue.record("expected text"); return }
        #expect(hidden.rows.map(\.kind) == [.equal])
        guard case let .text(shown) = await DiffEngine.build(sources, hideWhitespace: false, cache: .bundled(), priority: .foreground) else { Issue.record("expected text"); return }
        #expect(shown.rows.map(\.kind) == [.modified])
    }

    @Test func engineDetectsBinaryAndIdentical() async {
        let bin = DiffEngine.Sources(old: Data([0, 1, 2]), new: Data([0, 1, 3]), fileName: "a.bin")
        guard case .binary = await DiffEngine.build(bin, hideWhitespace: true, cache: .bundled(), priority: .foreground) else { Issue.record("expected binary"); return }
        let same = DiffEngine.Sources(old: Data("a".utf8), new: Data("a".utf8), fileName: "a.txt")
        guard case .identical = await DiffEngine.build(same, hideWhitespace: true, cache: .bundled(), priority: .foreground) else { Issue.record("expected identical"); return }
    }
}
