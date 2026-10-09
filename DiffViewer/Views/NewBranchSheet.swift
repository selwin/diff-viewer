import SwiftUI

/// Names a new branch made at HEAD. Create only reports the checked name; the parent
/// dismisses and creates, and git's refusal arrives as the window's error.
struct NewBranchSheet: View {
    @Environment(WindowState.self) private var windowState
    @State private var validation: NewBranchNameValidation
    @State private var text: String
    /// Read once per presentation so "Today" does not shift while the sheet is up.
    @State private var grouping = CommitDayGrouping()
    @FocusState private var nameFocused: Bool
    let onCreate: (String) -> Void

    /// Width of the left gutter that holds the commit dot and the connector.
    private static let gutter: CGFloat = 22

    /// `initialName` fills the field, as the branch picker's search proposes it.
    init(initialName: String?, validation: NewBranchNameValidation, onCreate: @escaping (String) -> Void) {
        _text = State(initialValue: initialName ?? "")
        _validation = State(initialValue: validation)
        self.onCreate = onCreate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            baseBlock
            actions
        }
        .padding(20)
        .frame(width: 380)
        // The same translucent material as the commit sheet.
        .presentationBackground(.regularMaterial)
        .onAppear {
            nameFocused = true
            // `.onChange` skips the initial value, so a prefilled name is checked here.
            if !text.isEmpty { validation.update(text) }
        }
        .onChange(of: windowState.branches) { validation.branchesChanged() }
        .onDisappear { validation.cancel() }
    }

    private var header: some View {
        Text("New Branch").font(.system(size: 15, weight: .bold))
    }

    // MARK: Base

    /// The branch being started from, then the name field it leads to. Its origin is the
    /// gutter's top-left, which is where the dot and connector are drawn from.
    private var baseBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            baseText
            nameField.padding(.top, 16)
            errorLine.padding(.top, 5)
        }
        .padding(.leading, Self.gutter)
        .overlayPreferenceValue(FieldBoundsKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    gutterArt(fieldFrame: proxy[anchor])
                }
            }
        }
    }

    private var baseText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(windowState.newBranchBaseTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if let commit = windowState.newBranchBaseCommit {
                commitLine(commit)
            }
        }
    }

    private func commitLine(_ commit: CommitSummary) -> some View {
        // A separate Text for the sha: a font set inside an interpolated Text is not applied.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: commit.ref.shortSha)
                .font(.system(size: 12, design: .monospaced))
                .fixedSize()
            Text(verbatim: " · \(commit.subject) · \(grouping.commitDateText(for: commit.committedAt))")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
    }

    /// The dot sits on the base name's line; the dotted connector runs down from it and
    /// curves into the field's vertical centre, wherever the field ends up.
    private func gutterArt(fieldFrame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .strokeBorder(Color(nsColor: NewBranchSheetPalette.commitDot), lineWidth: 2)
                .frame(width: 10, height: 10)
                .offset(y: 4)
            BranchConnector(fieldMidY: fieldFrame.midY, fieldMinX: fieldFrame.minX)
                .stroke(
                    Color(nsColor: NewBranchSheetPalette.connector),
                    // Round caps on zero-length dashes make dots.
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0, 4]))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    // MARK: Name

    private var nameField: some View {
        HStack(spacing: 6) {
            TextField("New branch name", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .focused($nameFocused)
                .accessibilityLabel("Branch name")
                .onChange(of: text) { validation.update(text) }
                .onSubmit { if validation.canCreate { onCreate(validation.name) } }
            statusIcon
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: NewBranchSheetPalette.fieldFill)))
        .overlay {
            // A subtle focus cue instead of the system ring; validation never tints the field.
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(
                    nameFocused ? Color.primary.opacity(0.3) : Color(nsColor: NewBranchSheetPalette.fieldBorder),
                    lineWidth: 0.5)
        }
        .anchorPreference(key: FieldBoundsKey.self, value: .bounds) { $0 }
    }

    /// Always 16pt square so the text never shifts as the status changes.
    private var statusIcon: some View {
        ZStack {
            switch validation.status {
            case .valid:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(nsColor: .systemGreen))
            case .invalid, .exists:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(nsColor: .systemRed))
            case .empty, .pending:
                EmptyView()
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private var errorLine: some View {
        // A space holds the line, so the sheet doesn't resize as the reason comes and goes.
        Text(validation.message ?? " ")
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: NewBranchSheetPalette.errorText))
            .lineLimit(1)
            // Middle, so a long "<name> already exists" keeps "already exists".
            .truncationMode(.middle)
            .padding(.leading, 2)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                windowState.isNewBranchSheetPresented = false
            } label: {
                Text("Cancel").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(SheetCapsuleButtonStyle(appearance: .neutral))
            .keyboardShortcut(.cancelAction)
            Button {
                onCreate(validation.name)
            } label: {
                HStack(spacing: 6) {
                    Text("Create").font(.system(size: 13, weight: .semibold))
                    Text("⌘↩")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.6)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(SheetCapsuleButtonStyle(appearance: .prominent))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!validation.canCreate)
            .help("Create (⌘↩)")
        }
    }
}

/// The name field's bounds, so the connector can end at its vertical centre.
private struct FieldBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Runs down from just below the commit dot, turns through a quarter circle and heads
/// right to the field's left edge.
private struct BranchConnector: Shape {
    let fieldMidY: CGFloat
    let fieldMinX: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 9
        let x: CGFloat = 5
        // Control-point distance that makes a cubic Bézier trace a circular quarter.
        let control = radius * 0.5523
        var path = Path()
        path.move(to: CGPoint(x: x, y: 15))
        path.addLine(to: CGPoint(x: x, y: fieldMidY - radius))
        path.addCurve(
            to: CGPoint(x: x + radius, y: fieldMidY),
            control1: CGPoint(x: x, y: fieldMidY - radius + control),
            control2: CGPoint(x: x + radius - control, y: fieldMidY))
        path.addLine(to: CGPoint(x: fieldMinX, y: fieldMidY))
        return path
    }
}

/// Colours specific to the New Branch sheet.
private enum NewBranchSheetPalette {
    static let commitDot = DiffTheme.dynamic(light: rgb(174, 174, 178), dark: NSColor(white: 1, alpha: 0.40))
    static let connector = DiffTheme.dynamic(light: rgb(184, 184, 189), dark: NSColor(white: 1, alpha: 0.30))
    static let fieldFill = DiffTheme.dynamic(light: .textBackgroundColor, dark: NSColor(white: 0, alpha: 0.25))
    static let fieldBorder = DiffTheme.dynamic(
        light: NSColor(white: 0, alpha: 0.15), dark: NSColor(white: 1, alpha: 0.14))
    static let errorText = DiffTheme.dynamic(light: rgb(215, 0, 21), dark: rgb(255, 105, 97))

    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
}
