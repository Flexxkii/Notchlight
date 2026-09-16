import SwiftUI
import BorderOverlay
import Observation
import CodexIntegration
import Diagnostics

@MainActor
@Observable
final class BorderModel {
    let codex: CodexMonitor
    @ObservationIgnored let diagnostics: DiagnosticRecorder
    var codexLinked: Bool {
        didSet {
            if integrationAllowed {
                if codexLinked { codex.start() } else { codex.stop() }
            }
            handleCodexChange()
            saveAndApply()
        }
    }
    var codexWindow: CodexUsageWindow { didSet { saveAndApply() } }
    var codexUsageDisplay: CodexUsageDisplay { didSet { saveAndApply() } }
    var isEnabled: Bool { didSet { saveAndApply() } }
    var hideWhenSwiping: Bool {
        didSet {
            saveAndApply()
        }
    }
    private(set) var swipeMonitoringStatus: SwipeMonitoringStatus = .disabled
    var showOnlyWhileWorking: Bool { didSet { reconcileActivityVisibility(); saveAndApply() } }
    var inactivityTimeoutMinutes: Double {
        didSet {
            let normalized = Self.validated(inactivityTimeoutMinutes, range: 0...60, fallback: 1)
            if inactivityTimeoutMinutes != normalized { inactivityTimeoutMinutes = normalized; return }
            reconcileActivityVisibility(); saveAndApply()
        }
    }
    var lineWidth: Double { didSet { saveAndApply() } }
    var padding: Double { didSet { saveAndApply() } }
    var glow: Bool { didSet { saveAndApply() } }
    var hoverTextSize: Double {
        didSet {
            let normalized = NotchHoverStyle(textSize: hoverTextSize).textSize
            if hoverTextSize != normalized { hoverTextSize = normalized; return }
            saveAndApply()
        }
    }
    var startPercentage: Double {
        didSet {
            let normalized = (Self.validated(startPercentage, range: 0...100, fallback: 0) * 10).rounded() / 10
            if startPercentage != normalized {
                startPercentage = normalized
                return
            }
            if startPercentage > endPercentage { endPercentage = startPercentage }
            saveAndApply()
        }
    }
    var endPercentage: Double {
        didSet {
            let normalized = (Self.validated(endPercentage, range: 0...100, fallback: 100) * 10).rounded() / 10
            if endPercentage != normalized {
                endPercentage = normalized
                return
            }
            if endPercentage < startPercentage { startPercentage = endPercentage }
            saveAndApply()
        }
    }
    var borderColor: Color { didSet { saveAndApply() } }
    var workingColor: Color { didSet { saveAndApply() } }
    var stripsEnabled: Bool { didSet { saveAndApply() } }
    var stripThickness: Double {
        didSet {
            let value = Self.validated(stripThickness, range: 0.5...6, fallback: 1.5)
            if stripThickness != value { stripThickness = value; return }
            saveAndApply()
        }
    }
    var stripLength: Double {
        didSet {
            let value = Self.validated(stripLength, range: 2...20, fallback: 8)
            if stripLength != value { stripLength = value; return }
            saveAndApply()
        }
    }
    var stripOffset: Double {
        didSet {
            let value = Self.validated(stripOffset, range: 0...24, fallback: 0)
            if stripOffset != value { stripOffset = value; return }
            saveAndApply()
        }
    }
    var stripTopPadding: Double {
        didSet {
            let value = Self.validated(stripTopPadding, range: 0...12, fallback: 2)
            if stripTopPadding != value { stripTopPadding = value; return }
            saveAndApply()
        }
    }
    var stripOpacity: Double {
        didSet {
            let value = Self.validated(stripOpacity, range: 0...1, fallback: 0.7)
            if stripOpacity != value { stripOpacity = value; return }
            saveAndApply()
        }
    }
    var stripColor: Color { didSet { saveAndApply() } }
    private(set) var detectedNotchCount = 0
    private(set) var targetDescription = "Detecting display…"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let overlay: BorderOverlayController
    @ObservationIgnored private let integrationAllowed: Bool
    @ObservationIgnored private let overlayAllowed: Bool
    @ObservationIgnored private lazy var notchMenuController = NotchMenuController(model: self)
    @ObservationIgnored var openSettingsAction: (() -> Void)?
    @ObservationIgnored var exportDiagnosticsAction: (() -> Void)?
    @ObservationIgnored private var idleSince: Date?
    @ObservationIgnored private var inactivityTask: Task<Void, Never>?
    private var graceActive = false
    private var servicesStopped = false
    @ObservationIgnored private var inactivityGeneration = 0
    @ObservationIgnored private var lastActivityWasWorking = false

