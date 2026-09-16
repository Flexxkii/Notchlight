import SwiftUI

enum BorderColorPreset: String, CaseIterable, Identifiable {
    case red, orange, green, blue, purple, white

    var id: Self { self }

    var color: Color {
        switch self {
        case .red: Color(.sRGB, red: 1, green: 0.04, blue: 0.08)
        case .orange: Color(.sRGB, red: 1, green: 0.5, blue: 0)
        case .green: Color(.sRGB, red: 0.2, green: 0.85, blue: 0.4)
        case .blue: Color(.sRGB, red: 0.15, green: 0.55, blue: 1)
        case .purple: Color(.sRGB, red: 0.7, green: 0.3, blue: 1)
        case .white: Color(.sRGB, red: 1, green: 1, blue: 1)
        }
    }
}
