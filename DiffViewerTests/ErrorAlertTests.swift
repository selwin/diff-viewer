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

    @Test func sixLinesAreStillShort() {
        let message = (1...6).map { "line \($0)" }.joined(separator: "\n")
        #expect(ErrorAlert.layout(for: message).detail == nil)
    }

    @Test func aSeventhLineMakesItLong() {
        let message = (1...7).map { "line \($0)" }.joined(separator: "\n")
        let (summary, detail) = ErrorAlert.layout(for: message)
        #expect(summary == "line 1")
        #expect(detail == message)
    }

    @Test func crlfLinesCountAsLines() {
        let message = (1...7).map { "line \($0)" }.joined(separator: "\r\n")
        let (summary, detail) = ErrorAlert.layout(for: message)
        #expect(summary == "line 1")
        #expect(detail == message)
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

    /// A pre-commit hook's output: the first line names the failure, the rest scrolls.
    @Test func longMessageKeepsItsFirstLineAsTheSummary() {
        let message = (1...300).map { "pre-commit: line \($0)" }.joined(separator: "\n")
        let (summary, detail) = ErrorAlert.layout(for: message)
        #expect(summary == "pre-commit: line 1")
        #expect(detail == message)
    }
}
