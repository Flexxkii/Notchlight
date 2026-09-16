import AppKit
import Diagnostics
import SwiftUI

/// Reads the actual AppKit window, including changes that SwiftUI onAppear does not describe.
struct SettingsWindowDiagnostics: NSViewRepresentable {
    let recorder: DiagnosticRecorder
    let state: SettingsWindowState

    func makeNSView(context: Context) -> SettingsWindowObserverView {
        SettingsWindowObserverView(recorder: recorder, state: state)
    }

    func updateNSView(_ view: SettingsWindowObserverView, context: Context) {}

    static func dismantleNSView(_ view: SettingsWindowObserverView, coordinator: ()) {
        view.stopObserving()
    }
}

@MainActor
final class SettingsWindowObserverView: NSView {
    private let recorder: DiagnosticRecorder
    private let state: SettingsWindowState
    private var observers: [NSObjectProtocol] = []
    private var pendingUpdate: Task<Void, Never>?

    init(recorder: DiagnosticRecorder, state: SettingsWindowState = SettingsWindowState()) {
        self.recorder = recorder
        self.state = state
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        // A final deferred closed-state update may outlive this view. It only
        // retains the state/recorder and is invalidated by a replacement observer.
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else {
            return
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleStateUpdate() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleStateUpdate(closed: true)
            }
        })
        scheduleStateUpdate()
    }

    /// Defer observable writes out of SwiftUI's representable update/layout pass.
    private func scheduleStateUpdate(closed: Bool = false) {
        pendingUpdate?.cancel()
        let state = state
        let recorder = recorder
        let revision = state.reserveUpdate()
        pendingUpdate = Task { @MainActor [weak self] in
            guard !Task.isCancelled, state.isCurrent(revision) else { return }
            if closed {
                state.update(isVisible: false, isMiniaturized: false, isOccluded: true)
                recorder.updateContext([
                    "settings_visible": .bool(false), "settings_minimized": .bool(false),
                    "settings_occluded": .bool(true)
                ])
            } else {
                self?.recordState()
            }
            self?.pendingUpdate = nil
        }
    }

    func stopObserving() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        scheduleStateUpdate(closed: true)
    }

    func recordState() {
        guard let window else { recordClosed(); return }
        state.update(isVisible: window.isVisible, isMiniaturized: window.isMiniaturized,
                     isOccluded: !window.occlusionState.contains(.visible))
        recorder.updateContext([
            "settings_visible": .bool(window.isVisible),
            "settings_minimized": .bool(window.isMiniaturized),
            "settings_occluded": .bool(!window.occlusionState.contains(.visible))
        ])
    }

    private func recordClosed() {
        state.update(isVisible: false, isMiniaturized: false, isOccluded: true)
        recorder.updateContext([
            "settings_visible": .bool(false),
            "settings_minimized": .bool(false),
            "settings_occluded": .bool(true)
        ])
    }
}
