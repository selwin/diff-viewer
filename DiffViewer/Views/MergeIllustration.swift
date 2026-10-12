import SwiftUI

/// Geometry the Merge sheet shares with the illustration, so the status box can sit under
/// the merge commit. Points are in the illustration's coordinates, origin top-left.
enum MergeOverviewLayout {
    static let illustrationWidth: CGFloat = 452
    static let illustrationHeight: CGFloat = 96
    static let mergeCommitX: CGFloat = 344
    static let mergeCommitY: CGFloat = 76
    /// The status box hugs its text, centred in a slot centred on the merge commit.
    static let statusSlotWidth: CGFloat = 216
    static let statusGap: CGFloat = 2
}

/// The incoming branch's lane carries its commits over and down into the current branch,
/// curving toward the merge marker, which gives the predicted outcome.
struct MergeIllustration: View {
    enum Marker {
        case neutral
        case clean
        case conflict
    }

    let sourceName: String
    let destinationName: String
    let marks: CommitMarks
    let commitsText: String?
    let marker: Marker
    let accessibilityLabel: String

    /// The incoming lane and the commit marks share this line; the current lane runs at the
    /// merge commit's.
    private static let incomingY: CGFloat = 20
    private static let incomingLaneStartX: CGFloat = 14
    /// Where the lane leaves the straight and curves down to the arrow tip.
    private static let curveStartX: CGFloat = 302
    private static let dotRadius: CGFloat = 4.5
    private static let dotSpacing: CGFloat = 24
    private static let commitsTextY: CGFloat = 4
    private static let countCapsuleHeight: CGFloat = 20
    private static let branchCapsuleHeight: CGFloat = 28
    /// Fits a four-digit count such as "1,234 commits"; longer counts truncate, and the full
    /// count is in the accessibility label.
    private static let countCapsuleMaxWidth: CGFloat = 116
    /// The minimum space on each side of the marks, against the incoming capsule and before
    /// the lane's curve.
    private static let marksGap: CGFloat = 8
    /// Keeps room for the widest marks on the straight part of the lane.
    private static let incomingCapsuleMaxWidth: CGFloat = curveStartX - countCapsuleMaxWidth - 2 * marksGap
    /// Leaves at least 60pt of dotted lane after the current capsule.
    private static let currentCapsuleMaxWidth: CGFloat = 261
    private static let currentLaneGap: CGFloat = 9
    private static let currentLaneEndX: CGFloat = 330
    private static let lineWidth: CGFloat = 1.5
    private static let haloRadius: CGFloat = 10
    private static let commitDotRadius: CGFloat = 6

    private static let accent = Color(nsColor: .controlAccentColor)
    private static let amber = Color(nsColor: .systemOrange)

