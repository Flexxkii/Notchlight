import AppKit
import Diagnostics

final class OverlayPanel: NSPanel {
    var diagnostics: DiagnosticRecorder = .disabled

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func orderFrontRegardless() {
        // NSPanel's nonactivating style prevents focus theft. Keeping this in
        // one override documents that the overlay is intentionally passive.
        super.orderFrontRegardless()
        diagnostics.updateContext(["panel.visible": .bool(isVisible)])
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        diagnostics.updateContext(["panel.visible": .bool(isVisible)])
    }
}
