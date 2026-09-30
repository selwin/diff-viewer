import Foundation
import Testing

@testable import DiffViewer

/// How an error message is split between the alert's text and its scrolling detail.
@MainActor
@Suite struct ErrorAlertTests {
    @Test func shortMessageIsShownWhole() {
        let (summary, detail) = ErrorAlert.layout(for: "  fatal: not a git repository\n")
        #expect(summary == "fatal: not a git repository")
        #expect(detail == nil)
    }

    /// Six lines are still short; a seventh makes it long, however the lines are separated.
    @Test(arguments: [
        (lineCount: 6, separator: "\n", isLong: false),
        (lineCount: 7, separator: "\n", isLong: true),
        (lineCount: 7, separator: "\r\n", isLong: true),
    ])
    func onlyAMessagePastSixLinesIsLong(lineCount: Int, separator: String, isLong: Bool) {
        let message = (1...lineCount).map { "line \($0)" }.joined(separator: separator)
        let (summary, detail) = ErrorAlert.layout(for: message)
        #expect(summary == (isLong ? "line 1" : message))
        #expect(detail == (isLong ? message : nil))
    }

    /// `ProcessError` joins its prefix to the hook output with ": ", so one line can hold
    /// everything; the summary must stay short on its own.
    @Test func aLongSingleLineGetsABoundedSummary() {
        let message = String(repeating: "x", count: 501)
        let (summary, detail) = ErrorAlert.layout(for: message)
        #expect(summary == String(repeating: "x", count: 160) + "…")
        #expect(detail == message)
        #expect(ErrorAlert.layout(for: String(repeating: "x", count: 500)).detail == nil)
    }
}
