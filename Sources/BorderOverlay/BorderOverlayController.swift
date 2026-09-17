import AppKit
import Diagnostics

/// Owns the notch overlays and routes pointer interaction only over the notch.
@MainActor
public final class BorderOverlayController {
    public private(set) var detectedNotchCount = 0
    public private(set) var targetDescription = "Overlay disabled"
    public private(set) var swipeMonitoringStatus: SwipeMonitoringStatus = .disabled
    public var onDisplaysChanged: (() -> Void)?
    public var onSwipeMonitoringStatusChanged: ((SwipeMonitoringStatus) -> Void)?
    public var menuProvider: (() -> NSMenu)?

    private var panels: [String: OverlayPanel] = [:]
    private var observers: [NSObjectProtocol] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var menuTrackingObserver: NSObjectProtocol?
    private var hoveredPanelKey: String?
    private var menuPanelKey: String?
    private var currentMenu: NSMenu?
    private let spaceTransition = SpaceTransitionCoordinator()
    private let menuHint = NotchMenuHintController()
    private var sessionIsActive = true
    private var isStarted = false
    private var isEnabled = false
    private var lineWidth: CGFloat = 1
    private var padding: CGFloat = 0
    private var glow = false
    private var pulse = false
    private var strokeRange = OverlayGeometry.StrokeRange(start: 0, end: 1)
    private var color = NSColor(srgbRed: 1, green: 0.04, blue: 0.08, alpha: 1)
    private var strips = BorderStripStyle()
    private var hoverContent = NotchHoverContent()
    private var hoverStyle = NotchHoverStyle()
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var hideWhenSwipingEnabled = false
    private var swipeEventSession: SwipeEventTapSession?
    private var swipeGestureActive = false

    private let diagnostics: DiagnosticRecorder

    public init(diagnostics: DiagnosticRecorder = .disabled) {
        self.diagnostics = diagnostics
        spaceTransition.onPhaseChange = { [weak self] phase in
            self?.applySpaceTransitionPhase(phase)
        }
        spaceTransition.onGestureTimeout = { [weak self] in
            self?.swipeGestureActive = false
        }
        registerObservers()
        refreshDisplayState()
        updateDiagnosticContext()
    }

