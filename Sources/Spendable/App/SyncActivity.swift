import Foundation
import Network

/// Event-driven reachability. The only delay is a bounded wait after launch/wake, never a poll.
@MainActor
final class NetworkReadiness {
    private let monitor = NWPathMonitor()
    private var satisfied = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]

    init(startMonitoring: Bool = true) {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.changed(online) }
        }
        if startMonitoring {
            monitor.start(queue: DispatchQueue(label: "com.nullterminater.spendable.network", qos: .utility))
        }
    }

    deinit { monitor.cancel() }

    func waitUntilOnline(timeout: Duration = .seconds(60)) async -> Bool {
        if satisfied { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false); return }
                waiters[id] = continuation
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(id, online: false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, online: false) }
        }
    }

    private func changed(_ online: Bool) {
        satisfied = online
        if online { for id in Array(waiters.keys) { finish(id, online: true) } }
    }

    private func finish(_ id: UUID, online: Bool) {
        timeouts.removeValue(forKey: id)?.cancel()
        waiters.removeValue(forKey: id)?.resume(returning: online)
    }
}

/// Shared by the actual activity and tests: every outcome finishes the OS activity exactly once.
enum SyncActivity {
    static func run(
        coordinator: SyncCoordinator,
        completion: @Sendable () -> Void
    ) async -> SyncReport {
        defer { completion() }
        return await coordinator.syncIfDue(trigger: .scheduled)
    }
}
