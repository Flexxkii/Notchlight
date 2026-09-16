import BorderOverlay
import CodexIntegration
import Foundation

enum NotchHoverPresentation {
    static func make(
        isLinked: Bool,
        usage: CodexUsageValue?,
        isRefreshing: Bool,
        isStale: Bool = false,
        display: CodexUsageDisplay = .used
    ) -> NotchHoverContent {
        guard isLinked else {
            return NotchHoverContent(
                usageText: "Not connected",
                usageCaption: "Codex usage",
                resetText: "Unavailable",
                resetCaption: "Reset unavailable"
            )
        }
        guard let usage else {
            let status = isRefreshing ? "Reading usage…" : "Usage unavailable"
            return NotchHoverContent(
                usageText: status,
                usageCaption: "Codex usage",
                resetText: "Unavailable",
                resetCaption: "Reset date"
            )
        }

        let usageText = display.summary(for: usage)
        let usageCaption = "\(usage.title) usage"
        if isStale {
            let resetText = usage.resetsAt.map { resetDateText($0) } ?? "Unavailable"
            return NotchHoverContent(
                usageText: usageText,
                usageCaption: usageCaption,
                resetText: resetText,
                resetCaption: "Last known reset"
            )
        }
        let resetText = usage.resetsAt.map { resetDateText($0) } ?? "Unavailable"
        return NotchHoverContent(
            usageText: usageText,
            usageCaption: usageCaption,
            resetText: resetText,
            resetCaption: "Resets"
        )
    }

    private static func resetDateText(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .day(.defaultDigits)
                .month(.abbreviated)
                .hour()
                .minute(.twoDigits)
        )
    }
}