    var hasTarget: Bool { detectedNotchCount > 0 }
    var selectedUsage: CodexUsageValue? { codex.usage?.value(for: codexWindow) }
    var selectedUsagePercentage: Double? { selectedUsage.map { codexUsageDisplay.percentage(for: $0) } }
    var effectiveStartPercentage: Double { codexLinked ? 0 : startPercentage }
    var effectiveEndPercentage: Double { codexLinked ? selectedUsagePercentage ?? 0 : endPercentage }
    var effectiveGlow: Bool { codexLinked ? codex.isWorking : glow }
    var effectivePulse: Bool { codexLinked && codex.isWorking }
    var effectiveBorderColor: Color { codexLinked && codex.isWorking ? workingColor : borderColor }
    var stripStyle: BorderStripStyle {
        BorderStripStyle(
            isEnabled: stripsEnabled, thickness: stripThickness, length: stripLength,
            offset: stripOffset, topPadding: stripTopPadding,
            color: (NSColor(stripColor).usingColorSpace(.sRGB) ?? .white).withAlphaComponent(1),
            opacity: stripOpacity
        )
    }
    var effectiveIsEnabled: Bool {
        guard !servicesStopped else { return false }
        return ActivityVisibilityPolicy.isVisible(
            masterEnabled: isEnabled, filterEnabled: showOnlyWhileWorking,
            linked: codexLinked, available: codex.activity?.isAvailable == true,
            working: codex.isWorking, idleSince: graceActive ? idleSince : nil,
            now: Date(), timeoutMinutes: inactivityTimeoutMinutes
        )
    }
    var hasVisibleLine: Bool { effectiveIsEnabled && hasTarget && effectiveEndPercentage > effectiveStartPercentage }
    var statusLabel: String {
        if !isEnabled { return "Border paused" }
        if showOnlyWhileWorking && !effectiveIsEnabled { return "Waiting for Codex activity" }
        if !hasTarget { return "No camera notch detected" }
        if codexLinked {
            guard let selectedUsage else { return codex.isRefreshing ? "Reading Codex usage…" : "Codex usage unavailable" }
            let summary = codexUsageDisplay.summary(for: selectedUsage)
            if codex.usageError != nil { return "Last known usage: \(summary)" }
            return "\(summary) · \(codex.isWorking ? "Codex working" : "Codex linked")"
        }
        if startPercentage == endPercentage { return "Line range is empty" }
        return "Your border is on"
    }

