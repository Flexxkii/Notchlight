import BorderOverlay
import Foundation
import Testing
@testable import Notchlight

@MainActor
struct HoverPreferencesTests {
    @Test("hover size defaults smaller, persists, and resets with appearance")
    func persistenceAndReset() throws {
        let name = "HoverPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(model.hoverTextSize == 12)
        model.hoverTextSize = 10.5
        let restored = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(restored.hoverTextSize == 10.5)
        model.resetStrips()
        #expect(model.hoverTextSize == 10.5)
        let linked = model.codexLinked
        model.resetAppearance()
        #expect(model.hoverTextSize == NotchHoverStyle.defaultTextSize)
        #expect(defaults.double(forKey: "hover.textSize") == 12)
        #expect(model.codexLinked == linked)
    }

    @Test("invalid saved and live hover sizes are normalized and persisted")
    func invalidValues() throws {
        let name = "HoverPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(100, forKey: "hover.textSize")
        let model = BorderModel(defaults: defaults, startIntegration: false, startOverlay: false)
        #expect(model.hoverTextSize == 14)
        for (input, expected) in [(Double.nan, 12.0), (.infinity, 12.0), (-1, 10.0), (100, 14.0)] {
            model.hoverTextSize = input
            #expect(model.hoverTextSize == expected)
            #expect(defaults.double(forKey: "hover.textSize") == expected)
        }
    }
}
