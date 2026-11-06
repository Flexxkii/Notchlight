import Foundation
import IOKit.ps
import Observation

@MainActor @Observable
final class PowerMonitor {
    private(set) var onBattery = false
    private(set) var lowPowerMode = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        refresh()
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
            }
        }, context)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
    }

    func stop() {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        powerSource = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    isolated deinit {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let battery: Bool
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            battery = source as String == kIOPSBatteryPowerValue
        } else { battery = false }
        record(onBattery: battery, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    func record(onBattery: Bool, lowPowerMode: Bool) {
        guard self.onBattery != onBattery || self.lowPowerMode != lowPowerMode else { return }
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        onChange?()
    }
}
