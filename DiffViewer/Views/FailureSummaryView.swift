import AppKit
import SwiftUI

/// The Commit Failed alert's subtitle: two placeholder bars while the model works, then
/// its summary, one or two lines tall; the output box below takes whatever it leaves.
struct FailureSummaryView: View {
    let model: FailureSummaryModel
    /// Measured by the alert to size this view, so the text drawn here must use it too.
    let font: NSFont

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private static let fade = Animation.easeInOut(duration: 0.2)
    private static let sweepReveal = Animation.easeOut(duration: 0.6)
    /// One shimmer cycle: a sweep across the slot, then a rest with the highlight off it.
    private static let sweepDuration: Double = 1.1
    private static let cycleDuration: Double = 1.6
    /// How far the highlight leans: points right per point up, so line 2 lights up just
    /// after line 1.
    private static let slant: CGFloat = 0.5
    /// The highlight band's width along a line, as a share of the slot's width.
    private static let bandShare: CGFloat = 0.5
    private static let secondBarShare: CGFloat = 0.58

    private var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    /// The most this view takes: two lines, the placeholder's height and a summary's limit.
    var height: CGFloat {
        ceil(lineHeight * 2)
    }

    var body: some View {
        slot
            .onChange(of: model.state) { _, state in
                if case let .ready(text) = state {
                    AccessibilityNotification.Announcement(text).post()
                }
            }
            .task { await model.run() }
    }

    private var slot: some View {
        ZStack(alignment: .topLeading) {
            switch model.state {
            case .loading:
                // Removed at once where the reveal picks up the shimmer's sweep; with Reduce
                // Motion the bars fade out as the text fades in, so the slot never goes blank.
                placeholder
                    .frame(height: height)
                    .transition(reduceMotion ? .opacity : .identity)
            case let .ready(text):
                summaryText(text, isSummary: true)
                    .transition(reduceMotion ? .opacity : SweepReveal.transition)
            case let .fallback(text):
                summaryText(text, isSummary: false).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Keeps the reveal's blur inside the slot.
        .clipped()
        .animation(isReady && !reduceMotion ? Self.sweepReveal : Self.fade, value: model.state)
    }

    /// Laid out across the whole slot, so the reveal's sweep spans it as the shimmer does.
    /// The model's summary ends in a quiet sparkle, so it reads apart from the fallback,
    /// which quotes the output. At full size the symbol is taller than a line of text and
    /// would push its line apart from the other. A no-break space keeps it from wrapping
    /// onto a line of its own.
    private func summaryText(_ text: String, isSummary: Bool) -> some View {
        let sparkle = Text("\u{00A0}\(Image(systemName: "sparkles"))")
            .font(Font(NSFont.systemFont(ofSize: font.pointSize * 0.8)))
            .foregroundStyle(.secondary)
        return (isSummary ? Text(text) + sparkle : Text(text))
            .font(Font(font))
            .lineLimit(2)
            .truncationMode(.tail)
            .help(isSummary ? "\(text)\n\nSummarized on device" : text)
            .accessibilityLabel(isSummary ? "\(text) Summarized on device." : text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Two bars where the two lines of text will be, lit by one gradient across both.
    private var placeholder: some View {
        GeometryReader { proxy in
            Group {
                if reduceMotion {
                    barColors.base
                } else {
                    TimelineView(.animation) { context in
                        shimmer(size: proxy.size, at: context.date)
                    }
                }
            }
            .mask(alignment: .topLeading) { bars(width: proxy.size.width) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Summarizing error")
    }

    /// Each bar covers its line's x-height band, where the text's lowercase letters will sit.
    private func bars(width: CGFloat) -> some View {
        let baseline = NSLayoutManager().defaultBaselineOffset(for: font)
        return ZStack(alignment: .topLeading) {
            Capsule()
                .frame(width: width, height: font.xHeight)
                .padding(.top, baseline - font.xHeight)
            Capsule()
                .frame(width: width * Self.secondBarShare, height: font.xHeight)
                .padding(.top, lineHeight + baseline - font.xHeight)
        }
    }

    /// The gradient at `date`. Its axis leans by `slant`, and its centre eases from off
    /// the slot's left edge to off its right edge, then rests there until the next cycle.
    private func shimmer(size: CGSize, at date: Date) -> some View {
        let band = size.width * Self.bandShare
        let reach = band / 2 + Self.slant * size.height / 2
        let time = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycleDuration)
        let progress = UnitCurve.easeInOut.value(at: min(time / Self.sweepDuration, 1))
        let centerX = -reach + (size.width + 2 * reach) * progress
        // Tilted down by `slant` and shortened to match, so the band still spans `band`
        // along each line and its edges lean back by `slant` as they go down.
        let scale = 1 + Self.slant * Self.slant
        let axis = CGSize(width: band / scale, height: band * Self.slant / scale)
        let start = CGPoint(x: centerX - axis.width / 2, y: size.height / 2 - axis.height / 2)
        let end = CGPoint(x: centerX + axis.width / 2, y: size.height / 2 + axis.height / 2)
        let colors = barColors
        return LinearGradient(
            colors: [colors.base, colors.highlight, colors.base],
            startPoint: UnitPoint(x: start.x / size.width, y: start.y / size.height),
            endPoint: UnitPoint(x: end.x / size.width, y: end.y / size.height))
    }

    /// Tints of the text colour, so the bars follow the alert's material in either
    /// appearance.
    private var barColors: (base: Color, highlight: Color) {
        contrast == .increased
            ? (Color.primary.opacity(0.12), Color.primary.opacity(0.20))
            : (Color.primary.opacity(0.07), Color.primary.opacity(0.14))
    }

    private var isReady: Bool {
        if case .ready = model.state { true } else { false }
    }
}

/// Uncovers the text left to right behind a soft edge while it sharpens, as if the
/// shimmer's last sweep left it behind.
private struct SweepReveal: ViewModifier, Animatable {
    /// 0 hidden and blurred, 1 fully shown and sharp.
    var progress: CGFloat

    /// The mask's soft edge, as a share of the text's width.
    private static let softEdge: CGFloat = 0.25
    private static let blur: CGFloat = 5

    static let transition = AnyTransition.modifier(
        active: SweepReveal(progress: 0), identity: SweepReveal(progress: 1))

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // The edge runs from fully off the left (clear everywhere) to fully off the right.
        let edgeEnd = progress * (1 + Self.softEdge)
        return
            content
            .blur(radius: (1 - progress) * Self.blur)
            .mask {
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: UnitPoint(x: edgeEnd - Self.softEdge, y: 0.5),
                    endPoint: UnitPoint(x: edgeEnd, y: 0.5))
            }
    }
}
