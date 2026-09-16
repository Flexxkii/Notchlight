import CodexIntegration
import Foundation

enum CodexUsageDisplay: String, CaseIterable, Identifiable {
    case used
    case remaining

    var id: Self { self }

    var title: String {
        switch self {
        case .used: "Used"
        case .remaining: "Remaining"
        }
    }

    var description: String { title.lowercased() }

    func percentage(for usage: CodexUsageValue) -> Double {
        switch self {
        case .used: usage.usedPercent
        case .remaining: 100 - usage.usedPercent
        }
    }

    func formattedPercentage(for usage: CodexUsageValue) -> String {
        percentage(for: usage).formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    func summary(for usage: CodexUsageValue) -> String {
        "\(formattedPercentage(for: usage)) \(description)"
    }
}
