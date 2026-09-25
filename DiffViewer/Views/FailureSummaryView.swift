import AppKit
import SwiftUI

/// The Commit Failed alert's subtitle: a caption saying the model is at work, then its
/// summary in a fixed two-line slot, so nothing moves when the text arrives.
struct FailureSummaryView: View {
    let model: FailureSummaryModel
    /// Measured by the alert to size this view, so the text drawn here must use them too.
    let font: NSFont
    let captionFont: NSFont
    /// Decided once: a model that starts at its fallback never shows the caption, and the
    /// alert's height must not change after it opens.
    let showsCaption: Bool

    private static let captionSpacing: CGFloat = 4
    private static let reveal = Animation.easeInOut(duration: 0.2)

    init(model: FailureSummaryModel, font: NSFont, captionFont: NSFont) {
        self.model = model
        self.font = font
        self.captionFont = captionFont
        showsCaption = model.state == .loading
    }

    private var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    private var captionHeight: CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: captionFont))
    }

    /// Always two lines, so a one-line summary leaves its spare line as spacing.
    private var slotHeight: CGFloat {
        ceil(lineHeight * 2)
    }

    /// The whole view's height, for the alert's fixed frame.
    var height: CGFloat {
        slotHeight + (showsCaption ? captionHeight + Self.captionSpacing : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.captionSpacing) {
            if showsCaption {
                caption
            }
            slot
        }
        .animation(Self.reveal, value: model.state)
        .task { await model.run() }
    }

    private var caption: some View {
        let text = isReady ? "Summarized on device" : "Summarizing on device…"
        return Text("\(Image(systemName: "sparkles")) \(text)")
            .font(Font(captionFont))
            .foregroundStyle(.secondary)
            // The row stays when the fallback shows, so the text below does not move.
            .opacity(isFallback ? 0 : 1)
            .frame(height: captionHeight, alignment: .leading)
    }

    private var slot: some View {
        ZStack(alignment: .topLeading) {
            if let summary {
                Text(summary)
                    .font(Font(font))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(summary)
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: slotHeight, alignment: .topLeading)
    }

    /// Two bars where the two lines of text will be.
    private var placeholder: some View {
        let barHeight = (lineHeight * 0.6).rounded()
        let inset = (lineHeight - barHeight) / 2
        return GeometryReader { proxy in
            VStack(alignment: .leading, spacing: lineHeight - barHeight) {
                bar(width: proxy.size.width, height: barHeight)
                bar(width: proxy.size.width * 0.58, height: barHeight)
            }
            .padding(.top, inset)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Summarizing error")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(Color.primary.opacity(0.07))
            .frame(width: width, height: height)
    }

    private var summary: String? {
        switch model.state {
        case .loading: nil
        case let .ready(text), let .fallback(text): text
        }
    }

    private var isReady: Bool {
        if case .ready = model.state { true } else { false }
    }

    private var isFallback: Bool {
        if case .fallback = model.state { true } else { false }
    }
}
