import Foundation
import Combine

// MARK: - Approval center

/// Holds the approval the run is waiting on, so the chat can show it. The run
/// stays suspended until the user decides, the request times out (a denial),
/// or the run is stopped. Tool calls are sequential, so there is at most one.
@MainActor
final class ApprovalCenter: ObservableObject {
    @Published private(set) var pending: ApprovalRequest?

    /// How long a request waits before counting as a denial (Anu Android: 10 min).
    var timeout: Duration = .seconds(600)
    /// Test seam: decides immediately, without UI. Production leaves it nil.
    var autoDecide: (@MainActor (ApprovalRequest) -> ApprovalDecision)?

    private var continuation: CheckedContinuation<ApprovalDecision, Never>?
    private var timeoutTask: Task<Void, Never>?

    func request(_ request: ApprovalRequest) async -> ApprovalDecision {
        if let autoDecide { return autoDecide(request) }
        // A stopped run never raises a new sheet.
        if Task.isCancelled { return .cancelled }
        // Defensive: never leave an earlier request suspended forever. The
        // sheet isn't cleared first, so it updates in place.
        resumeWaiting(with: .cancelled)
        pending = request
        let wait = timeout
        return await withCheckedContinuation { (cont: CheckedContinuation<ApprovalDecision, Never>) in
            continuation = cont
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                self?.finish(.timedOut)
            }
        }
    }

    /// The user's answer to the request with this id. Stale answers are ignored.
    func decide(_ id: UUID, _ decision: ApprovalDecision) {
        guard pending?.id == id else { return }
        if case .revised = decision {
            // The broker checks the edit and asks again straight away; keep the
            // sheet up so it updates in place instead of closing and reopening.
            resumeWaiting(with: decision)
        } else {
            finish(decision)
        }
    }

    /// Clears a request nobody waits on any more: after an edit, the broker can
    /// finish without asking again (the edited call replayed a stored result).
    func settle() {
        if continuation == nil { pending = nil }
    }

    /// Withdraws the pending request, for example when the run is stopped.
    func cancelAll() {
        finish(.cancelled)
    }

    private func finish(_ decision: ApprovalDecision) {
        pending = nil
        resumeWaiting(with: decision)
    }

    private func resumeWaiting(with decision: ApprovalDecision) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: decision)
    }
}