    init(defaults: UserDefaults = .standard, startIntegration: Bool = true, startOverlay: Bool = true,
         diagnostics: DiagnosticRecorder = .disabled) {
        self.diagnostics = diagnostics
        codex = CodexMonitor(diagnostics: diagnostics)
        overlay = BorderOverlayController(diagnostics: diagnostics)
        self.defaults = defaults
        integrationAllowed = startIntegration
        overlayAllowed = startOverlay
        if defaults === UserDefaults.standard {
            Self.migrateLegacyDefaultsIfNeeded(to: defaults, destinationDomainName: Bundle.main.bundleIdentifier ?? "com.teodor.Notchlight")
        }
        defaults.register(defaults: [
            "border.enabled": true,
            "border.hideWhenSwiping": false,
            "border.showOnlyWhileWorking": false,
            "border.inactivityTimeoutMinutes": 1.0,
            "border.lineWidth": 2.0,
            "border.padding": 1.0,
            "border.glow": false,
            "hover.textSize": NotchHoverStyle.defaultTextSize,
            "border.startPercentage": 0.0,
            "border.endPercentage": 100.0,
            "border.color.red": 1.0,
            "border.color.green": 0.04,
            "border.color.blue": 0.08,
            "border.workingColor.red": 0.15,
            "border.workingColor.green": 0.55,
            "border.workingColor.blue": 1.0,
            "strips.enabled": true,
            "strips.thickness": 1.5,
            "strips.length": 8.0,
            "strips.offset": 0.0,
            "strips.topPadding": 2.0,
            "strips.opacity": 0.7,
            "strips.color.red": 1.0,
            "strips.color.green": 1.0,
            "strips.color.blue": 1.0,
            "codex.linked": true,
            "codex.window": CodexUsageWindow.automatic.rawValue,
            "codex.usageDisplay": CodexUsageDisplay.used.rawValue
        ])
        codexLinked = defaults.bool(forKey: "codex.linked")
        codexWindow = CodexUsageWindow(rawValue: defaults.string(forKey: "codex.window") ?? "") ?? .automatic
        codexUsageDisplay = CodexUsageDisplay(rawValue: defaults.string(forKey: "codex.usageDisplay") ?? "") ?? .used
        isEnabled = defaults.bool(forKey: "border.enabled")
        hideWhenSwiping = defaults.bool(forKey: "border.hideWhenSwiping")
        showOnlyWhileWorking = defaults.bool(forKey: "border.showOnlyWhileWorking")
        inactivityTimeoutMinutes = Self.validated(defaults.double(forKey: "border.inactivityTimeoutMinutes"), range: 0...60, fallback: 1)
        lineWidth = Self.validated(defaults.double(forKey: "border.lineWidth"), range: 1...6, fallback: 2)
        padding = Self.validated(defaults.double(forKey: "border.padding"), range: 0...12, fallback: 1)
        glow = defaults.bool(forKey: "border.glow")
        hoverTextSize = NotchHoverStyle(textSize: defaults.double(forKey: "hover.textSize")).textSize
        defaults.removeObject(forKey: "border.mode")
        let savedStart = Self.validated(defaults.double(forKey: "border.startPercentage"), range: 0...100, fallback: 0)
        let savedEnd = Self.validated(defaults.double(forKey: "border.endPercentage"), range: 0...100, fallback: 100)
        startPercentage = min(savedStart, savedEnd)
        endPercentage = max(savedStart, savedEnd)
        borderColor = Color(
            .sRGB,
            red: Self.validated(defaults.double(forKey: "border.color.red"), range: 0...1, fallback: 1),
            green: Self.validated(defaults.double(forKey: "border.color.green"), range: 0...1, fallback: 0.04),
            blue: Self.validated(defaults.double(forKey: "border.color.blue"), range: 0...1, fallback: 0.08)
        )
        workingColor = Color(
            .sRGB,
            red: Self.validated(defaults.double(forKey: "border.workingColor.red"), range: 0...1, fallback: 0.15),
            green: Self.validated(defaults.double(forKey: "border.workingColor.green"), range: 0...1, fallback: 0.55),
            blue: Self.validated(defaults.double(forKey: "border.workingColor.blue"), range: 0...1, fallback: 1)
        )
        stripsEnabled = defaults.bool(forKey: "strips.enabled")
        stripThickness = Self.validated(defaults.double(forKey: "strips.thickness"), range: 0.5...6, fallback: 1.5)
        stripLength = Self.validated(defaults.double(forKey: "strips.length"), range: 2...20, fallback: 8)
        stripOffset = Self.validated(defaults.double(forKey: "strips.offset"), range: 0...24, fallback: 0)
        stripTopPadding = Self.validated(defaults.double(forKey: "strips.topPadding"), range: 0...12, fallback: 2)
        stripOpacity = Self.validated(defaults.double(forKey: "strips.opacity"), range: 0...1, fallback: 0.7)
        stripColor = Color(
            .sRGB,
            red: Self.validated(defaults.double(forKey: "strips.color.red"), range: 0...1, fallback: 1),
            green: Self.validated(defaults.double(forKey: "strips.color.green"), range: 0...1, fallback: 1),
            blue: Self.validated(defaults.double(forKey: "strips.color.blue"), range: 0...1, fallback: 1)
        )
        overlay.onDisplaysChanged = { [weak self] in self?.syncStatus() }
        overlay.onSwipeMonitoringStatusChanged = { [weak self] status in
            self?.swipeMonitoringStatus = status
        }
        overlay.menuProvider = { [weak self] in self?.notchMenuController.makeMenu() ?? NSMenu() }
        codex.onChange = { [weak self] in self?.handleCodexChange() }
        apply()
        if codexLinked && startIntegration { codex.start() }
    }

    func resetAppearance() {
        hoverTextSize = NotchHoverStyle.defaultTextSize
        lineWidth = 2
        padding = 1
        glow = false
        startPercentage = 0
        endPercentage = 100
        borderColor = Color(.sRGB, red: 1, green: 0.04, blue: 0.08)
        workingColor = Color(.sRGB, red: 0.15, green: 0.55, blue: 1)
        resetStrips()
    }

