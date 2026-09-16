import SwiftUI

struct LegalSettingsView: View {
    @State private var showsDocuments = false

    var body: some View {
        GroupBox("License & terms") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Use for noncommercial purposes or internal business work. Noncommercial sharing is allowed; commercial redistribution requires separate permission.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("License, terms & privacy…") { showsDocuments = true }
                    Spacer()
                    Text("© 2026 Flexxkii")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
        .sheet(isPresented: $showsDocuments) {
            LegalDocumentsView()
        }
    }
}
