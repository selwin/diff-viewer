import Foundation

/// Whether the New Branch sheet's name can be created, re-checked as the reader types.
/// Git's own rules decide, through `check`, so the app keeps no copy of them.
@MainActor
@Observable
final class NewBranchNameValidation {
    enum Status: Equatable {
        /// Nothing typed but whitespace.
        case empty
        /// Waiting out the debounce, or for git's answer.
        case pending
        case valid
        case invalid
        /// A local branch already has the name.
        case exists
    }

    /// The field's text, trimmed: what Create would name the branch.
    private(set) var name = ""
    private(set) var status: Status = .empty

    /// The check in flight, if any. Internal so tests can await it.
    @ObservationIgnored private(set) var pendingCheck: Task<Void, Never>?
    /// Bumped by every change of name, so an answer for an earlier name is dropped.
    @ObservationIgnored private var generation = 0
    private let exists: @MainActor (String) -> Bool
    private let check: @MainActor (String) async -> Bool
    private let debounce: @Sendable () async throws -> Void

    /// `debounce` runs before each check and throws when cancelled; a name typed meanwhile
    /// cancels it, so fast typing runs git once.
    init(
        exists: @escaping @MainActor (String) -> Bool,
        check: @escaping @MainActor (String) async -> Bool,
        debounce: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(150)) }
    ) {
        self.exists = exists
        self.check = check
        self.debounce = debounce
    }

    var canCreate: Bool { status == .valid }

    /// Why Create is off, or nil while there is nothing to say yet.
    var message: String? {
        switch status {
        case .invalid: "Not a valid branch name"
        case .exists: "A branch named \(name) already exists"
        case .empty, .pending, .valid: nil
        }
    }

    /// Takes the field's text. Whitespace at either end changes nothing.
    func update(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != name else { return }
        name = trimmed
        evaluate()
    }

    /// Re-judges the name against a re-read branch list: another git process may have
    /// created or deleted a branch of that name while the sheet was up.
    func branchesChanged() {
        switch status {
        case .valid where exists(name): status = .exists
        case .exists where !exists(name): evaluate()
        default: break
        }
    }

    /// Drops the check in flight; a queued one never reaches git.
    func cancel() {
        generation += 1
        pendingCheck?.cancel()
        pendingCheck = nil
    }

    private func evaluate() {
        cancel()
        if name.isEmpty {
            status = .empty
        } else if name.hasPrefix("-") {
            status = .invalid
        } else if exists(name) {
            status = .exists
        } else {
            status = .pending
            let (name, generation) = (name, generation)
            pendingCheck = Task { [weak self, debounce, check] in
                do { try await debounce() } catch { return }
                let valid = await check(name)
                guard let self, generation == self.generation else { return }
                // The list may have been re-read while git answered.
                self.status = !valid ? .invalid : self.exists(name) ? .exists : .valid
                self.pendingCheck = nil
            }
        }
    }
}
