import SwiftUI

struct TranscriptCleanupSettingsView: View {
    @ObservedObject var settings: TranscriptCleanupSettings
    @State private var apiKeyInput = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Claude Cleanup")
                    .font(.title2.weight(.semibold))

                Text("Sends each transcript to Claude Haiku to fix punctuation and remove filler words before pasting. If Claude fails, the original transcript is pasted.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Clean up transcripts with Claude", isOn: $settings.isEnabled)
                .disabled(!settings.hasAPIKey)

            VStack(alignment: .leading, spacing: 8) {
                Text("Anthropic API Key")
                    .font(.headline)

                if settings.hasAPIKey {
                    savedKeyRow
                } else {
                    keyEntryRow
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            additionalContextEditor
        }
        .padding(24)
        .frame(width: 420)
    }

    private var additionalContextEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Additional Context")
                .font(.headline)

            Text("Describe what you usually dictate: topics, names, jargon, or style preferences.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $settings.additionalContext)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 96)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                }
        }
    }

    private var savedKeyRow: some View {
        HStack {
            Label("Saved in Keychain", systemImage: "lock.fill")
                .foregroundStyle(.secondary)

            Spacer()

            Button("Remove") {
                settings.removeAPIKey()
            }
        }
    }

    private var keyEntryRow: some View {
        HStack {
            SecureField("sk-ant-…", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveAPIKey)

            Button("Save", action: saveAPIKey)
                .disabled(trimmedAPIKey.isEmpty)
        }
    }

    private var trimmedAPIKey: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveAPIKey() {
        guard !trimmedAPIKey.isEmpty else { return }

        do {
            try settings.saveAPIKey(trimmedAPIKey)
            apiKeyInput = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
