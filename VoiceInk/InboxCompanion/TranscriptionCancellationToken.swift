import Atomics

final class TranscriptionCancellationToken: @unchecked Sendable {
    private let cancelled = ManagedAtomic(false)
    var isCancelled: Bool { cancelled.load(ordering: .acquiring) }
    func cancel() { cancelled.store(true, ordering: .releasing) }
    func throwIfCancelled() throws { if isCancelled || Task.isCancelled { throw CancellationError() } }
}
