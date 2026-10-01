import Foundation
import CryptoKit

/// Host-only identity context lets a failed limit request invalidate a previous
/// account's data. The fingerprint is never written into the widget snapshot.
public struct CodexUsageReadResult: Sendable {
    public let accountFingerprint: String?
    public let usage: Result<CodexUsageSnapshot, CodexUsageError>

    public init(accountFingerprint: String?, usage: Result<CodexUsageSnapshot, CodexUsageError>) {
        self.accountFingerprint = accountFingerprint
        self.usage = usage
    }
}

enum CodexAccountIdentity {
    static func fingerprint(_ account: [String: Any]) -> String? {
        guard let email = account["email"] as? String, !email.isEmpty else { return nil }
        return SHA256.hash(data: Data(email.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
