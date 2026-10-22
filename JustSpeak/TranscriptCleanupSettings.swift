import Combine
import Foundation

final class TranscriptCleanupSettings: ObservableObject {
    private static let enabledKey = "transcriptCleanupEnabled"
    private static let additionalContextKey = "transcriptCleanupAdditionalContext"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published var additionalContext: String {
        didSet { UserDefaults.standard.set(additionalContext, forKey: Self.additionalContextKey) }
    }
    @Published private(set) var apiKey: String?

    var hasAPIKey: Bool { apiKey != nil }

    init() {
        apiKey = APIKeyKeychain.load()
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        additionalContext = UserDefaults.standard.string(forKey: Self.additionalContextKey) ?? ""
    }

    func saveAPIKey(_ apiKey: String) throws {
        try APIKeyKeychain.save(apiKey)
        self.apiKey = apiKey
        isEnabled = true
    }

    func removeAPIKey() {
        APIKeyKeychain.delete()
        apiKey = nil
        isEnabled = false
    }
}
