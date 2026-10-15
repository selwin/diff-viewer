import SwiftUI

/// The Pull Request mode's left card: the link field, what it compares against (or what is
/// wrong with the link), and the base's well.
struct ComparePullRequestColumn: View {
    let model: CompareWindowModel
    @Bindable var pullRequest: PullRequestCompareModel
    var focus: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 6) {
            field
            message
            CompareWell(side: .base, content: model.wellContent(.base), placeholder: model.wellPlaceholder(.base))
        }
        .padding(8)
        .compareCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Base")
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Paste a pull request link", text: $pullRequest.input)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused(focus)
                .disabled(model.isOpening)
                .onSubmit { pullRequest.resolveNow() }
                .accessibilityLabel("Pull request link")
            if !pullRequest.input.isEmpty {
                Button {
                    pullRequest.input = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .disabled(model.isOpening)
                .accessibilityLabel("Clear link")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Color(nsColor: .tertiarySystemFill)))
    }

    /// The error replaces the note, so only one line explains the field at a time.
    @ViewBuilder
    private var message: some View {
        Group {
            if let error = pullRequest.inputError {
                Text(error).foregroundStyle(Color(nsColor: .systemRed))
            } else if let note = pullRequest.note {
                Text(note).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
