import AppKit
import SwiftUI
import Testing
@testable import Notchlight

@MainActor
struct BorderModelTests {
    @Test("fresh preferences use the documented appearance defaults")
    func defaultPreferences() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { remove(defaults, suiteName: suiteName) }
        defaults.set(false, forKey: "border.enabled")

        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)

        #expect(model.isEnabled == false)
        #expect(model.lineWidth == 2)
        #expect(model.padding == 1)
        #expect(model.glow == false)
        #expect(model.startPercentage == 0)
        #expect(model.endPercentage == 100)
        expectColor(model.borderColor, red: 1, green: 0.04, blue: 0.08)
    }

    @Test("percentage setters clamp, round, and keep the range ordered")
    func percentageNormalization() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { remove(defaults, suiteName: suiteName) }
        defaults.set(false, forKey: "border.enabled")
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)

        model.startPercentage = 25.55
        #expect(model.startPercentage == 25.6)
        model.endPercentage = 20
        #expect(model.startPercentage == 20)
        #expect(model.endPercentage == 20)

        model.startPercentage = 90
        model.endPercentage = 10
        #expect(model.startPercentage == 10)
        #expect(model.endPercentage == 10)

        model.startPercentage = -20
        #expect(model.startPercentage == 0)
        model.endPercentage = 140
        #expect(model.endPercentage == 100)

        model.startPercentage = .nan
        #expect(model.startPercentage == 0)
        model.endPercentage = .infinity
        #expect(model.endPercentage == 100)
    }

    @Test("appearance and stroke preferences survive a second model initialization")
    func preferencesPersistAcrossInitialization() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { remove(defaults, suiteName: suiteName) }
        defaults.set(false, forKey: "border.enabled")

        do {
            let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
            model.lineWidth = 4.5
            model.padding = 7
            model.glow = true
            model.startPercentage = 12.34
            model.endPercentage = 87.66
            model.borderColor = Color(.sRGB, red: 0.17, green: 0.42, blue: 0.91)
        }

        let restored = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(restored.isEnabled == false)
        #expect(restored.lineWidth == 4.5)
        #expect(restored.padding == 7)
        #expect(restored.glow == true)
        #expect(restored.startPercentage == 12.3)
        #expect(restored.endPercentage == 87.7)
        expectColor(restored.borderColor, red: 0.17, green: 0.42, blue: 0.91)
    }

    @Test("resetAppearance restores and persists the full red appearance")
    func resetAppearance() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { remove(defaults, suiteName: suiteName) }
        defaults.set(false, forKey: "border.enabled")
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        model.lineWidth = 5
        model.padding = 10
        model.glow = true
        model.startPercentage = 25
        model.endPercentage = 75
        model.borderColor = Color(.sRGB, red: 0.2, green: 0.6, blue: 0.8)

        model.resetAppearance()

        #expect(model.lineWidth == 2)
        #expect(model.padding == 1)
        #expect(model.glow == false)
        #expect(model.startPercentage == 0)
        #expect(model.endPercentage == 100)
        expectColor(model.borderColor, red: 1, green: 0.04, blue: 0.08)
        #expect(defaults.double(forKey: "border.startPercentage") == 0)
        #expect(defaults.double(forKey: "border.endPercentage") == 100)
        #expect(defaults.double(forKey: "border.color.red") == 1)
        #expect(abs(defaults.double(forKey: "border.color.green") - 0.04) < 0.000001)
        #expect(abs(defaults.double(forKey: "border.color.blue") - 0.08) < 0.000001)
    }

    @Test("retired placement preferences are removed without resetting appearance")
    func retiredPlacementPreference() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { remove(defaults, suiteName: suiteName) }
        defaults.set(false, forKey: "border.enabled")
        defaults.set("island", forKey: "border.mode")
        defaults.set(4.5, forKey: "border.lineWidth")
        defaults.set(25.0, forKey: "border.startPercentage")
        defaults.set(80.0, forKey: "border.endPercentage")

        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)

        #expect(defaults.object(forKey: "border.mode") == nil)
        #expect(model.lineWidth == 4.5)
        #expect(model.startPercentage == 25)
        #expect(model.endPercentage == 80)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "NotchlightTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func remove(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func expectColor(_ color: Color, red: CGFloat, green: CGFloat, blue: CGFloat) {
        let nsColor = NSColor(color).usingColorSpace(.sRGB)!
        #expect(abs(nsColor.redComponent - red) < 0.001)
        #expect(abs(nsColor.greenComponent - green) < 0.001)
        #expect(abs(nsColor.blueComponent - blue) < 0.001)
    }
}
