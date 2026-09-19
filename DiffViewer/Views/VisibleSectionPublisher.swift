import Foundation

/// The changeset section whose rows are at the top of the viewport, tied to the load that
/// produced it: revisions within a load only append, so the index stays valid, but the
/// same index in another load names a different file.
struct VisibleSectionReference: Equatable, Sendable {
    let loadID: UUID
    let sectionIndex: Int
}

/// Coalesces top-visible-section changes into at most one pending delivery. Schedule one
/// delivery per main-loop turn using the latest visible section: `update` says when a
/// delivery must be scheduled, `deliver` publishes whatever is current by then.
@MainActor
final class VisibleSectionPublisher {
    /// What was last handed to `onChange`; `.never` until the first delivery, so the
    /// first `nil` and the first section are both delivered.
    private enum Delivered: Equatable {
        case never
        case value(VisibleSectionReference?)
    }

    var onChange: ((VisibleSectionReference?) -> Void)?
    private(set) var current: VisibleSectionReference?
    private(set) var isDeliveryPending = false
    private var lastDelivered = Delivered.never

    /// Records `value` as current. Returns true when the caller must schedule a delivery:
    /// the value differs from the last delivered one and none is pending yet.
    func update(_ value: VisibleSectionReference?) -> Bool {
        current = value
        guard !isDeliveryPending, lastDelivered != .value(value) else { return false }
        isDeliveryPending = true
        return true
    }

    /// Publishes `current` if it differs from the last delivered value.
    func deliver() {
        isDeliveryPending = false
        guard lastDelivered != .value(current) else { return }
        lastDelivered = .value(current)
        onChange?(current)
    }

    /// Forgets the current and delivered values, for when the content is replaced. A
    /// pending delivery stays pending: its block is already queued and cannot be cancelled,
    /// so it publishes whatever is current by then.
    func reset() {
        current = nil
        lastDelivered = .never
    }
}
