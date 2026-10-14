import SwiftUI

/// The root of a Compare window: finds the repository window it belongs to, builds the
/// model once, and closes itself when that window is gone.
struct CompareWindowRoot: View {
    let target: CompareWindowTarget?
    let services: AppServices
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var model: CompareWindowModel?

    var body: some View {
        // Clear underneath so the modifiers below always have a view to attach to.
        ZStack {
            Color.clear
            if let model {
                CompareWindow(model: model, dismiss: { dismissWindow() })
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .navigationTitle("Compare")
        .background {
            if let target { CompareWindowAccessor(owner: target.owner, services: services) }
        }
        .task { await start() }
        .onDisappear { model?.close() }
    }

    private func start() async {
        guard model == nil else { return }
        let coordinator = services.coordinator
        guard let owner = target?.owner, let client = coordinator.client(for: owner) else {
            dismissWindow()
            return
        }
        let model = CompareWindowModel(
            client: client, currentBranch: coordinator.windows[owner]?.currentBranchName,
            open: { [coordinator] range in coordinator.openComparison(owner: owner, range: range) })
        self.model = model
        #if DEBUG
            if let names = DebugLaunchOptions.compareWindowSelection {
                await model.load(selecting: names.base, names.target)
                return
            }
        #endif
        await model.load()
    }
}

/// Two cards, base and compare, with the preview and the swap button overlaid where they
/// meet, and the Cancel and Compare buttons below.
struct CompareWindow: View {
    @Bindable var model: CompareWindowModel
    let dismiss: () -> Void
    @FocusState private var focus: CompareWindowModel.Side?

    var body: some View {
        VStack(spacing: 0) {
            CompareModeCapsule()
                .frame(height: 60)
            HStack(spacing: 12) {
                CompareRefColumn(model: model, side: .base, focus: $focus)
                CompareRefColumn(model: model, side: .target, focus: $focus)
            }
            .padding(.horizontal, 12)
            // Overlays, not part of the row, so neither moves with the names' lengths.
            .overlay(alignment: .bottom) {
                CompareSwapButton(model: model).padding(.bottom, 19)
            }
            .overlay(alignment: .bottom) {
                CompareChurnPill(model: model).offset(y: 14)
            }
            footer
        }
        // The hidden title bar still reserves its safe area; the title area is ours.
        .ignoresSafeArea(.container, edges: .top)
        // Not `.defaultFocus`: it holds focus on Base, so a click or ⇥ never reaches Compare.
        .onAppear { focus = .base }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = model.openError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .lineLimit(2)
                    .accessibilityLabel("Couldn't compare: \(error)")
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Text("Cancel").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(SheetCapsuleButtonStyle(appearance: .neutral))
            .keyboardShortcut(.cancelAction)
            Button(action: compare) {
                HStack(spacing: 6) {
                    if model.isOpening {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    }
                    Text("Compare").font(.system(size: 13, weight: .semibold))
                    Text("⌘↩")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.8)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(SheetCapsuleButtonStyle(appearance: .prominent))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canCompare)
            .help("Compare (⌘↩)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(height: 64)
    }

    private func compare() {
        Task { if await model.submit() { dismiss() } }
    }
}

/// The title bar's mode control. Only Branches exists so far; the others are shown so the
/// window's future shape is visible, but they cannot be chosen.
private struct CompareModeCapsule: View {
    var body: some View {
        HStack(spacing: 0) {
            segment("Branches", isSelected: true) { octicon(.gitBranch) }
            segment("Commits", isSelected: false) { octicon(.gitCommit) }
            segment("Pull Request", isSelected: false) { Image(systemName: "arrow.triangle.pull") }
        }
        .padding(3)
        .background(Capsule().fill(Color(nsColor: .tertiarySystemFill)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comparison mode")
    }

    private func octicon(_ image: ImageResource) -> some View {
        Image(image).renderingMode(.template).resizable().scaledToFit().frame(width: 15, height: 15)
    }

    private func segment(_ title: String, isSelected: Bool, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: 8) {
            icon().font(.system(size: 14)).frame(width: 15)
            Text(title).font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(isSelected ? Color.primary : Color.secondary.opacity(0.6))
        .padding(.horizontal, 15)
        .frame(height: 32)
        .background {
            if isSelected {
                Capsule().fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "" : "Not available yet")
    }
}
