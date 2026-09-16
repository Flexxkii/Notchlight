import BorderOverlay
import CodexIntegration
import Foundation
import AppKit
import Testing
@testable import Notchlight

struct NotchHoverPresentationTests {
    @Test("remaining hover shows converted usage and preserves reset and stale state", arguments: [false, true])
    func remainingUsage(isStale: Bool) {
        let usage = CodexUsageValue(usedPercent: 43, windowDurationMins: 300,
                                   resetsAt: Date(timeIntervalSince1970: 1_758_320_280))
        let content = NotchHoverPresentation.make(isLinked: true, usage: usage,
                                                isRefreshing: false, isStale: isStale, display: .remaining)
        #expect(content.usageText == "57% remaining")
        #expect(content.usageCaption == "5-hour usage")
        #expect(content.resetCaption == (isStale ? "Last known reset" : "Resets"))
        #expect(content.resetText != "Unavailable")
    }

    @Test("remaining mode preserves unavailable, loading, and disconnected states")
    func remainingUnavailableStates() {
        let missing = NotchHoverPresentation.make(isLinked: true, usage: nil,
                                                isRefreshing: false, display: .remaining)
        #expect(missing.usageText == "Usage unavailable")
        let loading = NotchHoverPresentation.make(isLinked: true, usage: nil,
                                                isRefreshing: true, display: .remaining)
        #expect(loading.usageText == "Reading usage…")
        let disconnected = NotchHoverPresentation.make(isLinked: false, usage: nil,
                                                     isRefreshing: false, display: .remaining)
        #expect(disconnected.usageText == "Not connected")
    }

    @Test("linked usage shows used percentage and exact reset date")
    func linkedUsage() {
        let content = NotchHoverPresentation.make(
            isLinked: true,
            usage: CodexUsageValue(usedPercent: 43, windowDurationMins: 10_080, resetsAt: Date(timeIntervalSince1970: 1_758_320_280)),
            isRefreshing: false
        )
        #expect(content.usageText == "43% used")
        #expect(content.usageCaption == "Weekly usage")
        #expect(content.resetCaption == "Resets")
        #expect(content.resetText != "Unavailable")
    }

    @Test("missing and disconnected states never fabricate usage")
    func unavailableStates() {
        let missing = NotchHoverPresentation.make(isLinked: true, usage: nil, isRefreshing: false)
        #expect(missing.usageText == "Usage unavailable")
        #expect(missing.resetText == "Unavailable")

        let disconnected = NotchHoverPresentation.make(isLinked: false, usage: nil, isRefreshing: false)
        #expect(disconnected.usageText == "Not connected")
        #expect(disconnected.usageCaption == "Codex usage")
        #expect(disconnected.resetText == "Unavailable")
        #expect(disconnected.resetCaption == "Reset unavailable")
    }

    @Test("stale usage is labeled as last known")
    func staleUsage() {
        let content = NotchHoverPresentation.make(
            isLinked: true,
            usage: CodexUsageValue(usedPercent: 12.5, windowDurationMins: 300, resetsAt: Date(timeIntervalSince1970: 1_758_320_280)),
            isRefreshing: false,
            isStale: true
        )
        #expect(content.usageText.contains("12"))
        #expect(content.usageText.hasSuffix("% used"))
        #expect(content.resetText != "Unavailable")
        #expect(content.resetCaption == "Last known reset")
    }

    @Test("native menu exposes state and settings target")
    @MainActor
    func menuStateAndSettingsTarget() throws {
        let suiteName = "NotchlightTests.notch-menu"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "border.enabled")
        defaults.set(false, forKey: "codex.linked")

        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        let controller = NotchMenuController(model: model)
        let menu = controller.makeMenu()

        #expect(menu.autoenablesItems == false)
        let status = try #require(menu.item(at: 0))
        let connect = try #require(menu.item(at: 1))
        let showBorder = try #require(menu.item(at: 2))
        let settings = try #require(menu.item(at: 4))
        #expect(status.isEnabled == false)
        #expect(connect.state == .off)
        #expect(showBorder.state == .off)
        #expect(settings.target === controller)
        #expect(settings.action != nil)
        #expect(settings.action.map(NSStringFromSelector) == "showSettings:")
        #expect(settings.keyEquivalent == ",")
    }
}
