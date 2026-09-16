import Foundation

enum LegalDocument: String, CaseIterable, Identifiable {
    case license, terms, privacy, notices

    var id: Self { self }

    var title: String {
        switch self {
        case .license: "License"
        case .terms: "Terms of use"
        case .privacy: "Privacy"
        case .notices: "Third-party notices"
        }
    }

    var filename: String {
        switch self {
        case .license: "LICENSE"
        case .terms: "TERMS.md"
        case .privacy: "PRIVACY.md"
        case .notices: "THIRD_PARTY_NOTICES.md"
        }
    }

    func contents() throws -> String {
        #if SWIFT_PACKAGE
        let resources = Bundle.module
        #else
        // The standalone validation fixture bundles the same canonical documents.
        let resources = Bundle.main
        #endif
        guard let url = resources.url(forResource: filename, withExtension: nil, subdirectory: "Legal") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