    var body: some View {
        ZStack(alignment: .topLeading) {
            incomingCapsule
            currentCapsule
            mergeCommit
                .position(x: MergeOverviewLayout.mergeCommitX, y: MergeOverviewLayout.mergeCommitY)
        }
        .frame(
            width: MergeOverviewLayout.illustrationWidth, height: MergeOverviewLayout.illustrationHeight,
            alignment: .topLeading
        )
        // Behind everything, so it stays a lane; the reader shares the illustration's
        // coordinates, which is where the capsule's anchor resolves.
        .backgroundPreferenceValue(CurrentCapsuleBoundsKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    currentLane(startX: proxy[anchor].maxX + Self.currentLaneGap)
                }
            }
        }
        // The marks are centred in the lane's free stretch, which starts at the incoming
        // capsule's visible edge. Behind the capsules, like the current lane.
        .backgroundPreferenceValue(IncomingCapsuleBoundsKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let marksCenterX = (proxy[anchor].maxX + Self.curveStartX) / 2
                    ZStack(alignment: .topLeading) {
                        incomingLane(marksCenterX: marksCenterX)
                        visibleMarks(marksCenterX: marksCenterX)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Lanes

    /// The lane and the chevron share this tip, so the shaft meets the arrowhead.
    private static let arrowTip = CGPoint(x: MergeOverviewLayout.mergeCommitX, y: 60)

    /// The marks' interiors are cut out of the lane rather than painted over it, so the
    /// sheet's material shows through them.
    private func incomingLane(marksCenterX: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            IncomingLane(
                start: CGPoint(x: Self.incomingLaneStartX, y: Self.incomingY),
                curveStartX: Self.curveStartX,
                tip: Self.arrowTip
            )
            .stroke(Self.accent, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
            markInteriors(marksCenterX: marksCenterX).blendMode(.destinationOut)
        }
        .compositingGroup()
        .overlay {
            Chevron(tip: Self.arrowTip)
                .stroke(Self.accent, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private func currentLane(startX: CGFloat) -> some View {
        Path { path in
            guard startX < Self.currentLaneEndX else { return }
            path.move(to: CGPoint(x: startX, y: MergeOverviewLayout.mergeCommitY))
            path.addLine(to: CGPoint(x: Self.currentLaneEndX, y: MergeOverviewLayout.mergeCommitY))
        }
        // Round caps on near-zero dashes make dots.
        .stroke(
            Color(nsColor: .tertiaryLabelColor),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [0.1, 5]))
    }

    // MARK: Commit marks

    private func dotCenters(marksCenterX: CGFloat) -> [CGPoint] {
        guard case let .dots(count) = marks else { return [] }
        return (0..<count).map { index in
            let offset = CGFloat(index) - CGFloat(count - 1) / 2
            return CGPoint(x: marksCenterX + offset * Self.dotSpacing, y: Self.incomingY)
        }
    }

    private func dotsPath(marksCenterX: CGFloat) -> Path {
        Path { path in
            for center in dotCenters(marksCenterX: marksCenterX) {
                path.addEllipse(
                    in: CGRect(
                        x: center.x - Self.dotRadius, y: center.y - Self.dotRadius,
                        width: Self.dotRadius * 2, height: Self.dotRadius * 2))
            }
        }
    }

    private func commitsLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Self.accent)
            .lineLimit(1)
            .fixedSize()
    }

    /// Hugs its text up to the cap, then truncates; the full count is in the illustration's
    /// accessibility label. The interior lays out the same label, hidden, so it matches the
    /// visible capsule without measuring it.
    private func countCapsule(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Self.accent)
            .lineLimit(1)
            .truncationMode(.tail)
            // Centred by its line box, the text reads low in the pill; lift it to the eye, as in the title bar pickers.
            .offset(y: -1)
            .padding(.horizontal, 12)
            .frame(height: Self.countCapsuleHeight)
    }

    /// A fixed outer frame, not `maxWidth`, so the capsule inside keeps hugging its text
    /// while both the outline and the cut-out share one position and cap.
    private func placedCountCapsule(_ capsule: some View, marksCenterX: CGFloat) -> some View {
        capsule
            .frame(width: Self.countCapsuleMaxWidth)
            .position(x: marksCenterX, y: Self.incomingY)
    }

    @ViewBuilder
    private func markInteriors(marksCenterX: CGFloat) -> some View {
        switch marks {
        case .dots:
            dotsPath(marksCenterX: marksCenterX).fill(.black)
        case .capsule:
            if let commitsText {
                placedCountCapsule(
                    countCapsule(commitsText)
                        .hidden()
                        .background(Capsule().fill(.black)),
                    marksCenterX: marksCenterX)
            }
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func visibleMarks(marksCenterX: CGFloat) -> some View {
        switch marks {
        case .dots:
            dotsPath(marksCenterX: marksCenterX).stroke(Self.accent, lineWidth: Self.lineWidth)
            if let commitsText {
                commitsLabel(commitsText)
                    .position(x: marksCenterX, y: Self.commitsTextY)
            }
        case .capsule:
            if let commitsText {
                placedCountCapsule(
                    countCapsule(commitsText)
                        .overlay(Capsule().stroke(Self.accent, lineWidth: Self.lineWidth)),
                    marksCenterX: marksCenterX)
            }
        case .none:
            EmptyView()
        }
    }

    // MARK: Branches

    // The outer fixed frames cap the width without stretching: a short name keeps its
    // natural width, and a long one truncates in the middle.

    /// The anchor is taken inside the width cap, so the marks centre on the capsule's visible
    /// edge rather than the cap's.
    private var incomingCapsule: some View {
        branchCapsule(
            sourceName, fill: Self.accent,
            iconStyle: AnyShapeStyle(AccentForeground.color), textStyle: AnyShapeStyle(AccentForeground.color)
        )
        .anchorPreference(key: IncomingCapsuleBoundsKey.self, value: .bounds) { $0 }
        .frame(width: Self.incomingCapsuleMaxWidth, alignment: .leading)
        .padding(.top, Self.incomingY - Self.branchCapsuleHeight / 2)
    }

    /// The anchor is taken inside the width cap, so the lane starts at the capsule's visible
    /// edge rather than the cap's.
    private var currentCapsule: some View {
        branchCapsule(
            destinationName, fill: MergeSheetPalette.cardFill, border: MergeSheetPalette.cardBorder,
            iconStyle: AnyShapeStyle(.secondary), textStyle: AnyShapeStyle(.primary)
        )
        .anchorPreference(key: CurrentCapsuleBoundsKey.self, value: .bounds) { $0 }
        .frame(width: Self.currentCapsuleMaxWidth, alignment: .leading)
        .padding(.top, MergeOverviewLayout.mergeCommitY - Self.branchCapsuleHeight / 2)
    }

    private func branchCapsule(
        _ name: String, fill: Color, border: Color? = nil, iconStyle: AnyShapeStyle, textStyle: AnyShapeStyle
    ) -> some View {
        HStack(spacing: 6) {
            Image(.gitBranch)
                .resizable()
                .frame(width: 13, height: 13)
                .foregroundStyle(iconStyle)
            Text(verbatim: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textStyle)
                .lineLimit(1)
                .truncationMode(.middle)
                // Centred by its line box, the text reads low in the pill; lift it to the eye, as in the title bar pickers.
                .offset(y: -1)
        }
        .padding(.leading, 9)
        .padding(.trailing, 12)
        .frame(height: Self.branchCapsuleHeight)
        .background {
            Capsule().fill(fill)
            if let border { Capsule().strokeBorder(border, lineWidth: 0.5) }
        }
        .help(name)
    }

    // MARK: Merge commit

    @ViewBuilder
    private var mergeCommit: some View {
        switch marker {
        case .clean:
            ZStack {
                halo(Self.accent)
                circle(radius: Self.commitDotRadius, Self.accent)
            }
        case .conflict:
            ZStack {
                halo(Self.amber)
                circle(radius: Self.commitDotRadius, Self.amber)
            }
        case .neutral:
            circle(radius: Self.commitDotRadius, Color(nsColor: .tertiaryLabelColor))
        }
    }

    private func halo(_ color: Color) -> some View {
        circle(radius: Self.haloRadius, color.opacity(0.25))
    }

    private func circle(radius: CGFloat, _ color: Color) -> some View {
        Circle().fill(color).frame(width: radius * 2, height: radius * 2)
    }
}

/// The current branch capsule's visible bounds, where the dotted lane starts.
private struct CurrentCapsuleBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The incoming branch capsule's visible bounds, where the free stretch of its lane starts.
private struct IncomingCapsuleBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Runs right from under the incoming capsule, then curves down to the arrow tip,
/// arriving vertically.
private struct IncomingLane: Shape {
    let start: CGPoint
    let curveStartX: CGFloat
    let tip: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: CGPoint(x: curveStartX, y: start.y))
        path.addQuadCurve(to: tip, control: CGPoint(x: tip.x, y: start.y))
        return path
    }
}

/// An open arrowhead pointing down at `tip`.
private struct Chevron: Shape {
    private static let armHalfWidth: CGFloat = 3.5
    private static let armRise: CGFloat = 3.5

    let tip: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: tip.x - Self.armHalfWidth, y: tip.y - Self.armRise))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x + Self.armHalfWidth, y: tip.y - Self.armRise))
        return path
    }
}
