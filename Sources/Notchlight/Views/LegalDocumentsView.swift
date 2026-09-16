import SwiftUI

struct LegalDocumentsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var document = LegalDocument.license
    @State private var content = ""
    @State private var loadFailed = false

    private let repository = URL(string: "https://github.com/Flexxkii/notchlight")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notchlight")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("PolyForm licenses · © 2026 Flexxkii")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Version \((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "Development")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Legal document", selection: $document) {
                ForEach(LegalDocument.allCases) { document in
                    Text(document.title).tag(document)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                Text(verbatim: content)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .id(document)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(document.title)

            if loadFailed {
                Link("Read this document in the repository", destination: repository.appendingPathComponent("blob/main/\(document.filename)"))
            }
            HStack {
                Link("Project & support", destination: repository)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 600, idealWidth: 680, minHeight: 440, idealHeight: 640)
        .task(id: document, loadDocument)
    }

    private func loadDocument() async {
        do {
            content = try document.contents()
            loadFailed = false
        } catch {
            content = "This document could not be read from the app. You can find a copy in the project repository."
            loadFailed = true
        }
    }
}
