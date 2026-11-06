import AppKit
import Observation
import StatusSignals

@MainActor @Observable
final class SignalMonitor {
    private(set) var signals: [StatusSignal] = []
    private(set) var error: String?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let store: SignalStore
    @ObservationIgnored private var watcher: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var revision = 0

    init(store: SignalStore = SignalStore()) { self.store = store }

    func start() {
        guard watcher == nil else { return }
        do {
            try store.prepare()
            let descriptor = open(store.directory.path, O_EVTONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                  eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let event = self.watcher?.data, !event.intersection([.rename, .delete]).isEmpty { self.retry() }
                    else { self.refresh() }
                }
            }
            source.setCancelHandler { close(descriptor) }
            watcher = source
            source.resume()
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                             object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            refresh()
        } catch {
            self.error = error.localizedDescription
            onChange?()
        }
    }

    func stop() {
        revision &+= 1
        watcher?.cancel(); watcher = nil
        refreshTask?.cancel(); refreshTask = nil
        expiryTask?.cancel(); expiryTask = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        signals = []
        onChange?()
    }

    isolated deinit {
        watcher?.cancel()
        refreshTask?.cancel()
        expiryTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func refresh() {
        guard watcher != nil else { return }
        revision &+= 1
        let current = revision, store = store
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try store.snapshot() } }.value
            guard let self, !Task.isCancelled, current == revision else { return }
            switch result {
            case .success(let values): error = nil; record(values)
            case .failure(let error): self.error = error.localizedDescription; record([])
            }
        }
    }

    func retry() { stop(); start() }

    func dismiss(_ signal: StatusSignal) {
        let store = store
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try store.clear(source: signal.source) } }.value
            if case .failure(let error) = result { self?.error = error.localizedDescription }
            self?.refresh()
        }
    }

    /// Also used by isolated fixtures; production input always comes from the mailbox.
    func record(_ values: [StatusSignal]) {
        signals = values.filter { $0.isValid(at: .now) }
        expiryTask?.cancel()
        if let deadline = signals.map(\.expiresAt).min() {
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
                guard let self else { return }
                record(signals)
            }
        }
        onChange?()
    }
}
