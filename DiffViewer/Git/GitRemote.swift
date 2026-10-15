import Foundation

/// A configured remote and the URL git fetches from after `insteadOf` rewrites.
struct GitRemote: Equatable, Sendable {
    let name: String
    let fetchURL: String
}
