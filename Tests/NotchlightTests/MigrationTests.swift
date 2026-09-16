import Foundation
import Testing
@testable import Notchlight

@MainActor
struct MigrationTests {
    @Test("legacy preferences fill missing Notchlight keys and preserve new values")
    func migratesMissingKeysOnly() throws {
        let legacyName = "MigrationTests.legacy.\(UUID().uuidString)"
        let destinationName = "MigrationTests.destination.\(UUID().uuidString)"
        let legacy = try #require(UserDefaults(suiteName: legacyName))
        let destination = try #require(UserDefaults(suiteName: destinationName))
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            destination.removePersistentDomain(forName: destinationName)
        }
        legacy.set(4.5, forKey: "border.lineWidth")
        legacy.set("weekly", forKey: "codex.window")
        legacy.set(0.8, forKey: "border.color.red")
        legacy.set(true, forKey: "border.enabled")
        legacy.set(0.002, forKey: "border.inactivityTimeoutMinutes")
        legacy.set(0.15, forKey: "border.workingColor.red")
        legacy.set(12.0, forKey: "strips.length")
        legacy.set("private", forKey: "notchlight.unowned")
        destination.set(false, forKey: "border.enabled")

        BorderModel.migrateLegacyDefaultsIfNeeded(to: destination, from: legacy, destinationDomainName: destinationName, legacyDomainName: legacyName)

        #expect(destination.double(forKey: "border.lineWidth") == 4.5)
        #expect(destination.string(forKey: "codex.window") == "weekly")
        #expect(destination.double(forKey: "border.color.red") == 0.8)
        #expect(destination.bool(forKey: "border.enabled") == false)
        #expect(destination.double(forKey: "border.inactivityTimeoutMinutes") == 0.002)
        #expect(destination.double(forKey: "border.workingColor.red") == 0.15)
        #expect(destination.double(forKey: "strips.length") == 12)
        #expect(destination.persistentDomain(forName: destinationName)?["notchlight.unowned"] == nil)
        #expect(destination.persistentDomain(forName: destinationName)?["border.padding"] == nil)
    }

    @Test("legacy migration is idempotent")
    func migrationIsIdempotent() throws {
        let legacyName = "MigrationTests.legacy.\(UUID().uuidString)"
        let destinationName = "MigrationTests.destination.\(UUID().uuidString)"
        let legacy = try #require(UserDefaults(suiteName: legacyName))
        let destination = try #require(UserDefaults(suiteName: destinationName))
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            destination.removePersistentDomain(forName: destinationName)
        }
        legacy.set(2.0, forKey: "border.lineWidth")
        BorderModel.migrateLegacyDefaultsIfNeeded(to: destination, from: legacy, destinationDomainName: destinationName, legacyDomainName: legacyName)
        legacy.set(6.0, forKey: "border.lineWidth")
        BorderModel.migrateLegacyDefaultsIfNeeded(to: destination, from: legacy, destinationDomainName: destinationName, legacyDomainName: legacyName)

        #expect(destination.double(forKey: "border.lineWidth") == 2.0)
        #expect(destination.bool(forKey: "notchlight.legacyMigration.v1"))
    }
}
