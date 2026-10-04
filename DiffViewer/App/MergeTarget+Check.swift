import Foundation

/// The branch a merge was confirmed for has moved or gone.
struct MergeDestinationChanged: LocalizedError {
    let destinationBranch: String

    var errorDescription: String? {
        "\(destinationBranch) changed before the merge could start. Open the merge again to review it."
    }
}

extension MergeTarget {
    /// Throws `MergeDestinationChanged` unless the destination is still checked out at the tip
    /// the sheet showed. Reads from git itself, not the window's cache: an external
    /// checkout or commit may have landed since. The source needs no check, because the
    /// merge takes its confirmed sha.
    func validateDestination(in client: any RepoClient) async throws {
        guard try await client.headState() == .named(destinationBranch),
            try await client.commitSha(of: "refs/heads/\(destinationBranch)") == destinationTipSha
        else {
            throw MergeDestinationChanged(destinationBranch: destinationBranch)
        }
    }
}