    func resetStrips() {
        stripsEnabled = true
        stripThickness = 1.5
        stripLength = 8
        stripOffset = 0
        stripTopPadding = 2
        stripOpacity = 0.7
        stripColor = .white
    }

    func showSettings() {
        openSettingsAction?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func exportDiagnostics() {
        exportDiagnosticsAction?()
    }

    func quit() {
        stopServices()
        NSApp.terminate(nil)
    }

    func stopServices() {
        servicesStopped = true
        clearActivityHistory()
        codex.stop()
        overlay.stop()
    }

    private func saveAndApply() {
        defaults.set(isEnabled, forKey: "border.enabled")
        defaults.set(hideWhenSwiping, forKey: "border.hideWhenSwiping")
        defaults.set(showOnlyWhileWorking, forKey: "border.showOnlyWhileWorking")
        defaults.set(inactivityTimeoutMinutes, forKey: "border.inactivityTimeoutMinutes")
        defaults.set(lineWidth, forKey: "border.lineWidth")
        defaults.set(padding, forKey: "border.padding")
        defaults.set(glow, forKey: "border.glow")
        defaults.set(hoverTextSize, forKey: "hover.textSize")
        defaults.set(startPercentage, forKey: "border.startPercentage")
        defaults.set(endPercentage, forKey: "border.endPercentage")
        defaults.set(resolvedColor.redComponent, forKey: "border.color.red")
        defaults.set(resolvedColor.greenComponent, forKey: "border.color.green")
        defaults.set(resolvedColor.blueComponent, forKey: "border.color.blue")
        defaults.set(resolvedWorkingColor.redComponent, forKey: "border.workingColor.red")
        defaults.set(resolvedWorkingColor.greenComponent, forKey: "border.workingColor.green")
        defaults.set(resolvedWorkingColor.blueComponent, forKey: "border.workingColor.blue")
        defaults.set(stripsEnabled, forKey: "strips.enabled")
        defaults.set(stripThickness, forKey: "strips.thickness")
        defaults.set(stripLength, forKey: "strips.length")
        defaults.set(stripOffset, forKey: "strips.offset")
        defaults.set(stripTopPadding, forKey: "strips.topPadding")
        defaults.set(stripOpacity, forKey: "strips.opacity")
        let resolvedStripColor = NSColor(stripColor).usingColorSpace(.sRGB) ?? .white
        defaults.set(resolvedStripColor.redComponent, forKey: "strips.color.red")
        defaults.set(resolvedStripColor.greenComponent, forKey: "strips.color.green")
        defaults.set(resolvedStripColor.blueComponent, forKey: "strips.color.blue")
        defaults.set(codexLinked, forKey: "codex.linked")
        defaults.set(codexWindow.rawValue, forKey: "codex.window")
        defaults.set(codexUsageDisplay.rawValue, forKey: "codex.usageDisplay")
        apply()
    }

    private func apply() {
        diagnostics.updateContext([
            "codex_connected": .bool(codexLinked),
            "codex_activity_available": .bool(codex.activity?.isAvailable == true),
            "codex_working": .bool(codex.isWorking),
            "usage_available": .bool(codex.usage != nil),
            "usage_stale": .bool(codex.usageError != nil),
            "active_task_count": .int(Int64(codex.activity?.activeTaskCount ?? 0)),
            "border_enabled": .bool(isEnabled),
            "border_effective_enabled": .bool(effectiveIsEnabled),
            "glow_enabled": .bool(effectiveGlow),
            "pulse_requested": .bool(effectivePulse),
            "show_only_while_working": .bool(showOnlyWhileWorking),
            "inactivity_timeout_minutes": .double(inactivityTimeoutMinutes),
            "line_width_points": .double(lineWidth),
            "border_spacing_points": .double(padding),
            "hover_text_size_points": .double(hoverTextSize),
            "strips_enabled": .bool(stripsEnabled)
        ])
        guard overlayAllowed, !servicesStopped else { return }
        overlay.update(
            isEnabled: effectiveIsEnabled, lineWidth: lineWidth, padding: padding, glow: effectiveGlow, pulse: effectivePulse,
            startPercentage: effectiveStartPercentage, endPercentage: effectiveEndPercentage, color: resolvedEffectiveColor,
            strips: stripStyle,
            hoverContent: NotchHoverPresentation.make(
                isLinked: codexLinked, usage: selectedUsage,
                isRefreshing: codex.isRefreshing, isStale: codex.usageError != nil,
                display: codexUsageDisplay
            ),
            hoverStyle: NotchHoverStyle(textSize: hoverTextSize)
        )
        overlay.setHideWhenSwiping(hideWhenSwiping)
        syncStatus()
    }

    func requestSwipeMonitoringPermission() {
        guard overlayAllowed, !servicesStopped else { return }
        overlay.requestSwipeMonitoringPermission()
    }

    func refreshSwipeMonitoring() {
        guard overlayAllowed, !servicesStopped else { return }
        overlay.refreshSwipeMonitoring()
    }

    private func syncStatus() {
        detectedNotchCount = overlay.detectedNotchCount
        targetDescription = overlay.targetDescription
    }

    private func handleCodexChange() {
        guard !servicesStopped else { return }
        let working = codexLinked && codex.isWorking
        if !codexLinked || working {
            clearActivityHistory()
        } else if lastActivityWasWorking {
            idleSince = Date()
            scheduleInactivityExpiry()
        }
        // Repeated idle/unavailable reports and usage refreshes leave the
        // original idle timestamp and its pending deadline untouched.
        lastActivityWasWorking = working
        apply()
    }

    private func reconcileActivityVisibility() {
        guard !servicesStopped else { return }
        if !codexLinked || codex.isWorking {
            clearActivityHistory()
            lastActivityWasWorking = codexLinked && codex.isWorking
        } else {
            scheduleInactivityExpiry()
        }
        apply()
    }

    private func scheduleInactivityExpiry() {
        cancelInactivityTask()
        graceActive = false
        guard showOnlyWhileWorking, let idleSince else { return }
        let generation = inactivityGeneration
        let remaining = inactivityTimeoutMinutes * 60 - Date().timeIntervalSince(idleSince)
        // Preserve the original timestamp after expiry, so changing the
        // timeout always measures from when work actually stopped.
        guard remaining > 0 else { return }
        graceActive = true
        inactivityTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, !Task.isCancelled, !self.servicesStopped,
                  self.inactivityGeneration == generation,
                  self.idleSince == idleSince else { return }
            self.graceActive = false
            self.inactivityTask = nil
            self.apply()
        }
    }

