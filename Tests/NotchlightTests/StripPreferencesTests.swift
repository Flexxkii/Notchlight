import AppKit
import SwiftUI
import Testing
@testable import Notchlight

@MainActor
struct StripPreferencesTests {
    @Test("strip preferences persist independently of the progress line")
    func persistence() {
        withModel { model, defaults in
            model.stripThickness = 3
            model.stripLength = 14
            model.stripOffset = 5
            model.stripTopPadding = 4
            model.stripOpacity = 0.4
            model.stripColor = Color(.sRGB, red: 0.2, green: 0.6, blue: 0.9)
            model.stripsEnabled = false

            let restored = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
            #expect(!restored.stripsEnabled)
            #expect(restored.stripThickness == 3)
            #expect(restored.stripLength == 14)
            #expect(restored.stripOffset == 5)
            #expect(restored.stripTopPadding == 4)
            #expect(restored.stripOpacity == 0.4)
            let color = NSColor(restored.stripColor).usingColorSpace(.sRGB)!
            #expect(abs(color.redComponent - 0.2) < 0.001)
            #expect(abs(color.greenComponent - 0.6) < 0.001)
            #expect(abs(color.blueComponent - 0.9) < 0.001)
            #expect(restored.startPercentage == model.startPercentage)
            #expect(restored.endPercentage == model.endPercentage)
            #expect(restored.codexLinked == model.codexLinked)
        }
    }

    @Test("strip values stay finite and within drawable limits")
    func invalidValues() {
        withModel { model, _ in
            model.stripThickness = .nan
            model.stripLength = 200
            model.stripOffset = -1
            model.stripTopPadding = .infinity
            model.stripOpacity = 2
            #expect(model.stripThickness == 1.5)
            #expect(model.stripLength == 20)
            #expect(model.stripOffset == 0)
            #expect(model.stripTopPadding == 2)
            #expect(model.stripOpacity == 1)
        }
    }

    @Test("resetting strips preserves manual range, appearance, and Codex connection")
    func separateReset() {
        withModel { model, _ in
            model.lineWidth = 4
            model.padding = 6
            model.startPercentage = 10
            model.endPercentage = 65
            model.stripLength = 20
            model.stripsEnabled = false
            let linked = model.codexLinked

            model.resetStrips()

            #expect(model.stripsEnabled)
            #expect(model.stripThickness == 1.5)
            #expect(model.stripLength == 8)
            #expect(model.stripOffset == 0)
            #expect(model.stripTopPadding == 2)
            #expect(model.stripOpacity == 0.7)
            #expect(model.lineWidth == 4)
            #expect(model.padding == 6)
            #expect(model.startPercentage == 10)
            #expect(model.endPercentage == 65)
            #expect(model.codexLinked == linked)
        }
    }

    private func withModel(_ body: (BorderModel, UserDefaults) -> Void) {
        let name = "StripPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "border.enabled")
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        body(model, defaults)
    }
}
