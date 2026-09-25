import AppKit
import SwiftUI

/// The body of the Commit Failed alert: the line that names the failure, then the whole
/// output with a copy button in its corner.
struct CommitFailureAccessory: View {
    let subtitle: String
    let output: String
    /// Measured by the alert to size this view, so the text drawn here must use it too.
    let subtitleFont: NSFont
    /// Where the alert's title text starts, so the subtitle and the box line up under it.
    /// Set once the alert has laid out.
    var leadingInset: CGFloat = 0

    private static let spacing: CGFloat = 8
    /// The copy button's corner, kept clear of the output's text so the first lines
    /// wrap around it instead of running underneath.
    private static let buttonClearance = NSSize(width: 34, height: 30)

    /// Always two lines, so a one-line subtitle leaves its spare line as spacing.
    private var subtitleHeight: CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: subtitleFont) * 2)
    }

    /// The whole view's height, for the alert's fixed frame.
    var height: CGFloat {
        subtitleHeight + Self.spacing + ErrorAlert.detailSize.height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Text(subtitle)
                .font(Font(subtitleFont))
                .lineLimit(2)
                .truncationMode(.tail)
                .help(subtitle)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: subtitleHeight, alignment: .topLeading)
            OutputView(text: output, buttonClearance: Self.buttonClearance)
                .frame(height: ErrorAlert.detailSize.height)
                .overlay(alignment: .topTrailing) {
                    CopyButton(label: "Copy Output", action: copyOutput)
                        .padding(2)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .padding(5)
                }
        }
        .padding(.leading, leadingInset)
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
