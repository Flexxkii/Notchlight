import Foundation
import Testing
@testable import Notchlight

struct LegalDocumentTests {
    @Test("every legal document is available offline and matches its canonical release text",
          arguments: LegalDocument.allCases)
    func bundledDocument(_ document: LegalDocument) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let canonical = try String(contentsOf: root.appendingPathComponent(document.filename), encoding: .utf8)
        let bundled = try document.contents()
        #expect(!bundled.isEmpty)
        #expect(bundled == canonical)
    }
}
