import SwiftUI

/// One side's card: a search field over its ref list, and the well showing the choice.
struct CompareRefColumn: View {
    @Bindable var model: CompareWindowModel
    let side: CompareWindowModel.Side
    var focus: FocusState<CompareWindowModel.Side?>.Binding

    private var query: Binding<String> {
        side == .base ? $model.baseQuery : $model.targetQuery
    }

    var body: some View {
        VStack(spacing: 6) {
            searchField
            list
            CompareWell(model: model, side: side)
        }
        .padding(8)
        .background {
            let card = RoundedRectangle(cornerRadius: 20, style: .continuous)
            card.fill(Color(nsColor: .controlBackgroundColor))
                .overlay { card.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(side == .base ? "Base" : "Compare")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search branches and tags", text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused(focus, equals: side)
                .onKeyPress(.upArrow) { move(by: -1) }
                .onKeyPress(.downArrow) { move(by: 1) }
                .onKeyPress(.tab) {
                    focus.wrappedValue = side == .base ? .target : .base
                    return .handled
                }
            if !query.wrappedValue.isEmpty {
                Button {
                    query.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Color(nsColor: .tertiarySystemFill)))
    }

    private func move(by offset: Int) -> KeyPress.Result {
        model.moveSelection(side, by: offset)
        return .handled
    }

    @ViewBuilder
    private var list: some View {
        if model.refList == .loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let text = model.emptyText(side) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.rows(side)) { ref in
                            CompareRefRow(model: model, side: side, ref: ref) {
                                // Rows never take focus, so ↑/↓ follow the last click.
                                focus.wrappedValue = side
                                model.select(ref, for: side)
                            }
                            .id(ref.id)
                        }
                    }
                }
                // Keyboard moves can leave the choice out of view.
                .onChange(of: model.selection(side)?.id) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }
}

/// A branch, remote branch or tag. The choice shows as a tinted icon and a check, never a fill.
private struct CompareRefRow: View {
    let model: CompareWindowModel
    let side: CompareWindowModel.Side
    let ref: GitRef
    let onSelect: () -> Void
    @State private var isHovered = false

    private var isSelected: Bool { model.selection(side) == ref }
    private var tint: Color { side == .base ? .secondary : .accentColor }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                icon
                    .foregroundStyle(isSelected ? tint : Color.secondary.opacity(0.75))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: ref.name).font(.system(size: 14)).lineLimit(1).truncationMode(.tail)
                    Text(model.subtitle(for: ref)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if model.isCurrentBranch(ref) {
                    Text("HEAD")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .quaternarySystemFill), in: .rect(cornerRadius: 8))
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                Color.primary.opacity(isHovered ? 0.05 : 0), in: .rect(cornerRadius: 12, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(ref.name), \(kindName), \(model.subtitle(for: ref))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var kindName: String {
        switch ref.kind {
        case .local: "local branch"
        case .remote: "remote branch"
        case .tag: "tag"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch ref.kind {
        case .local:
            Image(.gitBranch).renderingMode(.template).resizable().scaledToFit().frame(width: 15, height: 15)
        case .remote:
            Image(systemName: "cloud").font(.system(size: 14))
        case .tag:
            Image(systemName: "tag").font(.system(size: 14))
        }
    }
}
