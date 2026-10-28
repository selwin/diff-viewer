import SwiftUI

/// Caps the picker's reported ideal width so long labels can truncate instead of forcing
/// the toolbar item into overflow. Lays out exactly one child.
struct CappedWidth: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        assert(subviews.count == 1)
        // The ideal width, not the proposed one: the toolbar proposes the width it measured
        // last time, so honouring it would freeze the item at the size of its old label.
        let ideal = subviews[0].sizeThatFits(ProposedViewSize(width: nil, height: proposal.height))
        // Caps the ideal width, never the minimum: a picker squeezed below it would overlap its neighbour.
        let minimum = subviews[0].sizeThatFits(.zero).width
        return CGSize(width: max(min(ideal.width, maximumWidth), minimum), height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        assert(subviews.count == 1)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// Draws a part of the pill at a fraction of its width, cut from the trailing edge, and
/// takes no clicks while it collapses.
struct Collapsing: ViewModifier {
    let width: Double

    func body(content: Content) -> some View {
        WidthFractionLayout(fraction: width) { content }
            .clipped()
            .opacity(width)
            .allowsHitTesting(width == 1)
    }
}

/// Reports a fraction of the child's ideal width without compressing its content, so the
/// label keeps its shape as the part narrows. Lays out exactly one child.
struct WidthFractionLayout: Layout {
    let fraction: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        assert(subviews.count == 1)
        let ideal = idealSize(of: subviews[0], height: proposal.height)
        return CGSize(width: ideal.width * fraction, height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        assert(subviews.count == 1)
        let ideal = idealSize(of: subviews[0], height: proposal.height)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(ideal))
    }

    /// Measured at an unspecified width, never the narrowed one, so the label can't truncate.
    private func idealSize(of subview: LayoutSubview, height: CGFloat?) -> CGSize {
        subview.sizeThatFits(ProposedViewSize(width: nil, height: height))
    }
}
