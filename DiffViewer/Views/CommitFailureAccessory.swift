import AppKit
import SwiftUI

/// The body of the Commit Failed alert: its title, a sentence that names the failure, then
/// the whole output with a copy button in its corner.
///
/// The title is drawn here rather than by NSAlert, which leaves more room under its own
/// title than a message needs; here the three share one left edge and chosen gaps.
struct CommitFailureAccessory: View {
    let summary: FailureSummaryView
    let output: String

    /// NSAlert's own title font.
    private static let titleFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    /// NSAlert's gap between its title and its message.
    private static let titleSpacing: CGFloat = 10
    private static let boxSpacing: CGFloat = 12
    /// The copy button's corner, kept clear of the output's text so the first lines
    /// wrap around it instead of running underneath.
    private static let buttonClearance = NSSize(width: 34, height: 30)

    /// The whole view's height, for the alert's fixed frame. A summary shorter than its
    /// two lines leaves the difference to the output box.
    var height: CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: Self.titleFont)) + Self.titleSpacing + summary.height
            + Self.boxSpacing + ErrorAlert.detailSize.height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Commit Failed")
                .font(Font(Self.titleFont))
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, Self.titleSpacing)
            summary
                .padding(.bottom, Self.boxSpacing)
            OutputView(text: output, buttonClearance: Self.buttonClearance)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    CopyButton(label: "Copy Output", action: copyOutput)
                        .padding(2)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .padding(5)
                }
        }
    }

    private func copyOutput() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }
}

/// The alert's shared output scroller, with its top-trailing corner left clear.
private struct OutputView: NSViewRepresentable {
    let text: String
    let buttonClearance: NSSize

    func makeNSView(context: Context) -> DetailScrollView {
        let view = ErrorAlert.detailView(text)
        view.topTrailingExclusion = buttonClearance
        return view
    }

    func updateNSView(_ view: DetailScrollView, context: Context) {}
}