    isolated deinit {
        menuHint.stop()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        swipeEventSession?.stop()
        swipeEventSession = nil
        if let menuTrackingObserver { NotificationCenter.default.removeObserver(menuTrackingObserver) }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Offer only to a fresh install; the callback persists actual discovery.
    public func offerNotchMenuHint(onComplete: @escaping () -> Void) {
        menuHint.offer(onComplete: onComplete)
    }

    public func update(
        isEnabled: Bool,
        lineWidth: Double,
        padding: Double,
        glow: Bool,
        pulse: Bool = false,
        startPercentage: Double = 0,
        endPercentage: Double = 100,
        color: NSColor = NSColor(srgbRed: 1, green: 0.04, blue: 0.08, alpha: 1),
        strips: BorderStripStyle = BorderStripStyle(),
        hoverContent: NotchHoverContent = NotchHoverContent(),
        hoverStyle: NotchHoverStyle = NotchHoverStyle()
    ) {
        let measureDuration = diagnostics.isEnabled
        let startedAt = measureDuration ? DispatchTime.now().uptimeNanoseconds : 0
        let wasStarted = isStarted
        isStarted = true
        self.isEnabled = isEnabled
        self.lineWidth = OverlayGeometry.normalizedLineWidth(CGFloat(lineWidth))
        self.padding = OverlayGeometry.normalizedPadding(CGFloat(padding))
        self.glow = glow
        self.pulse = pulse
        strokeRange = OverlayGeometry.normalizedStrokeRange(start: CGFloat(startPercentage), end: CGFloat(endPercentage))
        self.color = color.usingColorSpace(.sRGB) ?? color
        self.strips = strips
        self.hoverContent = hoverContent
        self.hoverStyle = hoverStyle
        installMouseMonitorsIfNeeded()
        refreshDisplayState()
        synchronizePanels()
        refreshHover()
        if !wasStarted, hideWhenSwipingEnabled { refreshSwipeMonitoring() }
        updateDiagnosticContext()
        if measureDuration {
            diagnostics.aggregate(.overlayUpdate,
                                  durationNanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt)
        }
    }

    /// Enables or disables the optional passive Dock gesture listener. Toggling
    /// never prompts for accessibility permission; use the explicit request
    /// method from settings when the system reports that permission is needed.
    public func setHideWhenSwiping(_ enabled: Bool) {
        guard hideWhenSwipingEnabled != enabled else { return }
        hideWhenSwipingEnabled = enabled
        diagnostics.updateContext(["swipe.enabled": .bool(enabled)])
        if enabled {
            if isStarted { refreshSwipeMonitoring() }
        } else {
            swipeGestureActive = false
            swipeEventSession?.stop()
            swipeEventSession = nil
            setSwipeMonitoringStatus(.disabled)
            spaceTransition.cancel()
        }
    }

    /// Requests the listen-only event permission after an explicit user action,
    /// then immediately reevaluates the tap. No retry timer is installed.
    public func requestSwipeMonitoringPermission() {
        guard isStarted, hideWhenSwipingEnabled else { return }
        _ = CGRequestListenEventAccess()
        refreshSwipeMonitoring()
    }

    /// Rechecks permission and tap availability. Call this after app activation
    /// or wake, or from an explicit Retry action.
    public func refreshSwipeMonitoring() {
        guard isStarted, hideWhenSwipingEnabled else {
            if swipeMonitoringStatus != .disabled { setSwipeMonitoringStatus(.disabled) }
            return
        }
        guard CGPreflightListenEventAccess() else {
            let wasActive = swipeGestureActive
            swipeGestureActive = false
            swipeEventSession?.stop()
            swipeEventSession = nil
            if wasActive { spaceTransition.cancel() }
            setSwipeMonitoringStatus(.permissionRequired)
            return
        }
        if swipeEventSession != nil {
            if swipeMonitoringStatus != .monitoring { setSwipeMonitoringStatus(.monitoring) }
            return
        }
        let session = SwipeEventTapSession()
        session.onPhase = { [weak self] phase in
            self?.handleSwipePhase(phase)
        }
        session.onUnavailable = { [weak self] in
            self?.handleSwipeUnavailable()
        }
        guard session.start() else {
            setSwipeMonitoringStatus(.unavailable)
            return
        }
        swipeEventSession = session
        setSwipeMonitoringStatus(.monitoring)
    }

    public func stop() {
        menuHint.stop()
        isStarted = false
        isEnabled = false
        spaceTransition.cancel()
        currentMenu?.cancelTracking()
        finishMenuTracking()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        swipeGestureActive = false
        swipeEventSession?.stop()
        swipeEventSession = nil
        setSwipeMonitoringStatus(.disabled)
        removeAllPanels()
        targetDescription = "Overlay disabled"
        updateDiagnosticContext()
    }

    private func installMouseMonitorsIfNeeded() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleMouseMovement() }
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated { self?.handleMouseMovement() }
                return event
            }
        }
    }

    private func handleMouseMovement() {
        let measuring = diagnostics.isEnabled
        let start = measuring ? DispatchTime.now().uptimeNanoseconds : 0
        refreshHover()
        if measuring {
            diagnostics.aggregate(.mouse, durationNanoseconds: DispatchTime.now().uptimeNanoseconds - start)
        }
    }

    private func refreshHover() {
        guard isStarted else { return }
        guard spaceTransition.phase == .idle else {
            for panel in panels.values { panel.ignoresMouseEvents = true }
            return
        }
        if let menuPanelKey {
            panels[menuPanelKey]?.ignoresMouseEvents = false
            return
        }
        let mouse = NSEvent.mouseLocation
        let nextKey = panels.first { key, panel in
            guard let view = panel.contentView as? OverlayView else { return false }
            let point = CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
            let region = hoveredPanelKey == key ? view.expandedHitRect : view.collapsedHitRect
            return region.contains(point)
        }?.key
        let previousHoveredPanelKey = hoveredPanelKey
        hoveredPanelKey = nextKey
        if previousHoveredPanelKey != nextKey {
            diagnostics.updateContext(["hovered": nextKey.map { .string($0) } ?? .string("none")])
        }
        for (key, panel) in panels {
            let isHovered = key == nextKey
            panel.ignoresMouseEvents = !isHovered
            (panel.contentView as? OverlayView)?.setExpanded(isHovered, animated: !reduceMotion)
        }
    }

    private func showMenu(for key: String) {
        guard isStarted, spaceTransition.phase == .idle, menuPanelKey == nil,
              let panel = panels[key], let view = panel.contentView as? OverlayView,
              let menu = menuProvider?() else { return }
        menuPanelKey = key
        menuHint.menuOpened()
        hoveredPanelKey = key
        currentMenu = menu
        diagnostics.updateContext(["menu": .string("shown")])
        panel.ignoresMouseEvents = false
        view.setExpanded(true, animated: !reduceMotion)
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: menu, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishMenuTracking() }
        }
        let point = CGPoint(x: view.collapsedHitRect.midX, y: view.collapsedHitRect.minY - 4)
        let shown = menu.popUp(positioning: nil, at: point, in: view)
        // popUp tracks synchronously; the notification normally clears this first.
        if !shown || menuPanelKey != nil { finishMenuTracking() }
    }

    private func finishMenuTracking() {
        if let menuTrackingObserver { NotificationCenter.default.removeObserver(menuTrackingObserver) }
        menuTrackingObserver = nil
        menuPanelKey = nil
        currentMenu = nil
        diagnostics.updateContext(["menu": .string("none")])
        guard isStarted else { return }
        synchronizePanels()
        refreshHover()
    }

    private func registerObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.displaysChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStarted else { return }
                self.spaceTransition.beginFallback()
            }
        })
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if name != NSWorkspace.accessibilityDisplayOptionsDidChangeNotification {
                        self?.sessionIsActive = true
                    }
                    self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    self?.displaysChanged()
                    self?.refreshSwipeMonitoring()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSwipeMonitoring() }
        })
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessionIsActive = false
                    self?.menuHint.reconcile(target: nil)
                    self?.handleSwipeUnavailable()
                }
            })
        }
    }

    private func setSwipeMonitoringStatus(_ status: SwipeMonitoringStatus) {
        guard swipeMonitoringStatus != status else { return }
        swipeMonitoringStatus = status
        diagnostics.updateContext(["swipe.status": .string(status.diagnosticName)])
        onSwipeMonitoringStatusChanged?(status)
    }

    private func handleSwipePhase(_ phase: SwipeGesturePhase) {
        guard isStarted, hideWhenSwipingEnabled, swipeMonitoringStatus == .monitoring else { return }
        diagnostics.updateContext(["swipe.eventPhase": .string(phase.diagnosticName)])
        switch phase {
        case .began:
            swipeGestureActive = true
            spaceTransition.beginGesture()
        case .changed:
            if !swipeGestureActive {
                swipeGestureActive = true
                spaceTransition.beginGesture()
            }
            spaceTransition.noteGestureChange()
        case .ended, .cancelled:
            guard swipeGestureActive else { return }
            swipeGestureActive = false
            spaceTransition.endGesture()
        }
    }

    private func handleSwipeUnavailable() {
        guard isStarted, hideWhenSwipingEnabled else { return }
        swipeGestureActive = false
        swipeEventSession?.stop()
        swipeEventSession = nil
        spaceTransition.cancel()
        setSwipeMonitoringStatus(.unavailable)
    }

    private func applySpaceTransitionPhase(_ phase: SpaceTransitionCoordinator.Phase) {
        guard isStarted else { return }
        if phase != .idle { menuHint.reconcile(target: nil) }
        diagnostics.updateContext(["swipe.transitionPhase": .string(phase.diagnosticName)])
        updateDiagnosticContext()
        switch phase {
        case .hidden:
            hoveredPanelKey = nil
            for panel in panels.values {
                panel.ignoresMouseEvents = true
                guard let view = panel.contentView as? OverlayView else { continue }
                view.setSpaceTransitionHidden(true, animated: true)
                view.setExpanded(false, animated: !reduceMotion)
            }
            currentMenu?.cancelTracking()
        case .revealing:
            // Reconcile geometry while the overlay is concealed, then return
            // it after a short settling period. Repeated switches restart this
            // period instead of flashing the overlay between desktops.
            refreshDisplayState()
            synchronizePanels()
            for panel in panels.values {
                (panel.contentView as? OverlayView)?.setSpaceTransitionHidden(false, animated: true)
            }
            onDisplaysChanged?()
        case .idle:
            for panel in panels.values {
                (panel.contentView as? OverlayView)?.setSpaceTransitionHidden(false, animated: true)
            }
            refreshHover()
            synchronizeMenuHint()
        }
    }

    private func displaysChanged() {
        refreshDisplayState()
        if isStarted {
            synchronizePanels()
            refreshHover()
        }
        onDisplaysChanged?()
    }

    private func refreshDisplayState() {
        detectedNotchCount = NSScreen.screens.compactMap { notch(for: $0) }.count
        if detectedNotchCount == 0 {
            targetDescription = "No physical display notch detected"
        } else if !isEnabled {
            targetDescription = "Border hidden · click the notch for settings"
        } else {
            targetDescription = "Hover for usage · click the notch for settings"
        }
        updateDiagnosticContext()
    }

    private func synchronizePanels() {
        guard isStarted, menuPanelKey == nil else { return }
        var activeKeys = Set<String>()
        for screen in NSScreen.screens {
            guard let notch = notch(for: screen) else { continue }
            let input = geometryInput(for: screen)
            let geometry = OverlayGeometry.physicalBorder(in: input, notch: notch, lineWidth: lineWidth, padding: padding)
            let key = panelKey(for: screen)
            activeKeys.insert(key)
            let stripMargin = strips.isEnabled ? strips.offset + strips.length / 2 + strips.thickness / 2 + 4 : 0
            let margin = max(32, stripMargin, padding + lineWidth * 2 + 8)
            let frame = OverlayView.panelFrame(for: geometry, content: hoverContent, margin: margin, style: hoverStyle)
            let panel: OverlayPanel
            let view: OverlayView
            if let existing = panels[key], let existingView = existing.contentView as? OverlayView {
                panel = existing
                view = existingView
                if panel.frame != frame { panel.setFrame(frame, display: false) }
                view.frame = NSRect(origin: .zero, size: frame.size)
                view.updateGeometry(geometry, globalOrigin: frame.origin)
            } else {
                view = OverlayView(frame: NSRect(origin: .zero, size: frame.size), drawing: .physical(geometry),
                                   lineWidth: lineWidth, glow: glow, pulse: pulse, padding: padding,
                                   strokeRange: strokeRange, color: color, strips: strips,
                                   reduceMotion: reduceMotion, globalOrigin: frame.origin,
                                   diagnostics: diagnostics)
                panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.diagnostics = diagnostics
                panel.level = .statusBar
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = true
                panel.acceptsMouseMovedEvents = true
                panel.isMovable = false
                panel.contentView = view
                if spaceTransition.phase != .idle {
                    view.setSpaceTransitionHidden(true, animated: false)
                    if spaceTransition.phase == .revealing {
                        view.setSpaceTransitionHidden(false, animated: true)
                    }
                }
                panels[key] = panel
                view.onClick = { [weak self] in self?.showMenu(for: key) }
            }
            view.updateAppearance(lineWidth: lineWidth, glow: glow, pulse: pulse, padding: padding,
                                  strokeRange: strokeRange, color: color, strips: strips, reduceMotion: reduceMotion,
                                  content: hoverContent, hoverStyle: hoverStyle, isEnabled: isEnabled)
            panel.orderFrontRegardless()
        }
        for key in Set(panels.keys).subtracting(activeKeys) {
            let panel = panels.removeValue(forKey: key)
            panel?.orderOut(nil)
            panel?.contentView = nil
        }
        if let hoveredPanelKey, !activeKeys.contains(hoveredPanelKey) { self.hoveredPanelKey = nil }
        if panels.isEmpty { diagnostics.updateContext(["pulse.animationActive": .bool(false)]) }
        synchronizeMenuHint()
        updateDiagnosticContext()
    }

    private func synchronizeMenuHint() {
        guard isStarted, sessionIsActive, spaceTransition.phase == .idle, menuPanelKey == nil,
              let screen = NSScreen.screens.first(where: { notch(for: $0) != nil }),
              let notch = notch(for: screen), panels[panelKey(for: screen)] != nil else {
            menuHint.reconcile(target: nil)
            return
        }
        menuHint.reconcile(target: .init(notch: notch.rect, screen: screen.frame))
    }

    private func removeAllPanels() {
        for panel in panels.values {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
        hoveredPanelKey = nil
        diagnostics.updateContext(["pulse.animationActive": .bool(false), "render.lastUpdateAnimated": .bool(false)])
    }

    private func geometryInput(for screen: NSScreen) -> DisplayGeometryInput {
        DisplayGeometryInput(frame: screen.frame, safeTopInset: screen.safeAreaInsets.top,
                             auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea ?? .zero,
                             auxiliaryTopRightArea: screen.auxiliaryTopRightArea ?? .zero,
                             visibleFrame: screen.visibleFrame)
    }

    private func notch(for screen: NSScreen) -> NotchGeometry? { OverlayGeometry.physicalNotch(in: geometryInput(for: screen)) }

    private func panelKey(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber { return number.stringValue }
        return "\(screen.frame.origin.x):\(screen.frame.origin.y):\(screen.frame.width):\(screen.frame.height)"
    }

    private func updateDiagnosticContext() {
        let screens = NSScreen.screens
        var fields: [String: DiagnosticValue] = [
            "started": .bool(isStarted),
            "enabled": .bool(isEnabled),
            "reduceMotion": .bool(reduceMotion),
            "pulse": .bool(pulse),
            "swipe.enabled": .bool(hideWhenSwipingEnabled),
            "swipe.status": .string(swipeMonitoringStatus.diagnosticName),
            "swipe.phase": .string(spaceTransition.phase.diagnosticName),
            "hovered": hoveredPanelKey.map { .string($0) } ?? .string("none"),
            "menu": .string(menuPanelKey == nil ? "none" : "shown"),
            "display.count": .int(Int64(screens.count)),
            "notch.count": .int(Int64(detectedNotchCount))
        ]
        for (index, screen) in screens.enumerated() {
            fields["display.\(index).width"] = .double(Double(screen.frame.width))
            fields["display.\(index).height"] = .double(Double(screen.frame.height))
            fields["display.\(index).scale"] = .double(Double(screen.backingScaleFactor))
        }
        let hiddenReason: String
        if !isStarted { hiddenReason = "stopped" }
        else if detectedNotchCount == 0 { hiddenReason = "noNotch" }
        else if !isEnabled { hiddenReason = "disabled" }
        else if spaceTransition.phase != .idle { hiddenReason = "spaceTransition" }
        else { hiddenReason = "none" }
        fields["visible"] = .bool(isStarted && isEnabled && detectedNotchCount > 0 && spaceTransition.phase == .idle)
        fields["hiddenReason"] = .string(hiddenReason)
        diagnostics.updateContext(fields)
    }
}

private extension SwipeMonitoringStatus {
    var diagnosticName: String {
        switch self { case .disabled: "disabled"; case .permissionRequired: "permissionRequired"; case .monitoring: "monitoring"; case .unavailable: "unavailable" }
    }
}

private extension SwipeGesturePhase {
    var diagnosticName: String {
        switch self { case .began: "began"; case .changed: "changed"; case .ended: "ended"; case .cancelled: "cancelled" }
    }
}

private extension SpaceTransitionCoordinator.Phase {
    var diagnosticName: String {
        switch self { case .idle: "idle"; case .hidden: "hidden"; case .revealing: "revealing" }
    }
}
