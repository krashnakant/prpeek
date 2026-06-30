import AppKit
import Network

/// Sleep/wake + network reachability (plan T6 lifecycle). The laptop lid is the
/// #1 lifecycle event: pause on sleep, fire ONE poll on wake (no backlog burst);
/// poll only when a network path is satisfied.
@MainActor
final class LifecycleMonitor {
    var onWake: (@MainActor () -> Void)?
    var onSleep: (@MainActor () -> Void)?
    var onNetworkSatisfied: (@MainActor () -> Void)?

    private let monitor = NWPathMonitor()
    private(set) var networkAvailable = true

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                AppLog.lifecycle.info("System will sleep")
                self?.onSleep?()
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                AppLog.lifecycle.info("System did wake")
                self?.onWake?()
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let was = self.networkAvailable
                self.networkAvailable = (path.status == .satisfied)
                if was != self.networkAvailable {
                    AppLog.lifecycle.info("Network availability changed available=\(self.networkAvailable, privacy: .public)")
                }
                if !was && self.networkAvailable { self.onNetworkSatisfied?() }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }
}
