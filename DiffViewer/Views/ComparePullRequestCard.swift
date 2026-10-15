import SwiftUI

/// The Pull Request mode's right card: which pull request the link names, how far its
/// resolution has got, and the target's well.
struct ComparePullRequestCard: View {
    let model: CompareWindowModel
    let pullRequest: PullRequestCompareModel

    var body: some View {
        VStack(spacing: 6) {
            detail
            CompareWell(
                side: .target, content: model.wellContent(.target), placeholder: model.wellPlaceholder(.target))
        }
        .padding(8)
        .compareCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compare")
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 4) {
            if let request = pullRequest.request {
                Text(verbatim: "PR #\(request.number)").font(.system(size: 22, weight: .semibold))
                Text(verbatim: request.repository.fullName).font(.system(size: 14)).foregroundStyle(.secondary)
                state
            } else {
                Text("No pull request").font(.system(size: 13)).foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var state: some View {
        if let text = pullRequest.resolutionText {
            HStack(spacing: 6) {
                if case .resolving = pullRequest.resolution {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                }
                Text(text).font(.system(size: 13)).foregroundStyle(isFailed ? Color(nsColor: .systemRed) : .secondary)
            }
            .padding(.top, 6)
        }
    }

    private var isFailed: Bool {
        if case .failed = pullRequest.resolution { return true }
        return false
    }
}