    private func clearActivityHistory() {
        cancelInactivityTask()
        idleSince = nil
        graceActive = false
        lastActivityWasWorking = false
    }

    private func cancelInactivityTask() {
        inactivityGeneration += 1
        inactivityTask?.cancel()
        inactivityTask = nil
    }

    private static func validated(_ value: Double, range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    static func migrateLegacyDefaultsIfNeeded(to destination: UserDefaults, from legacy: UserDefaults? = nil, destinationDomainName: String? = nil, legacyDomainName: String = "com.teodor.MacDynamicBorder") {
        let marker = "notchlight.legacyMigration.v1"
        guard !destination.bool(forKey: marker) else { return }
        let sourcePersistent = (legacy ?? UserDefaults(suiteName: "com.teodor.MacDynamicBorder"))?.persistentDomain(forName: legacyDomainName) ?? [:]
        let persisted = destinationDomainName.flatMap { destination.persistentDomain(forName: $0) } ?? [:]
        let keys = sourcePersistent.keys.filter {
            $0.hasPrefix("border.") || $0.hasPrefix("strips.") ||
            $0.hasPrefix("codex.") || $0.hasPrefix("NSWindow Frame")
        }
        for key in keys where persisted[key] == nil {
            if let value = sourcePersistent[key] { destination.set(value, forKey: key) }
        }
        destination.set(true, forKey: marker)
    }

    private var resolvedColor: NSColor {
        resolved(borderColor, fallback: NSColor(srgbRed: 1, green: 0.04, blue: 0.08, alpha: 1))
    }

    private var resolvedWorkingColor: NSColor {
        resolved(workingColor, fallback: NSColor(srgbRed: 0.15, green: 0.55, blue: 1, alpha: 1))
    }

    private var resolvedEffectiveColor: NSColor {
        resolved(effectiveBorderColor, fallback: NSColor(srgbRed: 1, green: 0.04, blue: 0.08, alpha: 1))
    }

    private func resolved(_ color: Color, fallback: NSColor) -> NSColor {
        (NSColor(color).usingColorSpace(.sRGB) ?? fallback)
            .withAlphaComponent(1)
    }

    deinit {
        inactivityTask?.cancel()
    }
}
