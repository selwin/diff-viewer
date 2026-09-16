import SwiftUI

/// Small header views shared by the file and changeset detail headers, so both read the
/// same way and only one of them has to be changed.

/// "Change 3 of 41" while a block is current, "41 changes" otherwise. A current index
/// past the end (blocks shrank under it) falls back to the plain count.
struct ChangeCounterText: View {
    let count: Int
    let current: Int?

    var body: some View {
        if let current, current < count {
            Text("Change \(current + 1) of \(count)")
        } else {
            Text("\(count) change\(count == 1 ? "" : "s")")
        }
    }
}

/// The small spinner a header shows while its content is being computed.
struct LoadingIndicator: View {
    let isLoading: Bool

    var body: some View {
        if isLoading {
            ProgressView().controlSize(.small)
        }
    }
}
